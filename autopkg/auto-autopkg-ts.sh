#!/usr/bin/env bash

# Handle --help immediately before any other processing
if [[ "$1" == "--help" || "$1" == "-h" ]]; then
	echo "Usage: $(basename "$0") [option] [flags]"
	echo ""
	echo "Options:"
	echo "  (none)             Run full autopkg workflow (repoclean, verify trust, run all overrides, makecatalogs, git commit)"
	echo "  --make-overrides   Create new overrides for specified recipes"
	echo "                     Example: $0 --make-overrides Firefox.munki Chrome.munki"
	echo "  --run-overrides    Run a specific override"
	echo "                     Example: $0 --run-overrides /path/to/override.munki.recipe"
	echo "  --find-missing     Scan installed apps and search for autopkg recipes for apps without overrides"
	echo "                     Also scans remote hosts listed in autopkg-scan-hosts file"
	echo "  --verify-icons     Check that all packages in Munki repo have icons"
	echo "  --help, -h         Show this help message"
	echo ""
	echo "Flags (can be combined with options):"
	echo "  --force-import     Force re-import packages even if already in Munki repo (use for testing only)"
	echo "  --scan-host USER@HOST  Add additional host to scan for --find-missing (can be used multiple times)"
	echo "  --local-only       Skip scanning remote hosts for --find-missing"
	echo ""
	echo "Log file: ${HOME}/Library/Logs/auto-autopkg-ts.log"
	exit 0
fi

# Parse flags from any position in arguments
FORCE_MUNKIIMPORT=""
EXTRA_SCAN_HOSTS=()
LOCAL_ONLY=false
for arg in "$@"; do
	if [[ "${arg}" == "--force-import" ]]; then
		FORCE_MUNKIIMPORT="-k force_munkiimport=true"
	elif [[ "${arg}" == "--local-only" ]]; then
		LOCAL_ONLY=true
	fi
