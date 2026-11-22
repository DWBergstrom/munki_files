#!/usr/bin/env python3
"""
mac_app_inventory.py - Fast, efficient macOS installed application inventory.

Gathers installed applications using Spotlight (mdfind) for near-instant
discovery, then reads each app bundle's Info.plist for name, version, and
bundle identifier. Outputs structured data (JSON by default) that is easy to
parse from bash / AutoPkg / Munki automation.

Designed to be called from auto-autopkg-ts.sh and similar scripts.

Features:
  * mdfind-backed discovery - orders of magnitude faster than find/walk
  * Parallel Info.plist parsing for large inventories
  * Optional remote host scanning over SSH (same style as auto-autopkg-ts.sh)
  * Skip-list support (one app name per line)
  * Comparison against existing .munki.recipe overrides
  * Output formats: json, csv, tsv, names

Examples:
    ./mac_app_inventory.py --format json > apps.json
    ./mac_app_inventory.py --format names --include-system
    ./mac_app_inventory.py --scan-host dwbergstrom@192.168.1.28 --format json
    ./mac_app_inventory.py --compare-overrides ./overrides --missing-only --format names

Integration with auto-autopkg-ts.sh:
    # Get a list of apps without overrides, one per line:
    ./mac_app_inventory.py --compare-overrides ./overrides --missing-only --format names

Requirements:
    python3 (pre-installed on macOS)
"""

import argparse
import concurrent.futures
import csv
import glob
import io
import json
import os
import plistlib
import subprocess
import sys
from pathlib import Path


# Apple system applications that typically do not need AutoPkg/Munki management.
# Matching is case-insensitive and also tested with non-alphanumerics stripped.
DEFAULT_SYSTEM_APPS = {
    "app store", "automator", "books", "calculator", "calendar", "chess",
    "contacts", "dashboard", "dictionary", "facetime", "find my", "font book",
    "freeform", "home", "image capture", "keynote", "mail", "maps", "messages",
    "mission control", "music", "news", "notes", "numbers", "pages",
    "photo booth", "photos", "podcasts", "preview", "quicktime player",
    "reminders", "safari", "shortcuts", "siri", "stickies", "stocks",
    "system preferences", "system settings", "textedit", "time machine",
    "tv", "voice memos", "weather",
}


def run_mdfind(query, timeout=30):
    """Run an mdfind query and return matching paths (empty list on failure)."""
    try:
        result = subprocess.run(
            ["mdfind", query],
            capture_output=True, text=True, timeout=timeout,
        )
        if result.returncode != 0:
            return []
        return [line for line in result.stdout.splitlines() if line.strip()]
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError):
        return []


def discover_tailscale_hosts():
    """Parse `tailscale status` and return a list of user@ip for online macOS hosts.

    Tailscale status output looks like:
        100.108.53.59   coherence               DWBergstrom@  macOS     -
        100.87.179.13   apple-tv                DWBergstrom@  tvOS     offline, ...

    We extract the IP and username for macOS entries that are online (not
    offline/idle), and format them as user@ip for SSH scanning.
    """
    try:
        result = subprocess.run(
            ["tailscale", "status"],
            capture_output=True, text=True, timeout=10,
        )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        return []

    if result.returncode != 0:
        return []

    # Get the local machine's Tailscale IP so we don't scan ourselves
    local_ip = None
    try:
        local_result = subprocess.run(
            ["tailscale", "ip", "-4"],
            capture_output=True, text=True, timeout=5,
        )
        if local_result.returncode == 0:
            local_ip = local_result.stdout.strip()
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired):
        pass

    hosts = []
    for line in result.stdout.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue

        parts = line.split()
        if len(parts) < 4:
            continue

        ip = parts[0]

        # Skip the local machine (redundant with local scan)
        if local_ip and ip == local_ip:
            continue

        # parts[1] = hostname, parts[2] = user@ (may have trailing @), parts[3] = OS
        os_name = parts[3].lower() if len(parts) > 3 else ""

        # Only scan macOS hosts
        if "macos" not in os_name:
            continue

        # Skip offline / idle hosts
        status = " ".join(parts[4:]).lower() if len(parts) > 4 else ""
        if "offline" in status:
            continue

        # Extract username from parts[2] (e.g., "DWBergstrom@" -> "DWBergstrom")
        user_part = parts[2] if len(parts) > 2 else ""
        username = user_part.rstrip("@")

        if username and ip:
            hosts.append("%s@%s" % (username, ip))
        elif ip:
            hosts.append(ip)

    return hosts


