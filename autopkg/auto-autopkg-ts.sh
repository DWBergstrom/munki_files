#!/bin/bash

# logging functions
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color
log() {
	echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
}
error() {
	echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')][ERROR]${NC} $1" >&2
}
warn() {
	echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')][WARNING]${NC} $1"
}
info() {
	echo -e "${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')][INFO]${NC} $1"
}

log "executing auto-autopkg-ts.sh from ${PWD}"

# Prerequisites checks
# Verify tailscale is installed
log "verifying tailscale is installed..."
if ! TAILSCALE_CMD=$(command -v tailscale) &> /dev/null; then
	error "Tailscale could not be found. Please install Tailscale and try again."
	exit 1
else
	log "Tailscale is installed at ${TAILSCALE_CMD}"
fi
# Verify python3 is installed
log "verifying python3 is installed..."
if ! PYTHON_CMD=$(command -v python3) &> /dev/null; then
	error "Python3 could not be found. Please install Python3 and try again."
	exit 1
else
	log "Python3 is installed at ${PYTHON_CMD}"
fi
# Verify autopkg is installed
log "verifying autopkg is installed..."
if ! AUTOPKG_CMD=$(command -v autopkg) &> /dev/null; then
	error "Autopkg could not be found. Please install Autopkg and try again."
	exit 1
else
	log "Autopkg is installed at ${AUTOPKG_CMD}"
fi
# Verify munki is installed
log "verifying munki is installed..."
if ! MANAGEDSOFTWAREUPDATE_CMD=$(command -v managedsoftwareupdate) &> /dev/null; then
	error "Munki could not be found. Please install Munki and try again."
	exit 1
else
	log "Munki is installed at ${MANAGEDSOFTWAREUPDATE_CMD}"
fi
# Verify 1Password CLI is installed (optional)
log "verifying 1password CLI is installed..."
if ! OP_CMD=$(command -v op) &> /dev/null; then
	warn "1Password CLI could not be found. Will not be able to update github token for autopkg."
else
	log "1Password CLI is installed at ${OP_CMD}"
fi

# Get github token for autopkg (optional)
log "verifying github token for autopkg..."
GITHUB_TOKEN=$(op item get "GitHub - Autopkg" --fields token)
if [ -z "${GITHUB_TOKEN}" ]; then
	error "Github token for autopkg not found. Add to 1Password when possible."
else
	log "Github token for autopkg: ${GITHUB_TOKEN}"
fi

# Config variables
# Volume name
VOLUME_NAME="M4_Dock"
log "Munki volume name: ${VOLUME_NAME}"
# Define Munki  and autopkg variables
REPOCLEAN_VERSIONS="1"
AUTOPKG_DIR="/Volumes/${VOLUME_NAME}/munki_files/autopkg"
MUNKI_REPO_PATH="/Volumes/${VOLUME_NAME}/munki_files/munki_web/munki_repo/"
# Define the override directory
OVERRIDES_DIR="/Volumes/${VOLUME_NAME}/munki_files/autopkg/overrides"
AUTOPKG_REPOS_FILE="${AUTOPKG_DIR}/autopkg-repos"

# Verify volume is mounted
if [ ! -d "${AUTOPKG_DIR}" ]; then
	error "Volume ${VOLUME_NAME} is not mounted or accessible at ${AUTOPKG_DIR}"
	exit 1
fi
log "Autopkg directory verified: ${AUTOPKG_DIR}"

# Munki repo webserver check
WEBSERVER_NAME="coherence"
WEBSERVER_PORT="8080"
WEBSERVER_STATUS=""
if $TAILSCALE_CMD status | grep $WEBSERVER_NAME | grep "offline" > /dev/null; then
	WEBSERVER_STATUS="offline"
else
	WEBSERVER_STATUS="online as $WEBSERVER_NAME"
fi
log "Webserver host status: ${WEBSERVER_STATUS}"
# Check if python server is running
PYTHON_SERVER_STATUS=""
if pgrep -f "http.server" > /dev/null; then
	PYTHON_SERVER_STATUS="running...restarting"
	kill -9 $(pgrep -f "http.server") 2>/dev/null
	sleep 1