done
# Parse --scan-host arguments (need to look at pairs)
while [[ $# -gt 0 ]]; do
	case "$1" in
		--scan-host)
			if [[ -n "$2" && ! "$2" =~ ^-- ]]; then
				EXTRA_SCAN_HOSTS+=("$2")
				shift
			fi
			;;
	esac
	shift
done

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
# only do this if not running from launch agent and op CLI is available
if [ -t 0 ] && [ -t 1 ] && command -v op &> /dev/null; then
	log "verifying github token for autopkg..."
	# Check if signed into 1Password CLI first
	if op account list &> /dev/null; then
		GITHUB_TOKEN=$(op item get "GitHub Personal Access Token: Autopkg Read" --fields token --reveal 2>/dev/null)
		if [ -z "${GITHUB_TOKEN}" ]; then
			warn "GitHub token for autopkg not found in 1Password."
			info "Expected item: 'GitHub Personal Access Token: Autopkg Read' with field 'token'"
			info "Or set GITHUB_TOKEN environment variable"
		else
			log "GitHub token for autopkg retrieved from 1Password"
		fi
	else
		warn "1Password CLI not authenticated. Run 'op signin' to enable GitHub token retrieval."
	fi
fi

# Check if GITHUB_TOKEN was already set in environment (before this script ran)
if [ -z "${GITHUB_TOKEN:-}" ]; then
	info "No GitHub token available - autopkg will use unauthenticated GitHub API (rate limited)"
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

function verify_icons {
	log "Verifying icons for all packages in Munki repo..."
	
	ICONS_DIR="${MUNKI_REPO_PATH}/icons"
	PKGSINFO_DIR="${MUNKI_REPO_PATH}/pkgsinfo"
	
	if [ ! -d "${PKGSINFO_DIR}" ]; then
		error "pkgsinfo directory not found: ${PKGSINFO_DIR}"
		return 1
	fi
	
	if [ ! -d "${ICONS_DIR}" ]; then
		warn "Icons directory not found: ${ICONS_DIR}"
		mkdir -p "${ICONS_DIR}"
		log "Created icons directory"
	fi
	
	# Get list of unique package names from pkgsinfo
	missing_icons=()
	checked_names=()
	total_pkgs=0
	
	while IFS= read -r -d '' pkginfo_file; do
		# Extract the 'name' key from pkginfo plist
		pkg_name=$(xmllint --xpath 'string(//key[.="name"]/following-sibling::string[1])' "${pkginfo_file}" 2>/dev/null)
		
		if [ -n "${pkg_name}" ]; then
			# Skip if we've already checked this name
			if [[ " ${checked_names[*]} " =~ " ${pkg_name} " ]]; then
				continue
			fi
			checked_names+=("${pkg_name}")
			((total_pkgs++))
			
			# Check for icon file (try common extensions)
			icon_found=false
			for ext in png PNG icns ICNS jpg JPG jpeg JPEG; do
				if [ -f "${ICONS_DIR}/${pkg_name}.${ext}" ]; then
					icon_found=true
					break
				fi
			done
			
			if ! ${icon_found}; then
				missing_icons+=("${pkg_name}")
			fi
		fi
	done < <(find "${PKGSINFO_DIR}" -type f -name "*.plist" -print0 2>/dev/null)
	
	log "Checked ${total_pkgs} unique packages"
	
	if [ ${#missing_icons[@]} -eq 0 ]; then
		log "All packages have icons!"
		return 0
	fi
	
	warn "${#missing_icons[@]} package(s) missing icons:"
	for pkg in "${missing_icons[@]}"; do
		warn "  - ${pkg}"
	done
	
	# Offer to extract icons from installed apps (interactive mode)
	if [ -t 0 ] && [ -t 1 ]; then
		echo ""
		read -p "Attempt to extract icons from installed apps? (y/N): " extract_choice
		if [[ "${extract_choice}" =~ ^[Yy]$ ]]; then
			for pkg_name in "${missing_icons[@]}"; do
				# Try to find matching app in /Applications
				app_path=$(find /Applications -maxdepth 2 -name "*.app" -type d 2>/dev/null | while read app; do
					app_basename=$(basename "${app}" .app)
					# Case-insensitive match, also try without spaces
					app_lower=$(echo "${app_basename}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
					pkg_lower=$(echo "${pkg_name}" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9]//g')
					if [ "${app_lower}" = "${pkg_lower}" ]; then
						echo "${app}"
						break
					fi
				done)
				
				if [ -n "${app_path}" ] && [ -d "${app_path}" ]; then
					# Extract icon using sips
					icon_source="${app_path}/Contents/Resources/AppIcon.icns"
					if [ ! -f "${icon_source}" ]; then
						# Try to find any .icns file
						icon_source=$(find "${app_path}/Contents/Resources" -name "*.icns" -type f 2>/dev/null | head -1)
					fi
					
					if [ -f "${icon_source}" ]; then
						icon_dest="${ICONS_DIR}/${pkg_name}.png"
						if sips -s format png -z 256 256 "${icon_source}" --out "${icon_dest}" &>/dev/null; then
							log "Extracted icon for: ${pkg_name}"
						else
							warn "Failed to extract icon for: ${pkg_name}"
						fi
					else
						warn "No icon found in app bundle for: ${pkg_name}"
					fi
				else
					info "No matching app found for: ${pkg_name}"
				fi
			done
		fi
	fi
	
	return 0
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
	
	# Count overrides for progress (use unique list to avoid duplicates)
	shopt -s nullglob
	# Read files into array, handling spaces in filenames (bash 3.2 compatible)
	override_files=()
	while IFS= read -r file; do
		[ -n "${file}" ] && override_files+=("${file}")
	done < <(ls -1 "${OVERRIDES_DIR}"/*.munki.recipe "${OVERRIDES_DIR}"/*.recipe 2>/dev/null | sort -u)
	shopt -u nullglob
	total_overrides=${#override_files[@]}
	current=0
	
	for override in "${override_files[@]}"; do
		if [ -f "${override}" ]; then
			((current++))
			override_name=$(basename "${override}" .munki.recipe)
			# Show progress (overwrite same line)
			printf "\r  Checking [%d/%d]: %s...                    " "${current}" "${total_overrides}" "${override_name}"
			
			# Run verify-trust-info (without -vv for speed, we'll get details for failures)
			if ! "${AUTOPKG_CMD}" verify-trust-info "${override}" > "${trust_output}" 2>&1; then
				# Check if it's a trust verification failure vs other error
				if grep -q "FAILED" "${trust_output}" 2>/dev/null; then
					failed_recipes+=("${override_name}")
					failed_recipe_paths+=("${override}")
					printf "\n"
					warn "[verify-trust-info] Trust verification FAILED for: ${override_name}"
				else
					# Other error (e.g., recipe not found)
					printf "\n"
					error "[verify-trust-info] Error checking ${override_name}: $(cat "${trust_output}")"
				fi
			fi
		fi
	done
	printf "\n"
	
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
	# Suppress verbose output, log to file, show only errors
	"${AUTOPKG_CMD}" repo-update all >> "${LOG_FILE}" 2>&1 || warn "Some repos may have failed to update"
	log "Repo update complete (details in log file)"
	
	# Count overrides for progress (use unique list to avoid duplicates)
	shopt -s nullglob
	# Read files into array, handling spaces in filenames (bash 3.2 compatible)
	override_files=()
	while IFS= read -r file; do
		[ -n "${file}" ] && override_files+=("${file}")
	done < <(ls -1 "${OVERRIDES_DIR}"/*.munki.recipe "${OVERRIDES_DIR}"/*.recipe 2>/dev/null | sort -u)
	shopt -u nullglob
	total_overrides=${#override_files[@]}
	current=0

	for override in "${override_files[@]}"; do
		((current++))
		# Extract recipe name from override path
		override_name=$(basename "${override}" .munki.recipe)
		log "Running autopkg ${override}... (override ${current} of ${total_overrides})"
		# Write context marker to stderr so errors in log have context
		echo "--- [${override_name}] Starting autopkg run (${current}/${total_overrides}) ---" >&2
		
		# Capture both stdout and stderr to check for trust verification errors
		autopkg_output=$(mktemp)
		# Redirect all output to file while also displaying it
		if "${AUTOPKG_CMD}" run -v "${override}" ${FORCE_MUNKIIMPORT} > >(tee "${autopkg_output}") 2> >(tee "${autopkg_output}" >&2); then
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

function find_missing_overrides {
	log "Scanning installed applications for missing autopkg overrides..."
	
	# Skip list file - apps to permanently ignore
	SKIP_LIST_FILE="${AUTOPKG_DIR}/autopkg-skip-apps"
	
	# Load skip list (one app name per line, case-insensitive)
	skip_list=""
	if [ -f "${SKIP_LIST_FILE}" ]; then
		skip_list=$(cat "${SKIP_LIST_FILE}" | tr '[:upper:]' '[:lower:]')
		skip_count=$(echo "${skip_list}" | grep -c . || echo 0)
		log "Loaded ${skip_count} app(s) from skip list"
	fi
	
	# Enable nullglob so non-matching globs expand to nothing
	shopt -s nullglob
	
	# Build list of existing override names (normalized to lowercase, one per line)
	existing_overrides=""
	override_count=0
	# Use unique list to avoid duplicates (*.recipe also matches *.munki.recipe)
	# Read files line by line to handle spaces in filenames
	while IFS= read -r override_file; do
		if [ -f "${override_file}" ]; then
			# Extract the NAME from the recipe plist
			override_name=$(xmllint --xpath 'string(//key[.="NAME"]/following-sibling::string[1])' "${override_file}" 2>/dev/null | tr '[:upper:]' '[:lower:]')
			if [ -n "${override_name}" ]; then
				existing_overrides="${existing_overrides}${override_name}"$'\n'
				((override_count++))
			fi
			# Also add the filename-based name
			filename_name=$(basename "${override_file}" | sed -E 's/\.(munki\.recipe|recipe)$//' | tr '[:upper:]' '[:lower:]')
			existing_overrides="${existing_overrides}${filename_name}"$'\n'
		fi
	done < <(ls -1 "${OVERRIDES_DIR}"/*.munki.recipe "${OVERRIDES_DIR}"/*.recipe 2>/dev/null | sort -u)
	log "Found ${override_count} existing overrides"
	
	# Collect all app names from local and remote sources
	all_app_names=()
	
	# Scan local /Applications
	log "Scanning local applications..."
	local_app_count=0
	for app_path in /Applications/*.app ~/Applications/*.app; do
		if [ -d "${app_path}" ]; then
			((local_app_count++))
			app_name=$(basename "${app_path}" .app)
			all_app_names+=("${app_name}")
		fi
	done
	log "Found ${local_app_count} local applications"
	
	# Scan remote hosts (unless --local-only)
	SCAN_HOSTS_FILE="${AUTOPKG_DIR}/autopkg-scan-hosts"
	if [ "${LOCAL_ONLY}" != "true" ]; then
		# Build list of hosts to scan
		hosts_to_scan=()
		
		# Add hosts from config file
		if [ -f "${SCAN_HOSTS_FILE}" ]; then
			while IFS= read -r line; do
				# Skip comments and empty lines
				[[ "${line}" =~ ^[[:space:]]*# ]] && continue
				[[ -z "${line// }" ]] && continue
				hosts_to_scan+=("${line}")
			done < "${SCAN_HOSTS_FILE}"
		fi
		
		# Add extra hosts from --scan-host flags
		for host in "${EXTRA_SCAN_HOSTS[@]}"; do
			hosts_to_scan+=("${host}")
		done
		
		# Scan each remote host
		for host in "${hosts_to_scan[@]}"; do
			log "Scanning remote host: ${host}..."
			remote_apps=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "${host}" 'ls -1 /Applications/ 2>/dev/null | grep "\.app$" | sed "s/\.app$//"' 2>/dev/null)
			if [ $? -eq 0 ] && [ -n "${remote_apps}" ]; then
				remote_count=$(echo "${remote_apps}" | wc -l | tr -d ' ')
				log "Found ${remote_count} applications on ${host}"
				while IFS= read -r app_name; do
					[ -n "${app_name}" ] && all_app_names+=("${app_name}")
				done <<< "${remote_apps}"
			else
				warn "Could not connect to ${host} (check SSH key auth)"
			fi
		done
	fi
	
	# Deduplicate app names (bash 3.2 compatible)
	unique_app_names=()
	while IFS= read -r name; do
		[ -n "${name}" ] && unique_app_names+=("${name}")
	done < <(printf '%s\n' "${all_app_names[@]}" | sort -u)
	log "Total unique applications: ${#unique_app_names[@]}"
	
	# Filter apps to find those without overrides
	apps_without_overrides=()
	for app_name in "${unique_app_names[@]}"; do
		app_name_lower=$(echo "${app_name}" | tr '[:upper:]' '[:lower:]')
		
		# Skip Apple system apps and common utilities that don't need autopkg
		case "${app_name_lower}" in
			"app store"|"automator"|"books"|"calculator"|"calendar"|"chess"|"contacts"|"dictionary"|"facetime"|"find my"|"font book"|"freeform"|"home"|"image capture"|"keynote"|"mail"|"maps"|"messages"|"mission control"|"music"|"news"|"notes"|"numbers"|"pages"|"photo booth"|"photos"|"podcasts"|"preview"|"quicktime player"|"reminders"|"safari"|"shortcuts"|"siri"|"stickies"|"stocks"|"system preferences"|"system settings"|"textedit"|"time machine"|"tv"|"voice memos"|"weather"|"utilities"|"ilife"|"iwork")
				continue
				;;
		esac
		
		# Skip apps in the permanent skip list
		if [ -n "${skip_list}" ] && echo "${skip_list}" | grep -qix "${app_name_lower}"; then
			continue
		fi
		
		# Check if override exists (case-insensitive)
		app_name_nospace=$(echo "${app_name_lower}" | sed 's/[^a-z0-9]//g')
		if ! echo "${existing_overrides}" | grep -qix "${app_name_lower}" && \
		   ! echo "${existing_overrides}" | grep -qix "${app_name_nospace}"; then
			apps_without_overrides+=("${app_name}")
		fi
	done
	
	if [ ${#apps_without_overrides[@]} -eq 0 ]; then
		log "All applications have matching overrides!"
		return 0
	fi
	
	log "Found ${#apps_without_overrides[@]} application(s) without overrides:"
	for app in "${apps_without_overrides[@]}"; do
		info "  - ${app}"
	done
	
	# Search for recipes for each app
	echo ""
	log "Searching for autopkg recipes..."
	
	recipes_found=()
	apps_with_recipes=()
	
	for app_name in "${apps_without_overrides[@]}"; do
		# Search autopkg for matching .munki recipes
		# Try multiple search strategies for better results
		search_output=$(mktemp)
		munki_lines=""
		
		# Build search variations
		search_no_spaces=$(echo "${app_name}" | sed 's/[^a-zA-Z0-9]//g')
		first_word=$(echo "${app_name}" | awk '{print $1}' | sed 's/[^a-zA-Z0-9]//g')
		
		# Strategy 1: Try without spaces (e.g., "GoogleChrome" from "Google Chrome")
		# This often matches recipe naming conventions better
		"${AUTOPKG_CMD}" search "${search_no_spaces}" > "${search_output}" 2>&1 || true
		munki_lines=$(grep -i "\.munki" "${search_output}" 2>/dev/null | grep -vi "^Name\|^----\|^To search\|^Note:" | head -15)
		
		# Strategy 2: If few/no results, also try first word and combine results
		result_count=$(echo "${munki_lines}" | wc -l | tr -d ' ')
		if [ -z "${result_count}" ] || [ "${result_count}" -lt 3 ]; then
			"${AUTOPKG_CMD}" search "${first_word}" >> "${search_output}" 2>&1 || true
			munki_lines=$(grep -i "\.munki" "${search_output}" 2>/dev/null | grep -vi "^Name\|^----\|^To search\|^Note:" | sort -u | head -15)
		fi
		
		# Strategy 3: If still no results, try full name with spaces
		if [ -z "${munki_lines}" ]; then
			"${AUTOPKG_CMD}" search "${app_name}" > "${search_output}" 2>&1 || true
			munki_lines=$(grep -i "\.munki" "${search_output}" 2>/dev/null | grep -vi "^Name\|^----\|^To search\|^Note:" | head -15)
		fi
		
		if [ -n "${munki_lines}" ]; then
			echo ""
			info "Recipes found for '${app_name}':"
			recipe_num=1
			recipe_options=()
			recipe_repos=()
			while IFS= read -r line; do
				if [ -n "${line}" ]; then
					# autopkg search output: "RecipeName.munki.recipe    repo-name    Path/to/recipe"
					# Columns are separated by 2+ spaces. Recipe names can have single spaces.
					
					# Extract repo first - look for *-recipes pattern (this is reliable)
					recipe_repo=$(echo "${line}" | grep -oE '[a-zA-Z0-9_-]+-recipes' | head -1)
					
					# Extract recipe name - everything before "  " (2+ spaces) that ends with .munki or .munki.recipe
					# Split on 2+ spaces and take the first field
					recipe_name=$(echo "${line}" | sed -E 's/[[:space:]]{2,}.*//' | grep -oE '.*\.munki(\.recipe)?$')
					
					# Validate we have reasonable values
					if [ -n "${recipe_name}" ] && echo "${recipe_name}" | grep -qiE "\.munki(\.recipe)?$"; then
						if [ -n "${recipe_repo}" ]; then
							echo "  ${recipe_num}) ${recipe_name} (${recipe_repo})"
						else
							echo "  ${recipe_num}) ${recipe_name} (repo unknown)"
						fi
						recipe_options+=("${recipe_name}")
						recipe_repos+=("${recipe_repo}")
						((recipe_num++))
					fi
				fi
			done <<< "${munki_lines}"
			
			if [ ${#recipe_options[@]} -eq 0 ]; then
				warn "No .munki recipes found for '${app_name}'"
				rm -f "${search_output}"
				continue
			fi
			
			if [ -t 0 ] && [ -t 1 ]; then
				echo "  s) Skip this app"
				echo "  p) Permanently skip (add to skip list)"
				echo "  q) Quit searching"
				read -p "Choose recipe number to create override [1-$((recipe_num-1))/s/p/q]: " choice
				
				case "${choice}" in
					[Qq])
						log "Stopping recipe search"
						rm -f "${search_output}"
						break
						;;
					[Ss])
						log "Skipping ${app_name}"
						;;
					[Pp])
						log "Permanently skipping ${app_name}"
						echo "${app_name}" >> "${SKIP_LIST_FILE}"
						info "Added '${app_name}' to ${SKIP_LIST_FILE}"
						;;
					[1-9]*)
						idx=$((choice - 1))
						if [ ${idx} -ge 0 ] && [ ${idx} -lt ${#recipe_options[@]} ]; then
							selected_recipe="${recipe_options[${idx}]}"
							selected_repo="${recipe_repos[${idx}]}"
							log "Creating override for: ${selected_recipe}"
							
							# Function to attempt creating override with dependency resolution
							create_override_with_deps() {
								local recipe="$1"
								local repo="$2"
								local max_attempts=3
								local attempt=1
								local override_output
								
								while [ ${attempt} -le ${max_attempts} ]; do
									override_output=$(mktemp)
									if "${AUTOPKG_CMD}" make-override "${recipe}" > "${override_output}" 2>&1; then
										rm -f "${override_output}"
										return 0
									fi
									
									# Check for missing parent recipe
									missing_recipe=$(grep "Didn't find a recipe for" "${override_output}" | sed 's/.*Didn.t find a recipe for //' | tr -d '.')
									if [ -n "${missing_recipe}" ]; then
										# Extract repo name from recipe identifier (com.github.USERNAME.type.Name)
										parent_repo=$(echo "${missing_recipe}" | sed -n 's/com\.github\.\([^.]*\)\..*/\1-recipes/p')
										if [ -n "${parent_repo}" ]; then
											warn "Missing parent recipe from: ${parent_repo}"
											info "Adding repo: ${parent_repo}"
											if "${AUTOPKG_CMD}" repo-add "${parent_repo}" 2>/dev/null; then
												log "Added parent repo: ${parent_repo}"
												((attempt++))
												rm -f "${override_output}"
												continue
											else
												warn "Could not add ${parent_repo} automatically"
											fi
										fi
									fi
									
									# Show error and break
									cat "${override_output}"
									rm -f "${override_output}"
									break
								done
								return 1
							}
							
							# First, try adding the recipe's own repo if we have it
							if [ -n "${selected_repo}" ] && [ "${selected_repo}" != "" ]; then
								"${AUTOPKG_CMD}" repo-add "${selected_repo}" 2>/dev/null && \
									log "Ensured repo is added: ${selected_repo}"
							fi
							
							# Try to create override with automatic dependency resolution
							if create_override_with_deps "${selected_recipe}" "${selected_repo}"; then
								log "Successfully created override for ${app_name}"
								recipes_found+=("${selected_recipe}")
								apps_with_recipes+=("${app_name}")
							else
								error "Failed to create override for ${selected_recipe}"
								
								# Try to extract error details for better guidance
								test_output=$(mktemp)
								"${AUTOPKG_CMD}" make-override "${selected_recipe}" > "${test_output}" 2>&1 || true
								
								# Check if override already exists
								if grep -q "already exists" "${test_output}"; then
									existing_path=$(grep "already exists at" "${test_output}" | sed 's/.*already exists at //' | sed 's/,.*//')
									info "Override already exists: ${existing_path}"
									log "Skipping - you already have this override"
									rm -f "${test_output}"
									continue
								fi
								
								# Check for deprecated recipe
								if grep -q "deprecated" "${test_output}"; then
									warn "This recipe is deprecated"
									if [ -t 0 ] && [ -t 1 ]; then
										read -p "Create override anyway with --ignore-deprecation? (y/N): " deprec_choice
										if [[ "${deprec_choice}" =~ ^[Yy]$ ]]; then
											if "${AUTOPKG_CMD}" make-override "${selected_recipe}" --ignore-deprecation 2>/dev/null; then
												log "Successfully created override for ${app_name} (deprecated recipe)"
												recipes_found+=("${selected_recipe}")
												apps_with_recipes+=("${app_name}")
											else
												error "Failed to create override even with --ignore-deprecation"
											fi
										else
											log "Skipping deprecated recipe"
										fi
									fi
									rm -f "${test_output}"
									continue
								fi
								
								# Check for missing parent recipe
								missing_dep=$(grep "Didn't find a recipe for" "${test_output}" | sed 's/.*Didn.t find a recipe for //' | sed 's/\.$//')
								rm -f "${test_output}"
								
								if [ -n "${missing_dep}" ]; then
									# Extract likely repo name from identifier (com.github.USERNAME.type.Name)
									suggested_repo=$(echo "${missing_dep}" | sed -n 's/com\.github\.\([^.]*\)\..*/\1-recipes/p')
									echo ""
									info "Missing parent recipe: ${missing_dep}"
									if [ -n "${suggested_repo}" ]; then
										info "Suggested repo to add: ${suggested_repo}"
										read -p "Add '${suggested_repo}'? (Y/n/other): " repo_choice
										case "${repo_choice}" in
											[Nn])
												warn "Skipping ${app_name}"
												;;
											""|[Yy]*)
												if "${AUTOPKG_CMD}" repo-add "${suggested_repo}" 2>/dev/null; then
													log "Added repo: ${suggested_repo}"
													if "${AUTOPKG_CMD}" make-override "${selected_recipe}" 2>/dev/null; then
														log "Successfully created override for ${app_name}"
														recipes_found+=("${selected_recipe}")
														apps_with_recipes+=("${app_name}")
													else
														error "Still failed - may need additional repos"
													fi
												else
													error "Could not add repo: ${suggested_repo}"
												fi
												;;
											*)
												# User entered a different repo name
												if "${AUTOPKG_CMD}" repo-add "${repo_choice}" 2>/dev/null; then
													log "Added repo: ${repo_choice}"
													if "${AUTOPKG_CMD}" make-override "${selected_recipe}" 2>/dev/null; then
														log "Successfully created override for ${app_name}"
														recipes_found+=("${selected_recipe}")
														apps_with_recipes+=("${app_name}")
													else
														error "Still failed to create override"
													fi
												else
													error "Could not add repo: ${repo_choice}"
												fi
												;;
										esac
									else
										read -p "Enter repo to try (or press Enter to skip): " manual_repo
										if [ -n "${manual_repo}" ]; then
											"${AUTOPKG_CMD}" repo-add "${manual_repo}" 2>/dev/null
											"${AUTOPKG_CMD}" make-override "${selected_recipe}" 2>/dev/null && \
												log "Successfully created override for ${app_name}" && \
												recipes_found+=("${selected_recipe}") && \
												apps_with_recipes+=("${app_name}")
										fi
									fi
								else
									read -p "Enter repo to try (or press Enter to skip): " manual_repo
									if [ -n "${manual_repo}" ]; then
										"${AUTOPKG_CMD}" repo-add "${manual_repo}" 2>/dev/null
										"${AUTOPKG_CMD}" make-override "${selected_recipe}" 2>/dev/null && \
											log "Successfully created override for ${app_name}" && \
											recipes_found+=("${selected_recipe}") && \
											apps_with_recipes+=("${app_name}")
									fi
								fi
							fi
						else
							warn "Invalid selection, skipping ${app_name}"
						fi
						;;
					*)
						warn "Invalid selection, skipping ${app_name}"
						;;
				esac
			fi
		else
			warn "No .munki recipes found for '${app_name}'"
			if [ -t 0 ] && [ -t 1 ]; then
				read -p "  Permanently skip this app? (y/N): " skip_choice
				if [[ "${skip_choice}" =~ ^[Yy]$ ]]; then
					echo "${app_name}" >> "${SKIP_LIST_FILE}"
					info "Added '${app_name}' to skip list"
				fi
			fi
		fi
		
		rm -f "${search_output}"
	done
	
	# Summary
	echo ""
	if [ ${#recipes_found[@]} -gt 0 ]; then
		log "Created ${#recipes_found[@]} new override(s):"
		for recipe in "${recipes_found[@]}"; do
			info "  - ${recipe}"
		done
		
		# Offer to run trust verification on new overrides
		if [ -t 0 ] && [ -t 1 ]; then
			read -p "Run autopkg for new overrides now? (y/N): " run_choice
			if [[ "${run_choice}" =~ ^[Yy]$ ]]; then
				for app_name in "${apps_with_recipes[@]}"; do
					override_file=$(find "${OVERRIDES_DIR}" -maxdepth 1 -iname "*${app_name}*.recipe" -type f 2>/dev/null | head -1)
					if [ -n "${override_file}" ] && [ -f "${override_file}" ]; then
						log "Running override: ${override_file}"
						"${AUTOPKG_CMD}" run -v "${override_file}" ${FORCE_MUNKIIMPORT}
					fi
				done
			fi
		fi
	else
		log "No new overrides were created"
	fi
	
	# Restore default glob behavior
	shopt -u nullglob
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
	if "${AUTOPKG_CMD}" run -v "${override_path}" ${FORCE_MUNKIIMPORT} > >(tee "${autopkg_output}") 2> >(tee "${autopkg_output}" >&2); then
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
	--find-missing)
		find_missing_overrides
		;;
	--verify-icons)
		verify_icons
		;;
	*)
		main
		;;
esac