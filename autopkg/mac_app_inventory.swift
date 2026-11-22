#!/usr/bin/swift
//
// mac_app_inventory.swift - Fast macOS installed application inventory (Swift)
//
// Compile once:
//   swiftc -O mac_app_inventory.swift -o mac_app_inventory
//
// Then distribute the binary — it has zero runtime dependencies.
// Run:
//   ./mac_app_inventory --format json
//   ./mac_app_inventory --format names
//   ./mac_app_inventory --format names --compare-overrides ./overrides --missing-only
//

import Foundation

// MARK: - Argument parsing

struct Arguments {
    var format: String = "json"
    var outputPath: String? = nil
    var includeSystem: Bool = false
    var skipListPath: String? = nil
    var scanHosts: [String] = []
    var localOnly: Bool = false
    var hostsFile: String? = nil
    var compareOverrides: String? = nil
    var missingOnly: Bool = false
}

func parseArguments() -> Arguments? {
    var args = Arguments()
    var i = 1
    while i < CommandLine.argc {
        let arg = CommandLine.arguments[i]
        switch arg {
        case "--format":
            i += 1
            guard i < CommandLine.argc else { return nil }
            args.format = CommandLine.arguments[i]
        case "--output":
            i += 1
            guard i < CommandLine.argc else { return nil }
            args.outputPath = CommandLine.arguments[i]
        case "--include-system":
            args.includeSystem = true
        case "--skip-list":
            i += 1
            guard i < CommandLine.argc else { return nil }
            args.skipListPath = CommandLine.arguments[i]
        case "--scan-host":
            i += 1
            guard i < CommandLine.argc else { return nil }
            args.scanHosts.append(CommandLine.arguments[i])
        case "--local-only":
            args.localOnly = true
        case "--hosts-file":
            i += 1
            guard i < CommandLine.argc else { return nil }
            args.hostsFile = CommandLine.arguments[i]
        case "--compare-overrides":
            i += 1
            guard i < CommandLine.argc else { return nil }
            args.compareOverrides = CommandLine.arguments[i]
        case "--missing-only":
            args.missingOnly = true
        case "--help", "-h":
            print("Usage: \(CommandLine.arguments[0]) [options]")
            print("  --format json|csv|tsv|names   Output format (default: json)")
            print("  --output FILE                 Write to file instead of stdout")
            print("  --include-system              Include Apple system apps")
            print("  --skip-list FILE              Skip list (one app per line)")
            print("  --scan-host USER@HOST         Remote host to scan over SSH")
            print("  --local-only                  Skip remote hosts")
            print("  --hosts-file FILE             Hosts file (one per line)")
            print("  --compare-overrides DIR       Compare against .munki.recipe overrides")
            print("  --missing-only                Only show apps without overrides")
            return nil
        default:
            fputs("Unknown argument: \(arg)\n", stderr)
            return nil
        }
        i += 1
    }
    return args
}

// MARK: - mdfind discovery

func runMdfind(_ query: String) -> [String] {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
    task.arguments = [query]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = nil

    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        return []
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }
    return output.split(separator: "\n", omittingEmptySubsequences: true).map { String($0) }
}

// MARK: - Info.plist parsing

struct AppInfo: Encodable {
    var name: String
    var path: String
    var bundleId: String
    var version: String
    var bundleVersion: String
}

func parseAppPlist(at path: String) -> AppInfo? {
    let infoPlistPath = (path as NSString).appendingPathComponent("Contents/Info.plist")
    guard FileManager.default.fileExists(atPath: infoPlistPath) else { return nil }

    guard let plist = NSDictionary(contentsOfFile: infoPlistPath) as? [String: Any] else { return nil }

    let bundleId = (plist["CFBundleIdentifier"] as? String) ?? ""
    let name = (plist["CFBundleDisplayName"] as? String)
        ?? (plist["CFBundleName"] as? String)
        ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")
    let version = (plist["CFBundleShortVersionString"] as? String) ?? ""
    let bundleVersion = (plist["CFBundleVersion"] as? String) ?? ""

    return AppInfo(name: name, path: path, bundleId: bundleId, version: version, bundleVersion: bundleVersion)
}

// MARK: - Helpers

func normalize(_ name: String) -> String {
    return name.lowercased().filter { $0.isLetter || $0.isNumber }
}