def parse_app_plist(app_path):
    """Extract metadata from an app bundle's Contents/Info.plist.

    Returns a dict with name, path, bundle_id, version, bundle_version, or
    None if the plist cannot be read.
    """
    info_plist = os.path.join(app_path, "Contents", "Info.plist")
    if not os.path.isfile(info_plist):
        return None

    try:
        with open(info_plist, "rb") as f:
            plist = plistlib.load(f)
    except Exception:
        return None

    bundle_id = str(plist.get("CFBundleIdentifier", "") or "")
    name = (
        plist.get("CFBundleDisplayName")
        or plist.get("CFBundleName")
        or Path(app_path).stem
    )
    if not name:
        name = Path(app_path).stem

    return {
        "name": str(name),
        "path": str(app_path),
        "bundle_id": bundle_id,
        "version": str(plist.get("CFBundleShortVersionString", "") or ""),
        "bundle_version": str(plist.get("CFBundleVersion", "") or ""),
    }


def _normalize(name):
    """Lowercase and strip non-alphanumerics for fuzzy matching."""
    return "".join(c for c in name.lower() if c.isalnum())


# Steam library paths that contain installed games.  These are not
# typically managed via Munki, so we can optionally exclude them.
STEAM_PATH_MARKERS = [
    "Application Support/Steam/steamapps/",
    "Application Support/Steam/",
    "/Steam/steamapps/",
]


def is_steam_app(app_path):
    """Return True if the app lives under a Steam library directory."""
    path_lower = app_path.lower()
    for marker in STEAM_PATH_MARKERS:
        if marker.lower() in path_lower:
            return True
    return False


def gather_local_apps(include_system=False, exclude_steam=False, max_workers=8):
    """Gather all local applications using mdfind + Info.plist parsing."""
    # kMDItemKind == 'Application' uses the Spotlight index - nearly instant
    # even with thousands of apps. Fallback to kMDItemContentType if empty.
    app_paths = run_mdfind("kMDItemKind == 'Application'")
    if not app_paths:
        app_paths = run_mdfind("kMDItemContentType == 'com.apple.application-bundle'")

    apps = []
    seen_bundle_ids = set()

    def process(path):
        path = path.strip()
        if not path or not path.endswith(".app"):
            return None
        return parse_app_plist(path)

    # ThreadPoolExecutor keeps the GIL-friendly plist I/O overlapped.
    with concurrent.futures.ThreadPoolExecutor(max_workers=max_workers) as executor:
        results = executor.map(process, app_paths)

    for app in results:
        if app is None:
            continue

        app_path = app["path"]

        # Skip system-protected locations unless --include-system is set.
        # mdfind tags many background agents/helpers as "Application";
        # those are not user-installable software for a Munki catalog.
        if not include_system:
            if (
                app_path.startswith("/System/Library/")
                or app_path.startswith("/System/Applications/")
                or app_path.startswith("/System/i386/")
                or app_path.startswith("/usr/")
                or app_path.startswith("/bin/")
                or app_path.startswith("/sbin/")
                or app_path.startswith("/private/")
            ):
                continue

        # Optionally exclude Steam games
        if exclude_steam and is_steam_app(app_path):
            continue

        # De-duplicate by bundle ID (e.g. multiple copies of same app).
        bid = app["bundle_id"]
        if bid:
            if bid in seen_bundle_ids:
                continue
            seen_bundle_ids.add(bid)

        # Optionally filter out Apple system apps by name.
        if not include_system:
            name_lower = app["name"].lower()
            if name_lower in DEFAULT_SYSTEM_APPS or _normalize(app["name"]) in DEFAULT_SYSTEM_APPS:
                continue

        apps.append(app)

    apps.sort(key=lambda a: a["name"].lower())
    return apps


