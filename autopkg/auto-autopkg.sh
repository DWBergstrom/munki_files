#!/bin/bash

CURRENT_DATE=$(date "+%Y-%m-%d %H:%M:%S")

# Define the directory containing the overrides
OVERRIDES_DIR="/Users/dwbergstrom/git/munki_files/autopkg/overrides"

# Run autopkg for each override in the directory
for override in "$OVERRIDES_DIR"/*; do
  autopkg run -v "$override"
done

# Get the current date
current_date=$(date +%Y%m%d)

# Check for new overrides and run add-pkg for each
while IFS= read -r new_override; do
  installer_name=$(xmllint --xpath 'string(//key[.="NAME"]/following-sibling::string[1])' "$new_override")
  manifestutil add-pkg "$installer_name" --manifest site_default --section managed_updates
done < <(find "$OVERRIDES_DIR" -type f -newermt "$current_date")

# Run makecatalogs
makecatalogs

# Serve munki repo via tailscale
tailscale funnel /Users/dwbergstrom/git/munki_files/munki_web/munki_repo&

# Save changes to git
git add --all
git commit -m "$CURRENT_DATE Updating munki"
git push origin main