let DEFAULT_SYSTEM_APPS: Set<String> = [
    "app store", "automator", "books", "calculator", "calendar", "chess",
    "contacts", "dashboard", "dictionary", "facetime", "find my", "font book",
    "freeform", "home", "image capture", "keynote", "mail", "maps", "messages",
    "mission control", "music", "news", "notes", "numbers", "pages",
    "photo booth", "photos", "podcasts", "preview", "quicktime player",
    "reminders", "safari", "shortcuts", "siri", "stickies", "stocks",
    "system preferences", "system settings", "textedit", "time machine",
    "tv", "voice memos", "weather",
]

let SYSTEM_PATH_PREFIXES = [
    "/System/Library/",
    "/System/Applications/",
    "/System/i386/",
    "/usr/",
    "/bin/",
    "/sbin/",
    "/private/",
]

// MARK: - Local discovery

func gatherLocalApps(includeSystem: Bool) -> [AppInfo] {
    let queries = [
        "kMDItemKind == 'Application'",
        "kMDItemContentType == 'com.apple.application-bundle'",
    ]

    var appPaths: [String] = []
    for query in queries {
        appPaths = runMdfind(query)
        if !appPaths.isEmpty { break }
    }

    var apps: [AppInfo] = []
    var seenBundleIds: Set<String> = []

    for path in appPaths {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(".app") else { continue }

        guard let app = parseAppPlist(at: trimmed) else { continue }

        // Skip system-protected locations
        if !includeSystem {
            if SYSTEM_PATH_PREFIXES.contains(where: { app.path.hasPrefix($0) }) {
                continue
            }
        }

        // Dedup by bundle ID
        if !app.bundleId.isEmpty {
            if seenBundleIds.contains(app.bundleId) { continue }
            seenBundleIds.insert(app.bundleId)
        }

        // Skip Apple system apps by name
        if !includeSystem {
            let nameLower = app.name.lowercased()
            let nameNorm = normalize(app.name)
            if DEFAULT_SYSTEM_APPS.contains(nameLower) || DEFAULT_SYSTEM_APPS.contains(nameNorm) {
                continue
            }
        }

        apps.append(app)
    }

    apps.sort { $0.name.lowercased() < $1.name.lowercased() }
    return apps
}

// MARK: - Remote hosts (SSH)

func gatherRemoteApps(host: String, timeout: Int = 10) -> [AppInfo] {
    let sshCmd = """
    for app in /Applications/*.app ~/Applications/*.app; do
    [ -d \"$app\" ] || continue
    name=\"$(basename \"$app\" .app)\"
    version=\"$(mdls -raw -name kMDItemVersion \"$app\" 2>/dev/null)\"
    bundle_id=\"$(mdls -raw -name kMDItemCFBundleIdentifier \"$app\" 2>/dev/null)\"
    printf '%s\\t%s\\t%s\\t%s\\n' \"$name\" \"$app\" \"$bundle_id\" \"$version\"
    done
    """

    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
    task.arguments = [
        "-o", "ConnectTimeout=\(timeout)",
        "-o", "BatchMode=yes",
        host, sshCmd,
    ]

    let pipe = Pipe()
    task.standardOutput = pipe
    task.standardError = nil

    do {
        try task.run()
    } catch {
        return []
    }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    guard let output = String(data: data, encoding: .utf8) else { return [] }

    var apps: [AppInfo] = []
    for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
        let parts = String(line).split(separator: "\t", omittingEmptySubsequences: false)
        guard parts.count >= 1 else { continue }
        apps.append(AppInfo(
            name: String(parts[0]),
            path: parts.count > 1 ? String(parts[1]) : "",
            bundleId: parts.count > 2 ? String(parts[2]) : "",
            version: parts.count > 3 ? String(parts[3]) : "",
            bundleVersion: ""
        ))
    }
    return apps
}

// MARK: - Skip list

func loadSkipList(path: String?) -> Set<String> {
    guard let path = path, FileManager.default.fileExists(atPath: path) else { return [] }
    guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return Set(contents.split(separator: "\n", omittingEmptySubsequences: true)
        .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty && !$0.hasPrefix("#") }
        .map { $0.lowercased() })
}

// MARK: - Override comparison

func loadOverrideNames(directory: String?) -> Set<String> {
    guard let directory = directory,
          let enumerator = FileManager.default.enumerator(atPath: directory) else { return [] }

    var names: Set<String> = []

    for case let file as String in enumerator {
        guard file.hasSuffix(".munki.recipe") || file.hasSuffix(".recipe") else { continue }

        let fullPath = (directory as NSString).appendingPathComponent(file)
        var baseName = file
        if baseName.hasSuffix(".munki.recipe") {
            baseName = String(baseName.dropLast(".munki.recipe".count))
        } else if baseName.hasSuffix(".recipe") {
            baseName = String(baseName.dropLast(".recipe".count))
        }
        names.insert(baseName.lowercased())

        // Also try reading NAME key from plist
        if let plist = NSDictionary(contentsOfFile: fullPath) as? [String: Any],
           let recipeName = plist["NAME"] as? String {
            names.insert(recipeName.lowercased())
        }
    }
    return names
}