def gather_remote_apps(host, timeout=10):
    """Gather applications from a remote host over SSH.

    Runs a single inline shell loop on the remote side so we make one SSH
    connection regardless of how many apps are installed. Uses mdls on the
    remote host for fast per-app metadata.
    """
    print("Scanning remote host: %s..." % host, file=sys.stderr)

    ssh_cmd = (
        "for app in /Applications/*.app ~/Applications/*.app; do "
        "[ -d \"$app\" ] || continue; "
        "name=\"$(basename \"$app\" .app)\"; "
        "version=\"$(mdls -raw -name kMDItemVersion \"$app\" 2>/dev/null)\"; "
        "bundle_id=\"$(mdls -raw -name kMDItemCFBundleIdentifier \"$app\" 2>/dev/null)\"; "
        "printf '%s\\t%s\\t%s\\t%s\\n' \"$name\" \"$app\" \"$bundle_id\" \"$version\"; "
        "done"
    )
    try:
        result = subprocess.run(
            [
                "ssh", "-o", "ConnectTimeout=%d" % timeout,
                "-o", "BatchMode=yes", host, ssh_cmd,
            ],
            capture_output=True, text=True, timeout=timeout + 5,
        )
    except (subprocess.TimeoutExpired, FileNotFoundError, OSError) as e:
        print("  Could not connect to %s: %s" % (host, e), file=sys.stderr)
        return []

    if result.returncode != 0:
        stderr = result.stderr.strip() if result.stderr else "unknown error"
        print("  Could not connect to %s: SSH exited with code %d (%s)" % (
            host, result.returncode, stderr[:200]), file=sys.stderr)
        return []

    apps = []
    for line in result.stdout.splitlines():
        if not line.strip():
            continue
        parts = line.split("\t")
        apps.append({
            "name": parts[0] if len(parts) > 0 else "",
            "path": parts[1] if len(parts) > 1 else "",
            "bundle_id": parts[2] if len(parts) > 2 else "",
            "version": parts[3] if len(parts) > 3 else "",
            "bundle_version": "",
        })
    return apps


def load_skip_list(path):
    """Load a skip list (one app name per line, case-insensitive)."""
    skip = set()
    if not path or not os.path.isfile(path):
        return skip
    try:
        with open(path, "r") as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                skip.add(line.lower())
    except OSError:
        pass
    return skip


def load_existing_override_names(override_dir):
    """Load existing override names from .munki.recipe / .recipe files."""
    names = set()
    if not override_dir or not os.path.isdir(override_dir):
        return names
    for pattern in ("*.munki.recipe", "*.recipe"):
        for path in glob.glob(os.path.join(override_dir, pattern)):
            fname = os.path.basename(path)
            name = fname
            for suffix in (".munki.recipe", ".recipe"):
                if name.endswith(suffix):
                    name = name[: -len(suffix)]
                    break
            # Also try to read the NAME key from the recipe plist for accuracy.
            try:
                with open(path, "rb") as f:
                    plist = plistlib.load(f)
                recipe_name = plist.get("NAME")
                if recipe_name:
                    names.add(str(recipe_name).lower())
            except Exception:
                pass
            names.add(name.lower())
    return names


def format_output(apps, fmt):
    """Format the apps list as the requested output format."""
    fields = ["name", "path", "bundle_id", "version", "bundle_version"]

    if fmt == "json":
        return json.dumps(apps, indent=2)

    if fmt == "names":
        return "\n".join(app["name"] for app in apps)

    if fmt == "tsv":
        lines = ["\t".join(fields)]
        for app in apps:
            lines.append("\t".join(app.get(k, "") for k in fields))
        return "\n".join(lines)

    if fmt == "csv":
        buf = io.StringIO()
        writer = csv.DictWriter(buf, fieldnames=fields, extrasaction="ignore")
        writer.writeheader()
        for app in apps:
            writer.writerow(app)
        return buf.getvalue()

    return json.dumps(apps, indent=2)