fi

# Start Python server using a subshell with cd to avoid getcwd() issues when running from LaunchAgent
log "Starting Python server..."
(cd "${MUNKI_REPO_PATH}" && python3 -m http.server ${WEBSERVER_PORT} --bind 127.0.0.1 >/dev/null 2>&1) &
PYTHON_SERVER_PID=$!

# Wait a moment for server to start and verify it's responding
sleep 2
if curl -s -o /dev/null -w "%{http_code}" "http://127.0.0.1:${WEBSERVER_PORT}/" | grep -q "200\|301\|302"; then
	PYTHON_SERVER_STATUS="running"
	log "Python server status: ${PYTHON_SERVER_STATUS} at http://127.0.0.1:${WEBSERVER_PORT}"
else
	PYTHON_SERVER_STATUS="started but not responding"
	warn "Python server status: ${PYTHON_SERVER_STATUS} - may need a moment to start"
fi

# Check if tailscale is serving the munki repo
TAILSCALE_SERVING_STATUS=""
TAILSCALE_URL=""
# Extract the Tailscale URL from serve status
TAILSCALE_SERVE_OUTPUT=$($TAILSCALE_CMD serve status 2>/dev/null)
if echo "${TAILSCALE_SERVE_OUTPUT}" | grep -q "/munki"; then
	# Extract the base URL (e.g., https://coherence.tail8eea7.ts.net)
	TAILSCALE_URL=$(echo "${TAILSCALE_SERVE_OUTPUT}" | grep -E "^https://.*\.ts\.net" | head -1 | awk '{print $1}' | sed 's/ (tailnet only)//')
	if [ -n "${TAILSCALE_URL}" ]; then
		TAILSCALE_SERVING_STATUS="serving"
		log "Tailscale serving status: ${TAILSCALE_SERVING_STATUS} at ${TAILSCALE_URL}/munki"
	else
		TAILSCALE_SERVING_STATUS="configured but URL not found"
		warn "Tailscale serving status: ${TAILSCALE_SERVING_STATUS}"
	fi
else
	TAILSCALE_SERVING_STATUS="not serving"
	log "Tailscale serving status: ${TAILSCALE_SERVING_STATUS}"
	log "Attempting to start tailscale serve..."
	# Clear any existing configuration first, then set the new path
	$TAILSCALE_CMD serve --reset 2>/dev/null
	sleep 1
	if $TAILSCALE_CMD serve --bg --set-path /munki "http://127.0.0.1:${WEBSERVER_PORT}/" 2>/dev/null; then
		sleep 2
		# Get fresh status after configuration
		TAILSCALE_SERVE_OUTPUT=$($TAILSCALE_CMD serve status 2>/dev/null)
		TAILSCALE_URL=$(echo "${TAILSCALE_SERVE_OUTPUT}" | grep -E "^https://.*\.ts\.net" | head -1 | awk '{print $1}' | sed 's/ (tailnet only)//')
		if [ -n "${TAILSCALE_URL}" ]; then
			log "Tailscale serve configured at ${TAILSCALE_URL}/munki"
		else
			warn "Tailscale serve configured but URL not available yet - check with 'tailscale serve status'"
		fi
	else
		error "Failed to configure Tailscale serve"
	fi
fi

# rsync options checks
RSYNC_URL=""
RSYNC_DESTINATION_PATH=""

function verify_autopkg_settings {
	defaults write com.github.autopkg RECIPE_OVERRIDE_DIRS "${OVERRIDES_DIR}"
	defaults write com.github.autopkg MUNKI_REPO "${MUNKI_REPO_PATH}"
	defaults write com.github.autopkg GITHUB_TOKEN "${GITHUB_TOKEN}"
	if [ ! -f "${AUTOPKG_REPOS_FILE}" ]; then
		error "autopkg-repos file not found at ${AUTOPKG_REPOS_FILE}"
		exit 1
	fi
	for repo in $(cat "${AUTOPKG_REPOS_FILE}"); do
		"${AUTOPKG_CMD}" repo-add "${repo}"
	done
	log "Autopkg recipe override directory: $(defaults read com.github.autopkg RECIPE_OVERRIDE_DIRS)"
	log "Autopkg munki repo: $(defaults read com.github.autopkg MUNKI_REPO)"
}

