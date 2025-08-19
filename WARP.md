# WARP.md

This file provides guidance to WARP (warp.dev) when working with code in this repository.

## Repository Overview

This repository manages a macOS software distribution system using AutoPkg and Munki. It automates the process of downloading, packaging, and cataloging software updates for managed Mac clients. The system consists of AutoPkg recipe overrides, a Munki repository structure, and automation scripts.

## Architecture

### Core Components

**AutoPkg Layer (`autopkg/` directory)**
- `overrides/` - Contains 21+ recipe override files (.recipe) that customize how software is processed
- `auto-autopkg.sh` - Main automation script that orchestrates the entire update process
- `com.dwbergstrom.auto-autopkg.plist` - LaunchAgent configuration for scheduled execution
- `archived_overrides/` - Contains disabled/archived recipe overrides
- `postinstall_scripts/` - Custom post-installation scripts (currently contains 1Password scripts)

**Munki Repository (`munki_web/munki_repo/` directory)**
- `catalogs/` - Contains software catalog files (development, testing, production)
- `pkgs/` - Binary packages organized by application
- `pkgsinfo/` - Metadata files describing each package
- `manifests/` - Client manifest files defining what software should be installed
- `icons/` - Application icons for display in Managed Software Center

**Workflow Integration**
- Git version control tracks all changes with automated commits
- Rsync deployment to remote Ubuntu server via Tailscale VPN
- LaunchAgent runs daily at 12:45 AM for automated updates

## Common Development Commands

### AutoPkg Operations
```bash
# Run all recipe overrides (full automation)
./autopkg/auto-autopkg.sh

# Run a single recipe override
./autopkg/auto-autopkg.sh RecipeName.munki.recipe

# Run only the rsync deployment (skip AutoPkg processing)
./autopkg/auto-autopkg.sh --rsync-only
# or
./autopkg/auto-autopkg.sh -r

# Run AutoPkg directly for a specific override
/usr/local/bin/autopkg run -v autopkg/overrides/RecipeName.munki.recipe

# List all available recipes
find autopkg/overrides/ -name "*.recipe" -exec basename {} \;
```

### Munki Repository Management
```bash
# Clean up old package versions (keep only 1 version)
repoclean -k 1 -a munki_web/munki_repo

# Rebuild catalogs after manual changes
/usr/local/munki/makecatalogs --skip-pkg-check munki_web/munki_repo

# Add a package to the default manifest
manifestutil add-pkg "AppName" --manifest site_default --section managed_updates

# Remove a package from a manifest
manifestutil remove-pkg "AppName" --manifest site_default

# List all manifests
manifestutil list-manifests

# View manifest contents
manifestutil display-manifest site_default
```

### LaunchAgent Management
```bash
# Load the scheduled automation job
launchctl load ~/Library/LaunchAgents/com.dwbergstrom.auto-autopkg.plist

# Unload the scheduled automation job
launchctl unload ~/Library/LaunchAgents/com.dwbergstrom.auto-autopkg.plist

# Check if the job is loaded
launchctl list | grep auto-autopkg

# View automation logs
tail -f ~/Library/Logs/auto-autopkg.out
tail -f ~/Library/Logs/auto-autopkg.err
```

### Recipe Override Management
```bash
# Create a new recipe override (interactive)
/usr/local/bin/autopkg make-override ParentRecipeName.munki --name=local.munki.AppName

# Move recipe override to archive (disable)
mv autopkg/overrides/AppName.munki.recipe autopkg/archived_overrides/

# Reactivate an archived override
mv autopkg/archived_overrides/AppName.munki.recipe autopkg/overrides/
```

### Git Operations
```bash
# View recent automation commits
git --no-pager log --oneline -10

# Check repository status
git status

# Manual commit (automation normally handles this)
git add --all
git commit -m "Manual update to munki repository"
git push origin main
```

## Key Configuration Details

### Automation Script Behavior
- Runs `repoclean` to maintain only 1 version of each package
- Processes all recipe overrides in the `overrides/` directory
- Automatically adds new packages to the `site_default` manifest
- Rebuilds Munki catalogs with `makecatalogs`
- Commits changes to git with timestamp
- Syncs to remote Ubuntu server via rsync over Tailscale

### Recipe Override Structure
Each `.recipe` file in `overrides/` configures:
- Target application name and version detection
- Munki repository subdirectory (`apps/AppName`)
- Catalog assignment (typically `testing`)
- Package metadata (description, developer, display name)
- Parent recipe references with trust verification

### Scheduled Execution
The LaunchAgent runs the automation daily at 12:45 AM, with logs written to:
- `/Users/dwbergstrom/Library/Logs/auto-autopkg.out` (stdout)
- `/Users/dwbergstrom/Library/Logs/auto-autopkg.err` (stderr)

### Remote Deployment
Changes are automatically deployed to a remote Ubuntu server:
- Target: `dwbergstrom@TAILSCALE_IP:/home/dwbergstrom/git/`
- Method: rsync over Tailscale VPN
- Tailscale IP dynamically resolved from device status

## Troubleshooting

### Failed AutoPkg Runs
```bash
# Check AutoPkg verbose output for specific recipe
/usr/local/bin/autopkg run -vv autopkg/overrides/ProblemApp.munki.recipe

# Verify recipe parent trust
/usr/local/bin/autopkg verify-trust-info autopkg/overrides/ProblemApp.munki.recipe
```

### Repository Issues
```bash
# Verify repository structure
/usr/local/munki/makecatalogs --skip-pkg-check munki_web/munki_repo

# Check for broken package references
find munki_web/munki_repo/pkgsinfo -name "*.plist" -exec plutil -lint {} \;
```

### Network/Sync Issues
```bash
# Test Tailscale connectivity
/Applications/Tailscale.app/Contents/MacOS/Tailscale status

# Manual rsync test
rsync -avz --dry-run munki_web/munki_repo/ dwbergstrom@TAILSCALE_IP:/home/dwbergstrom/git/munki_files/munki_web/munki_repo/
```

## Development Workflow

1. **Adding New Software**: Create recipe override in `overrides/` directory
2. **Testing Changes**: Run single recipe override to test before full automation
3. **Monitoring**: Check automation logs for successful execution
4. **Deployment**: Changes automatically sync to remote server for client access
5. **Maintenance**: Periodically review and archive unused recipe overrides
