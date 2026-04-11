#!/bin/bash

# Log file setup - writes to ~/Library/Logs for Console.app visibility
LOG_DIR="${HOME}/Library/Logs"
LOG_FILE="${LOG_DIR}/auto-autopkg-ts.log"
mkdir -p "${LOG_DIR}"

# Rotate log if larger than 10MB
if [ -f "${LOG_FILE}" ] && [ $(stat -f%z "${LOG_FILE}" 2>/dev/null || echo 0) -gt 10485760 ]; then
	mv "${LOG_FILE}" "${LOG_FILE}.$(date +%Y%m%d_%H%M%S).bak"
fi

# Function to write to log file (strips color codes)
write_log() {
	echo "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "${LOG_FILE}"
}

# logging functions - output to both console and log file
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
NC='\033[0m' # No Color
log() {
	local msg="${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $1"
	echo -e "${msg}"
	write_log "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}
error() {
	local msg="${RED}[$(date +'%Y-%m-%d %H:%M:%S')][ERROR]${NC} $1"
	echo -e "${msg}" >&2
	write_log "[$(date +'%Y-%m-%d %H:%M:%S')][ERROR] $1"
}
warn() {
	local msg="${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')][WARNING]${NC} $1"
	echo -e "${msg}"
	write_log "[$(date +'%Y-%m-%d %H:%M:%S')][WARNING] $1"
}
info() {
	local msg="${BLUE}[$(date +'%Y-%m-%d %H:%M:%S')][INFO]${NC} $1"
	echo -e "${msg}"
	write_log "[$(date +'%Y-%m-%d %H:%M:%S')][INFO] $1"
}

log "executing auto-autopkg-ts.sh from ${PWD}"
log "Log file: ${LOG_FILE}"

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
# only do this if not running from launch agent
if [ -t 0 ] && [ -t 1 ]; then
	log "verifying github token for autopkg..."
	GITHUB_TOKEN=$(op item get "GitHub - Autopkg" --fields token)
	if [ -z "${GITHUB_TOKEN}" ]; then
		error "Github token for autopkg not found. Add to 1Password when possible."
	else
		log "Github token for autopkg: ${GITHUB_TOKEN}"
	fi
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
	$TAILSCALE_CMD serve reset 2>/dev/null
	sleep 1
	if $TAILSCALE_CMD serve --bg --set-path ${TAILSCALE_URL}/munki "http://127.0.0.1:${WEBSERVER_PORT}/" 2>/dev/null; then
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
	if $(defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL) != "${TAILSCALE_URL}/munki"; then
		log "Setting Munki repo URL to ${TAILSCALE_URL}/munki - will prompt for sudo password"
		sudo defaults write /Library/Preferences/ManagedInstalls SoftwareRepoURL "${TAILSCALE_URL}/munki"
		log "Munki repo URL: $(defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL)"
	else
		log "Munki repo URL is already set to ${TAILSCALE_URL}/munki"
	fi
}

function run_repoclean {
	log "Running repoclean..."
	# Write context marker to stderr so errors in log have context
	echo "--- [repoclean] Starting repoclean run ---" >&2
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
	# Write end marker to stderr
	echo "--- [repoclean] Finished repoclean run ---" >&2
}

