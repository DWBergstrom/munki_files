#!/bin/bash

# Define the directory containing the overrides
OVERRIDES_DIR="/Users/dwbergstrom/github/munki_files/autopkg/overrides"

# Define Munki repo path
MUNKI_REPO_PATH="/Volumes/2TB WD/munki_files/munki_web/munki_repo/"
RSYNC_PATH="/Users/dwbergstrom/github/munki_files"
WEBSERVER_IP=$(/Applications/Tailscale.app/Contents/MacOS/Tailscale status | grep ubuntun20 | awk '{ print $1 }')
WEBSERVER_SYNC_PATH="/home/dwbergstrom/git/"

# Verbose options
if [ $# -gt 0 ]; then
  if [ "$1" = "--rsync-only" ] || [ "$1" = "-r" ]; then
    # Only run the rsync command
    rsync -avz "${RSYNC_PATH}" "dwbergstrom@${WEBSERVER_IP}:${WEBSERVER_SYNC_PATH}"
    exit 0
  else
    echo "running single override ${OVERRIDES_DIR}/${1}"
    /usr/local/bin/autopkg run -v ${OVERRIDES_DIR}/${1}
    rsync -avz "${RSYNC_PATH}" "dwbergstrom@${WEBSERVER_IP}:${WEBSERVER_SYNC_PATH}"
    exit 0
  fi
else
  AUTOPKG_CMD="/usr/local/bin/autopkg run -v"
fi

COMMIT_DATE=$(date "+%Y-%m-%d %H:%M:%S")

# Clean up old apps
repoclean -k 1 -a $MUNKI_REPO_PATH

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
/usr/local/munki/makecatalogs --skip-pkg-check "$MUNKI_REPO_PATH"

# Serve munki repo via tailscale
# echo "setting up tailscale funnel..."
# /Users/dwbergstrom/git/munki_files/munki_web/munki_repo&

# Save changes to git
echo "Changing to munki directory"
cd "${RSYNC_PATH}"
git add --all
git status
echo "Printing date for logging:  ${current_date}"
git commit -m "$COMMIT_DATE Updating munki"
git push origin main

rsync -avz "${RSYNC_PATH}" "dwbergstrom@${WEBSERVER_IP}:${WEBSERVER_SYNC_PATH}"