// MARK: - Output formatting

func formatOutput(apps: [AppInfo], format: String) -> String {
    switch format {
    case "names":
        return apps.map { $0.name }.joined(separator: "\n")

    case "tsv":
        var lines = ["name\tpath\tbundle_id\tversion\tbundle_version"]
        for app in apps {
            lines.append("\(app.name)\t\(app.path)\t\(app.bundleId)\t\(app.version)\t\(app.bundleVersion)")
        }
        return lines.joined(separator: "\n")

    case "csv":
        var lines = ["name,path,bundle_id,version,bundle_version"]
        for app in apps {
            func csvQuote(_ s: String) -> String {
                let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\""
            }
            lines.append("\(csvQuote(app.name)),\(csvQuote(app.path)),\(csvQuote(app.bundleId)),\(csvQuote(app.version)),\(csvQuote(app.bundleVersion))")
        }
        return lines.joined(separator: "\n")

    case "json":
        var json = "[\n"
        for (index, app) in apps.enumerated() {
            json += "    {\n"
            json += "        \"name\": \(jsonString(app.name)),\n"
            json += "        \"path\": \(jsonString(app.path)),\n"
            json += "        \"bundle_id\": \(jsonString(app.bundleId)),\n"
            json += "        \"version\": \(jsonString(app.version)),\n"
            json += "        \"bundle_version\": \(jsonString(app.bundleVersion))\n"
            json += "    }"
            if index < apps.count - 1 { json += "," }
            json += "\n"
        }
        json += "]"
        return json

    default:
        return formatOutput(apps: apps, format: "json")
    }
}

func jsonString(_ s: String) -> String {
    var result = "\""
    for char in s {
        switch char {
        case "\"": result += "\\\""
        case "\\": result += "\\\\"
        case "\n": result += "\\n"
        case "\r": result += "\\r"
        case "\t": result += "\\t"
        default:
            let value = char.unicodeScalars.first?.value ?? 0
            if value < 0x20 {
                result += String(format: "\\u%04x", value)
            } else {
                result.append(char)
            }
        }
    }
    result += "\""
    return result
}

// MARK: - Main

guard let args = parseArguments() else {
    exit(1)
}

// Local discovery
var allApps = gatherLocalApps(includeSystem: args.includeSystem)

// Apply skip list
let skipSet = loadSkipList(path: args.skipListPath)
if !skipSet.isEmpty {
    allApps = allApps.filter { app in
        !skipSet.contains(app.name.lowercased()) && !skipSet.contains(normalize(app.name))
    }
}

// Remote hosts
if !args.localOnly {
    var hosts: [String] = []
    if let hostsFile = args.hostsFile, FileManager.default.fileExists(atPath: hostsFile),
       let contents = try? String(contentsOfFile: hostsFile, encoding: .utf8) {
        hosts += contents.split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }
    hosts += args.scanHosts

    for host in hosts {
        let remoteApps = gatherRemoteApps(host: host)
        for app in remoteApps {
            if !skipSet.contains(app.name.lowercased()) && !skipSet.contains(normalize(app.name)) {
                allApps.append(app)
            }
        }
    }
}

// De-duplicate by name
var seenNames: Set<String> = []
var uniqueApps: [AppInfo] = []
for app in allApps {
    let key = app.name.lowercased()
    if seenNames.insert(key).inserted {
        uniqueApps.append(app)
    }
}
allApps = uniqueApps

// Compare against overrides
var outputApps = allApps
if let overrideDir = args.compareOverrides {
    let existing = loadOverrideNames(directory: overrideDir)
    outputApps = allApps.filter { app in
        let nameLower = app.name.lowercased()
        let nospace = normalize(app.name)
        return !existing.contains(nameLower) && !existing.contains(nospace)
    }
}

if args.missingOnly && args.compareOverrides == nil {
    fputs("Warning: --missing-only requires --compare-overrides\n", stderr)
}

let output = formatOutput(apps: outputApps, format: args.format)

if let outputPath = args.outputPath {
    try? output.write(toFile: outputPath, atomically: true, encoding: .utf8)
    fputs("Wrote \(outputApps.count) application(s) to \(outputPath)\n", stderr)
} else {
    print(output)
}
