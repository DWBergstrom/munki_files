#!/bin/bash

# Verbose options
if [ $# -gt 0 ]; then
  AUTOPKG_CMD="/usr/local/bin/autopkg run ${1}"
  else
  AUTOPKG_CMD="/usr/local/bin/autopkg run"
fi

COMMIT_DATE=$(date "+%Y-%m-%d %H:%M:%S")

# Define the directory containing the overrides
OVERRIDES_DIR="/Users/dwbergstrom/github/munki_files/autopkg/overrides"

# Define Munki repo path
MUNKI_REPO_PATH="/Users/dwbergstrom/github/munki_files/munki_web/munki_repo"
RSYNC_PATH="/Users/dwbergstrom/github/munki_files"
WEBSERVER_IP="100.123.110.99"
WEBSERVER_SYNC_PATH="/home/dwbergstrom/git/"

# Clean up old apps
# rm -Rf "${MUNKI_REPO_PATH}/pkgs/"*

# Run autopkg for each override in the directory
for override in "$OVERRIDES_DIR"/*; do
  eval "${AUTOPKG_CMD} ${override}"
done

# Get the current date
current_date=$(date +%Y%m%d)

# Check for new overrides and run add-pkg for each
while IFS= read -r new_override; do
  installer_name=$(xmllint --xpath 'string(//key[.="NAME"]/following-sibling::string[1])' "$new_override")
  manifestutil add-pkg "$installer_name" --manifest site_default --section managed_updates
done < <(find "$OVERRIDES_DIR" -type f -newermt "$current_date")

# Run makecatalogs
echo "Running makecatalogs..."
makecatalogs --skip-pkg-check "$MUNKI_REPO_PATH"

# Serve munki repo via tailscale
# echo "setting up tailscale funnel..."
# /Users/dwbergstrom/git/munki_files/munki_web/munki_repo&

# Save changes to git
git add --all
git status
git commit -m "$COMMIT_DATE Updating munki"
git push origin main

rsync -avz ssh "${RSYNC_PATH}" "dwbergstrom@${WEBSERVER_IP}:${WEBSERVER_SYNC_PATH}"