function verify_munki_settings {
	# Check if running from launch agent (no TTY available)
	if [ -t 0 ] && [ -t 1 ]; then
		if $(defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL) != "${TAILSCALE_URL}/munki"; then
			log "Setting Munki repo URL to ${TAILSCALE_URL}/munki - will prompt for sudo password"
			sudo defaults write /Library/Preferences/ManagedInstalls SoftwareRepoURL "${TAILSCALE_URL}/munki"
			log "Munki repo URL: $(defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL)"
		else
			log "Munki repo URL is already set to ${TAILSCALE_URL}/munki"
		fi
	else
		warn "Running from launch agent - skipping Munki settings update (requires sudo)"
		log "Current Munki repo URL: $(defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL 2>/dev/null || echo 'Unable to read - may require sudo')"
	fi
}

function run_repoclean {
	log "Running repoclean..."
	repoclean_output=$(mktemp)
	if repoclean -k "${REPOCLEAN_VERSIONS}" -a "${MUNKI_REPO_PATH}" > >(tee -a "${repoclean_output}") 2> >(tee -a "${repoclean_output}" >&2); then
		# Check for trust verification errors
		if grep -q "Failed local trust verification" "${repoclean_output}" 2>/dev/null; then
			trust_error_count=$(grep -c "Failed local trust verification" "${repoclean_output}" 2>/dev/null || echo "0")
			if [ "${trust_error_count}" -gt 0 ]; then
				warn "[repoclean] Failed local trust verification (${trust_error_count} error(s))"
			fi
		fi
	fi
	rm -f "${repoclean_output}"
}

