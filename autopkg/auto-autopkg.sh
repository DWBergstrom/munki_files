#!/bin/bash

#TODO:
# - Convert if statements to case statements for parameters
# - Add autopkg verify function
# - Move blocks into functions where possible
# - Add error handling for rsync and tailscale
# - Reorder when functions are created
# - Add logging

#TODO with synology webserver
# - update rsync paths

# Parameter check
if [ $# -eq 0 ]; then
  echo "Usage: auto-autopkg.sh [--all / -a] [--rsync-only / -r] [override.name]"
  exit 1
fi

# Volume name
VOLUME_NAME="1TB-Toshiba"
echo "Volume name: $VOLUME_NAME"

# Tailscale command
TAILSCALE_CMD="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
echo "Tailscale command: $TAILSCALE_CMD"

# Verify the munki volume is mounted
if ! mount | grep -q "$VOLUME_NAME"; then
  echo "Volume $VOLUME_NAME is not mounted - unable to access munki files. Please mount it and try again."
  exit 1
else
  echo "Volume $VOLUME_NAME is mounted - continuing."
fi

# Define the override directory
OVERRIDES_DIR="/Volumes/${VOLUME_NAME}/munki_files/autopkg/overrides"
echo "Overrides directory: $OVERRIDES_DIR"

# Define Munki  and autopkg variables
REPOCLEAN_VERSIONS="1"
MUNKI_REPO_PATH="/Volumes/${VOLUME_NAME}/munki_files/munki_web/munki_repo/"
RSYNC_PATH="/Volumes/${VOLUME_NAME}/munki_files/munki_web/"
WEBSERVER_NAME="everything-book"
WEBSERVER_STATUS=""
if $TAILSCALE_CMD status | grep $WEBSERVER_NAME | grep "offline" > /dev/null; then
  WEBSERVER_STATUS="offline"
  else
    WEBSERVER_STATUS="online"
fi
WEBSERVER_SYNC_PATH="/volume1/serve"
AUTOPKG_CMD="/usr/local/bin/autopkg run -v"

# Verify autopkg settings
function verify_autopkg_settings {
  defaults write com.github.autopkg RECIPE_OVERRIDE_DIRS $OVERRIDES_DIR
  defaults write com.github.autopkg MUNKI_REPO $MUNKI_REPO_PATH
  autopkg repo-update all
}

if [ $# -gt 0 ]; then
  if [ "$1" = "--rsync-only" ] || [ "$1" = "-r" ]; then
    # Only run the rsync command
    if [ $WEBSERVER_STATUS == "online" ]; then
      # host config in ~/.ssh/config
      rsync -avz "${RSYNC_PATH}" "${WEBSERVER_NAME}:${WEBSERVER_SYNC_PATH}"
      else
      echo "Tailscale Synology server $WEBSERVER_NAME is offline - unable to rsync."
    fi
    exit 0
  elif [ "$1" = "--all" ] || [ "$1" = "-a" ]; then
    echo "Running autopkg for all overrides in ${OVERRIDES_DIR}"
  else
    echo "Checking for single override ${1} in ${OVERRIDES_DIR}"
    if [ -f "${OVERRIDES_DIR}/${1}" ]; then
      echo "Running single override ${1}"
      verify_autopkg_settings
      /usr/local/bin/autopkg run -v ${OVERRIDES_DIR}/${1}
      if [ $WEBSERVER_STATUS == "online" ]; then
        rsync -avz "${RSYNC_PATH}" "${WEBSERVER_NAME}:${WEBSERVER_SYNC_PATH}"
      else
        echo "Tailscale server $WEBSERVER_NAME is offline - unable to rsync."
      fi
    else
      echo "Override ${1} not found in ${OVERRIDES_DIR}"
      exit 1
    fi
    exit 0
  fi
else
  echo "Usage: auto-autopkg.sh [--all / -a] [--rsync-only / -r] [override.name]"
  exit 1
fi

COMMIT_DATE=$(date "+%Y-%m-%d %H:%M:%S")

# Clean up old apps
echo "Running repoclean..."
repoclean -k $REPOCLEAN_VERSIONS -a $MUNKI_REPO_PATH

# Run autopkg for each override in the directory
verify_autopkg_settings
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

if [ $WEBSERVER_STATUS == "online" ]; then
  rsync -avz "${RSYNC_PATH}" "${WEBSERVER_NAME}:${WEBSERVER_SYNC_PATH}"
else
  echo "Tailscale server $WEBSERVER_NAME is offline - unable to rsync."
fi