function verify_trust_info {
	log "Verifying trust info for all overrides..."
	echo "--- [verify-trust-info] Starting trust verification ---" >&2
	write_log "--- [verify-trust-info] Starting trust verification ---"
	
	trust_output=$(mktemp)
	failed_recipes=()
	failed_recipe_paths=()
	
	for override in "${OVERRIDES_DIR}"/*; do
		if [ -f "${override}" ]; then
			override_name=$(basename "${override}" .munki.recipe)
			# Run verify-trust-info with -vv for verbose output
			if ! "${AUTOPKG_CMD}" verify-trust-info -vv "${override}" > "${trust_output}" 2>&1; then
				# Check if it's a trust verification failure vs other error
				if grep -q "FAILED" "${trust_output}" 2>/dev/null; then
					failed_recipes+=("${override_name}")
					failed_recipe_paths+=("${override}")
					warn "[verify-trust-info] Trust verification FAILED for: ${override_name}"
					# Log verbose output to file for Console.app review
					write_log "--- Trust verification details for ${override_name} ---"
					cat "${trust_output}" >> "${LOG_FILE}"
					write_log "--- End trust verification details ---"
					# Show summary in console
					if grep -q "non-core processor" "${trust_output}" 2>/dev/null; then
						info "  Non-core processor has changed"
					fi
					if grep -q "parent recipe" "${trust_output}" 2>/dev/null; then
						info "  Parent recipe has changed"
					fi
				else
					# Other error (e.g., recipe not found)
					error "[verify-trust-info] Error checking ${override_name}: $(cat "${trust_output}")"
				fi
			fi
		fi
	done
	
	rm -f "${trust_output}"
	
	# Summary
	if [ ${#failed_recipes[@]} -gt 0 ]; then
		warn "[verify-trust-info] ${#failed_recipes[@]} recipe(s) have trust verification failures:"
		for recipe in "${failed_recipes[@]}"; do
			warn "  - ${recipe}"
		done
		info "See ${LOG_FILE} for detailed diff output"
		
		# If interactive, offer to update trust or continue
		if [ -t 0 ] && [ -t 1 ]; then
			echo ""
			echo "Options:"
			echo "  u) Update trust info for failed recipes (review changes first)"
			echo "  c) Continue running recipes without updating trust"
			echo "  a) Abort"
			read -p "Choose an option [u/c/a]: " trust_choice
			
			case "${trust_choice}" in
				[Uu])
					log "Updating trust info for failed recipes..."
					for i in "${!failed_recipes[@]}"; do
						recipe_name="${failed_recipes[$i]}"
						recipe_path="${failed_recipe_paths[$i]}"
						echo ""
						info "Reviewing changes for: ${recipe_name}"
						# Show the diff again for review
						"${AUTOPKG_CMD}" verify-trust-info -vv "${recipe_path}" 2>&1 || true
						echo ""
						read -p "Update trust for ${recipe_name}? (y/N): " update_choice
						if [[ "${update_choice}" =~ ^[Yy]$ ]]; then
							if "${AUTOPKG_CMD}" update-trust-info "${recipe_path}"; then
								log "Updated trust info for: ${recipe_name}"
							else
								error "Failed to update trust info for: ${recipe_name}"
							fi
						else
							warn "Skipped trust update for: ${recipe_name}"
						fi
					done
					;;
				[Cc])
					log "Continuing without updating trust info"
					;;
				*)
					log "Aborting recipe run due to trust verification failures"
					echo "--- [verify-trust-info] Finished trust verification (aborted) ---" >&2
					write_log "--- [verify-trust-info] Finished trust verification (aborted) ---"
					return 1
					;;
			esac
		fi
	else
		log "[verify-trust-info] All recipes passed trust verification"
	fi
	
	echo "--- [verify-trust-info] Finished trust verification ---" >&2
	write_log "--- [verify-trust-info] Finished trust verification ---"
	return 0
}

function run_all_overrides {
	log "Running autopkg repo-update all..."
	"${AUTOPKG_CMD}" repo-update all
	for override in "${OVERRIDES_DIR}"/*; do
		# Extract recipe name from override path
		override_name=$(basename "${override}" .munki.recipe)
		log "Running autopkg ${override}..."
		# Write context marker to stderr so errors in log have context
		echo "--- [${override_name}] Starting autopkg run ---" >&2
		
		# Capture both stdout and stderr to check for trust verification errors
		autopkg_output=$(mktemp)
		# Redirect all output to file while also displaying it
		if "${AUTOPKG_CMD}" run -v "${override}" -k force_munkiimport=true > >(tee "${autopkg_output}") 2> >(tee "${autopkg_output}" >&2); then
			# Wait a moment for any buffered output
			sleep 0.5
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
		# Write end marker to stderr
		echo "--- [${override_name}] Finished autopkg run ---" >&2
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

function verify_trust_info_single {
	local override_path="${1}"
	local override_name=$(basename "${override_path}" .munki.recipe)
	
	log "Verifying trust info for: ${override_name}..."
	
	trust_output=$(mktemp)
	# Run verify-trust-info with -vv for verbose output
	if ! "${AUTOPKG_CMD}" verify-trust-info -vv "${override_path}" > "${trust_output}" 2>&1; then
		if grep -q "FAILED" "${trust_output}" 2>/dev/null; then
			warn "[verify-trust-info] Trust verification FAILED for: ${override_name}"
			# Display verbose output
			cat "${trust_output}"
			# Log to file for Console.app review
			write_log "--- Trust verification details for ${override_name} ---"
			cat "${trust_output}" >> "${LOG_FILE}"
			write_log "--- End trust verification details ---"
			rm -f "${trust_output}"
			
			if [ -t 0 ] && [ -t 1 ]; then
				echo ""
				echo "Options:"
				echo "  u) Update trust info for this recipe"
				echo "  c) Continue running recipe without updating trust"
				echo "  a) Abort"
				read -p "Choose an option [u/c/a]: " trust_choice
				
				case "${trust_choice}" in
					[Uu])
						log "Updating trust info for: ${override_name}"
						if "${AUTOPKG_CMD}" update-trust-info "${override_path}"; then
							log "Updated trust info for: ${override_name}"
						else
							error "Failed to update trust info for: ${override_name}"
							return 1
						fi
						;;
					[Cc])
						log "Continuing without updating trust info"
						;;
					*)
						log "Aborting recipe run"
						return 1
						;;
				esac
			fi
		else
			error "[verify-trust-info] Error checking ${override_name}: $(cat "${trust_output}")"
			rm -f "${trust_output}"
			return 1
		fi
	else
		log "[verify-trust-info] ${override_name} passed trust verification"
	fi
	rm -f "${trust_output}"
	return 0
}

function run_specified_overrides {
	run_repoclean
	shift  # Skip the script option flag
	override_path="${1}"
	override_name=$(basename "${override_path}" .munki.recipe)
	
	# Verify trust before running
	if ! verify_trust_info_single "${override_path}"; then
		error "Trust verification failed for ${override_name}"
		return 1
	fi
	
	log "Running autopkg for specified overrides: ${override_path}..."
	# Write context marker to stderr so errors in log have context
	echo "--- [${override_name}] Starting autopkg run ---" >&2
	
	# Capture both stdout and stderr to check for trust verification errors
	autopkg_output=$(mktemp)
	# Redirect all output to file while also displaying it
	if "${AUTOPKG_CMD}" run -v "${override_path}" -k force_munkiimport=true > >(tee "${autopkg_output}") 2> >(tee "${autopkg_output}" >&2); then
		# Wait a moment for any buffered output
		sleep 0.5
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
	# Write end marker to stderr
	echo "--- [${override_name}] Finished autopkg run ---" >&2
	
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
	# Write context marker to stderr so errors in log have context
	echo "--- [makecatalogs] Starting makecatalogs run ---" >&2
	makecatalogs_output=$(mktemp)
	if /usr/local/munki/makecatalogs --skip-pkg-check "$MUNKI_REPO_PATH" > >(tee -a "${makecatalogs_output}") 2> >(tee -a "${makecatalogs_output}" >&2); then
		# Check for trust verification errors and try to extract package names
		if grep -q "Failed local trust verification" "${makecatalogs_output}" 2>/dev/null; then
			trust_error_count=$(grep -c "Failed local trust verification" "${makecatalogs_output}" 2>/dev/null || echo "0")
			
			# Try to extract package names from lines before trust errors
			# Look for package paths or names in the output - check lines before each error
			package_names=$(awk '
				BEGIN {
					split("", packages)
					line_num=0
				}
				{
					line_num++
					# Store package names from various patterns
					if (/[Pp]ackage:|[Pp]kg:|\.pkg|\.dmg/) {
						for (i=1; i<=NF; i++) {
							if ($i ~ /\.(pkg|dmg)$/) {
								pkg=$i
								gsub(/.*\//, "", pkg)
								packages[line_num] = pkg
							}
						}
					}
					# When we see a trust error, find the most recent package
					if (/Failed local trust verification/) {
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
			' "${makecatalogs_output}" | sort -u)
			
			if [ -n "${package_names}" ]; then
				while IFS= read -r package_name; do
					if [ -n "${package_name}" ]; then
						error "[makecatalogs] Failed local trust verification for: ${package_name}"
					fi
				done <<< "${package_names}"
			else
				if [ "${trust_error_count}" -gt 0 ]; then
					error "[makecatalogs] Failed local trust verification (${trust_error_count} error(s), unable to determine package name(s))"
				fi
			fi
		fi
	fi
	rm -f "${makecatalogs_output}"
	# Write end marker to stderr
	echo "--- [makecatalogs] Finished makecatalogs run ---" >&2
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
	# Check if running from launch agent (no TTY available)
	if [ -t 0 ] && [ -t 1 ]; then
		verify_autopkg_settings
		verify_munki_settings
		run_repoclean
		# Verify trust info before running overrides (interactive mode can abort)
		if ! verify_trust_info; then
			error "Trust verification failed and user chose to abort"
			exit 1
		fi
		run_all_overrides
		add_new_overrides
		run_makecatalogs
		save_changes_to_git
	else
		warn "Running from launch agent - skipping autopkg settings verification and munki settings update (requires sudo)"
		run_repoclean
		# Verify trust info (non-interactive mode continues despite failures)
		verify_trust_info || warn "Trust verification had failures - continuing anyway in non-interactive mode"
		run_all_overrides
		add_new_overrides
		run_makecatalogs
		save_changes_to_git
	fi
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