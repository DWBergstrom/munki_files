# Munki Files Repository

This repository contains AutoPkg recipes, Munki repository files, and automation scripts for managing software distribution via Munki.

## AutoPkg Automation Script (`auto-autopkg-ts.sh`)

The `auto-autopkg-ts.sh` script automates the process of running AutoPkg recipes, updating the Munki repository, and serving it via Tailscale. It can be run manually or automatically via a macOS LaunchAgent.

### Prerequisites

Before using the script, ensure the following software is installed:

1. **Tailscale** - Required for serving the Munki repository
   - Install from: https://tailscale.com/download/macos
   - Must be signed in and connected to your tailnet

2. **Python 3** - Required for the HTTP server
   - Usually pre-installed on macOS, or install via Homebrew: `brew install python3`

3. **AutoPkg** - Required for recipe processing
   - Install from: https://github.com/autopkg/autopkg/releases
   - Or via Homebrew: `brew install autopkg`

4. **Munki** - Required for repository management
   - Install from: https://github.com/munki/munki/releases
   - Munki tools should be installed in `/usr/local/munki/`

5. **1Password CLI** (Optional) - For retrieving GitHub token
   - Install from: https://developer.1password.com/docs/cli/get-started
   - If not installed, the script will warn but continue without GitHub token support

### macOS Security Requirements

**IMPORTANT**: LaunchAgents require Full Disk Access to access external volumes and perform file operations.

#### Grant Full Disk Access

1. Open **System Settings** (or **System Preferences** on older macOS)
2. Navigate to **Privacy & Security** → **Full Disk Access**
3. Click the **+** button to add an application
4. Add `/bin/bash` (or your terminal application like Terminal.app or iTerm.app)
5. Ensure the checkbox is enabled for the added application
6. Restart your Mac or reload the LaunchAgent for changes to take effect

**Note**: Without Full Disk Access, you will see errors like:
- `Operation not permitted`
- `getcwd: cannot access parent directories`
- `fatal: Unable to read current working directory`

### Configuration

#### 1. Update Volume Name

Edit `auto-autopkg-ts.sh` and update the `VOLUME_NAME` variable to match your external volume:

```bash
VOLUME_NAME="M4_Dock"  # Change this to your volume name
```

#### 2. Update LaunchAgent Paths

Edit `com.dwbergstrom.auto-autopkg-ts.plist` and update the script path to match your setup:

```xml
<string>/Users/YOUR_USERNAME/github/munki_files/autopkg/auto-autopkg-ts.sh</string>
```

Also update the log file paths if needed:

```xml
<string>/Users/YOUR_USERNAME/Library/Logs/auto-autopkg-ts.err</string>
<string>/Users/YOUR_USERNAME/Library/Logs/auto-autopkg-ts.out</string>
```

#### 3. Configure Tailscale Serve

The script expects your Tailscale machine to be named `coherence`. If your machine has a different name, update the `WEBSERVER_NAME` variable in the script:

```bash
WEBSERVER_NAME="coherence"  # Change to your Tailscale machine name
```

#### 4. GitHub Token (Optional)

If you have 1Password CLI installed, create a 1Password item named "GitHub - Autopkg" with a field called "token" containing your GitHub personal access token. This allows AutoPkg to access GitHub repositories without rate limiting.

### Setup LaunchAgent

1. Copy the LaunchAgent plist to your LaunchAgents directory:

```bash
cp autopkg/com.dwbergstrom.auto-autopkg-ts.plist ~/Library/LaunchAgents/
```

2. Update the plist file paths as described in the Configuration section above.

3. Load the LaunchAgent:

```bash
launchctl load ~/Library/LaunchAgents/com.dwbergstrom.auto-autopkg-ts.plist
```

4. Verify it's loaded:

```bash
launchctl list | grep auto-autopkg-ts
```

### Manual Execution

You can also run the script manually:

```bash
cd /Volumes/M4_Dock/munki_files/autopkg
./auto-autopkg-ts.sh
```

#### Script Options

- **Default behavior**: Runs all overrides, updates catalogs, and commits changes to git
- `--make-overrides RECIPE1 RECIPE2 ...`: Create override files for specified recipes
- `--run-overrides RECIPE`: Run a specific override recipe

Examples:

```bash
# Create an override for a recipe
./auto-autopkg-ts.sh --make-overrides GoogleChrome.munki.recipe

# Run a specific override
./auto-autopkg-ts.sh --run-overrides GoogleChrome.munki.recipe
```

### Schedule

The LaunchAgent is configured to run daily at 12:45 AM (00:45). To change the schedule, edit the `StartCalendarInterval` section in the plist:

```xml
<key>StartCalendarInterval</key>
<dict>
    <key>Hour</key>
    <integer>0</integer>      <!-- 0-23 -->
    <key>Minute</key>
    <integer>45</integer>     <!-- 0-59 -->
</dict>
```

### Logs

The script logs output to:
- **Standard output**: `~/Library/Logs/auto-autopkg-ts.out`
- **Standard error**: `~/Library/Logs/auto-autopkg-ts.err`

View logs in real-time:

```bash
tail -f ~/Library/Logs/auto-autopkg-ts.out
tail -f ~/Library/Logs/auto-autopkg-ts.err
```

### Troubleshooting

#### "Operation not permitted" errors

- Ensure Full Disk Access is granted to `/bin/bash` or your terminal app
- Verify the external volume is mounted and accessible
- Check that the volume name matches the `VOLUME_NAME` variable in the script

#### "Munki could not be found" error

- Verify Munki is installed: `which managedsoftwareupdate`
- Ensure `/usr/local/munki` is in the PATH (already configured in the plist)

#### "Tailscale could not be found" error

- Verify Tailscale is installed: `which tailscale`
- Ensure Tailscale is running and you're signed in: `tailscale status`

#### Python HTTP server fails to start

- Verify Python 3 is installed: `which python3`
- Check if port 8080 is already in use: `lsof -i :8080`
- The script will attempt to kill existing processes on port 8080

#### Git operations fail

- Ensure the Munki repository directory is a git repository
- Verify git credentials are configured (SSH keys or credential helper)
- Check that the external volume is mounted and accessible

#### LaunchAgent not running

- Check if it's loaded: `launchctl list | grep auto-autopkg-ts`
- Check logs for errors: `tail -f ~/Library/Logs/auto-autopkg-ts.err`
- Unload and reload: 
  ```bash
  launchctl unload ~/Library/LaunchAgents/com.dwbergstrom.auto-autopkg-ts.plist
  launchctl load ~/Library/LaunchAgents/com.dwbergstrom.auto-autopkg-ts.plist
  ```

### Repository Structure

```
munki_files/
├── autopkg/
│   ├── auto-autopkg-ts.sh          # Main automation script
│   ├── com.dwbergstrom.auto-autopkg-ts.plist  # LaunchAgent configuration
│   ├── autopkg-repos                # List of AutoPkg recipe repositories
│   ├── overrides/                   # AutoPkg recipe overrides
│   └── archived_overrides/          # Archived recipe overrides
└── munki_web/
    └── munki_repo/                  # Munki repository
        ├── catalogs/                 # Software catalogs
        ├── manifests/                # Client manifests
        ├── pkgs/                     # Package files
        ├── pkgsinfo/                 # Package metadata
        └── icons/                    # Application icons
```

### Additional Notes

- The script uses absolute paths to avoid working directory issues when running from LaunchAgents
- Git operations use `git -C` instead of `cd` to prevent permission errors
- The script automatically starts a Python HTTP server on port 8080 and configures Tailscale to serve it
- All file operations check for accessibility before proceeding