function run_all_overrides {
	log "Running autopkg repo-update all..."
	"${AUTOPKG_CMD}" repo-update all
	for override in "${OVERRIDES_DIR}"/*; do
		# Extract recipe name from override path
		override_name=$(basename "${override}" .munki.recipe)
		log "Running autopkg ${override}..."
		
		# Capture both stdout and stderr to check for trust verification errors
		autopkg_output=$(mktemp)
		if "${AUTOPKG_CMD}" run -v "${override}" -k force_munkiimport=true > >(tee -a "${autopkg_output}") 2> >(tee -a "${autopkg_output}" >&2); then
			# Check output for trust verification errors
			if grep -q "Failed local trust verification" "${autopkg_output}" 2>/dev/null; then
				# Count how many trust errors occurred
				trust_error_count=$(grep -c "Failed local trust verification" "${autopkg_output}" 2>/dev/null || echo "0")
				
			# Try to extract package names from MunkiImporter output
			# Look for "MunkiImporter: pkg to:" lines and match with nearby trust errors
			package_names=$(awk '
				BEGIN { 
					# Array to store recent packages (within last 50 lines)
					split("", packages)
					line_num=0
				}
				{
					line_num++
					# Store package names from MunkiImporter lines
					if (/MunkiImporter:.*pkg to:/) {
						pkg=$NF
						gsub(/.*\//, "", pkg)
						# Store with line number
						packages[line_num] = pkg
					}
					# When we see a trust error, find the most recent package
					if (/Failed local trust verification/) {
						# Look back up to 50 lines for a package
						found=""
						for (i=line_num; i>0 && i>line_num-50; i--) {
							if (packages[i] != "") {
								found=packages[i]
								break
							}
						}
						if (found != "") {
							print found
						}
					}
				}
			' "${autopkg_output}" | sort -u)
				
				# If we found package names, log them
				if [ -n "${package_names}" ]; then
					while IFS= read -r package_name; do
						if [ -n "${package_name}" ]; then
							error "[${override_name}] Failed local trust verification for: ${package_name}"
						fi
					done <<< "${package_names}"
				else
					# Fallback: log with recipe name and count
					if [ "${trust_error_count}" -gt 0 ]; then
						error "[${override_name}] Failed local trust verification (${trust_error_count} error(s), unable to determine package name(s))"
					fi
				fi
			fi
		fi
		# Clean up temp file
		rm -f "${autopkg_output}"
	done
}

function make_override () {
	shift  # Skip the script option flag
	for override in "$@"; do
		log "Making override ${override}..."
		if ! "${AUTOPKG_CMD}" make-override "${override}"; then
			error "Failed to make override ${override}"
			# prompt for recipe repo
			read -p "Enter the recipe repo for ${override}: " recipe_repo
			"${AUTOPKG_CMD}" repo-add "${recipe_repo}"
			"${AUTOPKG_CMD}" make-override "${override}"
			log "Successfully made override ${override}"
		else
			log "Successfully made override ${override}"
		fi
	done
}

function run_specified_overrides {
	run_repoclean
	shift  # Skip the script option flag
	override_path="${1}"
	override_name=$(basename "${override_path}" .munki.recipe)
	log "Running autopkg for specified overrides: ${override_path}..."
	
	# Capture both stdout and stderr to check for trust verification errors
	autopkg_output=$(mktemp)
	if "${AUTOPKG_CMD}" run -v "${override_path}" -k force_munkiimport=true > >(tee -a "${autopkg_output}") 2> >(tee -a "${autopkg_output}" >&2); then
		# Check output for trust verification errors
		if grep -q "Failed local trust verification" "${autopkg_output}" 2>/dev/null; then
			# Count how many trust errors occurred
			trust_error_count=$(grep -c "Failed local trust verification" "${autopkg_output}" 2>/dev/null || echo "0")
			
			# Try to extract package names from MunkiImporter output
			# Look for "MunkiImporter: pkg to:" lines and match with nearby trust errors
			package_names=$(awk '
				BEGIN { 
					# Array to store recent packages (within last 50 lines)
					split("", packages)
					line_num=0
				}
				{
					line_num++
					# Store package names from MunkiImporter lines
					if (/MunkiImporter:.*pkg to:/) {
						pkg=$NF
						gsub(/.*\//, "", pkg)
						# Store with line number
						packages[line_num] = pkg
					}
					# When we see a trust error, find the most recent package
					if (/Failed local trust verification/) {
						# Look back up to 50 lines for a package
						found=""
						for (i=line_num; i>0 && i>line_num-50; i--) {
							if (packages[i] != "") {
								found=packages[i]
								break
							}
						}
						if (found != "") {
							print found
						}
					}
				}
			' "${autopkg_output}" | sort -u)
			
			# If we found package names, log them
			if [ -n "${package_names}" ]; then
				while IFS= read -r package_name; do
					if [ -n "${package_name}" ]; then
						error "[${override_name}] Failed local trust verification for: ${package_name}"
					fi
				done <<< "${package_names}"
			else
				# Fallback: log with recipe name and count
				if [ "${trust_error_count}" -gt 0 ]; then
					error "[${override_name}] Failed local trust verification (${trust_error_count} error(s), unable to determine package name(s))"
				fi
			fi
		fi
	fi
	# Clean up temp file
	rm -f "${autopkg_output}"
	
	name="${override_name}"
	if ! manifestutil display-manifest site_default | grep "${name}" > /dev/null; then  
		log "Adding ${name} to site_default manifest in managed_updates section..."
		manifestutil add-pkg "${name}" --manifest site_default --section managed_updates
	else
		log "${name} already in site_default manifest in managed_updates section"
	fi
	makecatalogs --skip-pkg-check "$MUNKI_REPO_PATH"
}

function add_new_overrides {
	current_date=$(date +%Y%m%d)
	log "Checking for an adding new overrides from ${OVERRIDES_DIR} since ${current_date}..."
	if [ ! -d "${OVERRIDES_DIR}" ]; then
		warn "Overrides directory not accessible: ${OVERRIDES_DIR}"
		return
	fi
	# Use find with error handling - redirect stderr to avoid permission errors in output
	while IFS= read -r new_override; do
		if [ -n "$new_override" ] && [ -f "$new_override" ]; then
			installer_name=$(xmllint --xpath 'string(//key[.="NAME"]/following-sibling::string[1])' "$new_override" 2>/dev/null)
			if [ -n "$installer_name" ]; then
				log "Adding ${installer_name} to munki repo..."
				manifestutil add-pkg "$installer_name" --manifest site_default --section managed_updates
			fi
		fi
	done < <(find "$OVERRIDES_DIR" -type f -newermt "$current_date" 2>/dev/null || true)
}

function run_makecatalogs {
	log "Running makecatalogs..."
	makecatalogs_output=$(mktemp)
	if /usr/local/munki/makecatalogs --skip-pkg-check "$MUNKI_REPO_PATH" > >(tee -a "${makecatalogs_output}") 2> >(tee -a "${makecatalogs_output}" >&2); then
		# Check for trust verification errors and try to extract package names
		if grep -q "Failed local trust verification" "${makecatalogs_output}" 2>/dev/null; then
			trust_error_count=$(grep -c "Failed local trust verification" "${makecatalogs_output}" 2>/dev/null || echo "0")
			
			# Try to extract package names from lines before trust errors
			# Look for package paths or names in the output
			package_names=$(awk '
				/[Pp]ackage:|[Pp]kg:|\.pkg|\.dmg/ {
					# Extract package name from various formats
					for (i=1; i<=NF; i++) {
						if ($i ~ /\.(pkg|dmg)$/) {
							pkg=$i
							gsub(/.*\//, "", pkg)
							last_pkg=pkg
						}
					}
				}
				/Failed local trust verification/ {
					if (last_pkg != "") {
						print last_pkg
						last_pkg=""
					}
				}
			' "${makecatalogs_output}" | sort -u)
			
			if [ -n "${package_names}" ]; then
				while IFS= read -r package_name; do
					if [ -n "${package_name}" ]; then
						error "[makecatalogs] Failed local trust verification for: ${package_name}"
					fi
				done <<< "${package_names}"
			else
				if [ "${trust_error_count}" -gt 0 ]; then
					warn "[makecatalogs] Failed local trust verification (${trust_error_count} error(s), unable to determine package name(s))"
				fi
			fi
		fi
	fi
	rm -f "${makecatalogs_output}"
}

# Save changes to git
function save_changes_to_git {
	commit_date_and_time=$(date +%Y%m%d_%H%M%S)
	log "Saving changes to git in ${MUNKI_REPO_PATH}"
	if [ ! -d "${MUNKI_REPO_PATH}" ]; then
		error "Munki repo directory not accessible: ${MUNKI_REPO_PATH}"
		return
	fi
	# Use git -C flag instead of cd to avoid working directory issues
	log "Adding all changes to git"
	if ! git -C "${MUNKI_REPO_PATH}" add --all 2>/dev/null; then
		error "Failed to add changes to git"
		return
	fi
	git -C "${MUNKI_REPO_PATH}" status
	log "Commiting changes..."
	if ! git -C "${MUNKI_REPO_PATH}" commit -m "${commit_date_and_time} Updating munki" 2>/dev/null; then
		warn "No changes to commit or commit failed"
		return
	fi
	git -C "${MUNKI_REPO_PATH}" push origin main
	log "Changes saved to git in ${MUNKI_REPO_PATH}"
}

function main {
	verify_autopkg_settings
	verify_munki_settings
	run_repoclean
	run_all_overrides
	add_new_overrides
	run_makecatalogs
	save_changes_to_git
}

# parameters
case $1 in
	--make-overrides)
		make_override "$@"
		;;
	--run-overrides)
		run_specified_overrides "$@"
		;;
	*)
		main
		;;
esac