def main():
    parser = argparse.ArgumentParser(
        description="Gather installed macOS applications for Munki/AutoPkg inventory.",
    )
    parser.add_argument(
        "--format",
        choices=["json", "csv", "tsv", "names"],
        default="json",
        help="Output format (default: json)",
    )
    parser.add_argument(
        "--output",
        help="Write output to FILE instead of stdout",
    )
    parser.add_argument(
        "--include-system",
        action="store_true",
        help="Include Apple system applications (default: excluded)",
    )
    parser.add_argument(
        "--exclude-steam",
        action="store_true",
        help="Exclude Steam games (apps under Steam library directories)",
    )
    parser.add_argument(
        "--skip-list",
        help="File with app names to skip (one per line, # comments allowed)",
    )
    parser.add_argument(
        "--scan-host",
        action="append",
        metavar="USER@HOST",
        help="Additional remote host to scan over SSH (repeatable)",
    )
    parser.add_argument(
        "--local-only",
        action="store_true",
        help="Skip scanning remote hosts",
    )
    parser.add_argument(
        "--hosts-file",
        help="File with remote hosts to scan (one per line, # comments allowed)",
    )
    parser.add_argument(
        "--tailscale",
        action="store_true",
        help="Scan hosts discovered via tailscale status",
    )
    parser.add_argument(
        "--compare-overrides",
        metavar="DIR",
        help="Directory of .munki.recipe overrides to compare against",
    )
    parser.add_argument(
        "--missing-only",
        action="store_true",
        help="Only show apps without matching overrides",
    )
    args = parser.parse_args()

    # --- Local discovery ----------------------------------------------------
    all_apps = gather_local_apps(
        include_system=args.include_system,
        exclude_steam=args.exclude_steam,
    )

    # --- Apply skip list ----------------------------------------------------
    skip_set = load_skip_list(args.skip_list) if args.skip_list else set()
    if skip_set:
        all_apps = [
            app for app in all_apps
            if app["name"].lower() not in skip_set
            and _normalize(app["name"]) not in skip_set
        ]

    # --- Remote hosts -------------------------------------------------------
    hosts = []
    if not args.local_only:
        if args.hosts_file and os.path.isfile(args.hosts_file):
            with open(args.hosts_file, "r") as f:
                for line in f:
                    line = line.strip()
                    if line and not line.startswith("#"):
                        hosts.append(line)
        hosts.extend(args.scan_host or [])

        # Discover hosts from tailscale status
        if args.tailscale:
            ts_hosts = discover_tailscale_hosts()
            print("Discovered %d host(s) from tailscale" % len(ts_hosts), file=sys.stderr)
            hosts.extend(ts_hosts)

    for host in hosts:
        remote_apps = gather_remote_apps(host)
        for app in remote_apps:
            if app["name"].lower() not in skip_set and _normalize(app["name"]) not in skip_set:
                all_apps.append(app)

    # --- De-duplicate by app name (local wins on ties) ----------------------
    seen_names = set()
    unique_apps = []
    for app in all_apps:
        key = app["name"].lower()
        if key not in seen_names:
            seen_names.add(key)
            unique_apps.append(app)
    all_apps = unique_apps

    # --- Compare against existing overrides ---------------------------------
    apps_without_overrides = []
    if args.compare_overrides:
        existing = load_existing_override_names(args.compare_overrides)
        for app in all_apps:
            name_lower = app["name"].lower()
            nospace = _normalize(app["name"])
            if name_lower not in existing and nospace not in existing:
                apps_without_overrides.append(app)

    output_apps = apps_without_overrides if args.missing_only else all_apps
    output = format_output(output_apps, args.format)

    if args.output:
        with open(args.output, "w") as f:
            f.write(output)
            if not output.endswith("\n"):
                f.write("\n")
        print(
            "Wrote %d application(s) to %s" % (len(output_apps), args.output),
            file=sys.stderr,
        )
    else:
        print(output)


if __name__ == "__main__":
    main()
