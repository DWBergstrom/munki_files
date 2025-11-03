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
	echo -e "${RED}[ERROR]${NC} $1" >&2
}
warn() {
	echo -e "${YELLOW}[WARNING]${NC} $1"
}
info() {
	echo -e "${BLUE}[INFO]${NC} $1"
}

# Prerequisites checks
# Verify tailscale is installed
if ! TAILSCALE_CMD=$(command -v tailscale) &> /dev/null; then
	error "Tailscale could not be found. Please install Tailscale and try again."
	exit 1
else
	info "Tailscale is installed at ${TAILSCALE_CMD}"
fi
# Verify python3 is installed
if ! PYTHON_CMD=$(command -v python3) &> /dev/null; then
	error "Python3 could not be found. Please install Python3 and try again."
	exit 1
else
	info "Python3 is installed at ${PYTHON_CMD}"
fi
# Verify autopkg is installed
if ! AUTOPKG_CMD=$(command -v autopkg) &> /dev/null; then
	error "Autopkg could not be found. Please install Autopkg and try again."
	exit 1
else
	info "Autopkg is installed at ${AUTOPKG_CMD}"
fi
# Verify munki is installed
if ! MANAGEDSOFTWAREUPDATE_CMD=$(command -v managedsoftwareupdate) &> /dev/null; then
	error "Munki could not be found. Please install Munki and try again."
	exit 1
else
	info "Munki is installed at ${MANAGEDSOFTWAREUPDATE_CMD}"
fi
# Verify 1Password CLI is installed (optional)
if ! OP_CMD=$(command -v op) &> /dev/null; then
	warn "1Password CLI could not be found. Will not be able to update github token for autopkg."
else
	info "1Password CLI is installed at ${OP_CMD}"
fi

# Get github token for autopkg (optional)
GITHUB_TOKEN=$(op item get "GitHub - Autopkg" --fields token)
if [ -z "${GITHUB_TOKEN}" ]; then
	error "Github token for autopkg not found. Add to 1Password when possible."
else
	info "Github token for autopkg: ${GITHUB_TOKEN}"
fi

# Config variables
# Volume name
VOLUME_NAME="M4_Dock"
info "Munki volume name: ${VOLUME_NAME}"
# Define Munki  and autopkg variables
REPOCLEAN_VERSIONS="1"
MUNKI_REPO_PATH="/Volumes/${VOLUME_NAME}/munki_files/munki_web/munki_repo/"
# Define the override directory
OVERRIDES_DIR="/Volumes/${VOLUME_NAME}/munki_files/autopkg/overrides"

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
	PYTHON_SERVER_STATUS="running"
	log "Python server status: ${PYTHON_SERVER_STATUS} at http://127.0.0.1:${WEBSERVER_PORT}"
else
	PYTHON_SERVER_STATUS="not running"
	log "Python server status: ${PYTHON_SERVER_STATUS}"
	info "Attempting to start python server..."
	python3 -m http.server ${WEBSERVER_PORT} --bind 127.0.0.1 --directory ${MUNKI_REPO_PATH} &
fi
# Check if tailscale is serving the munki repo
TAILSCALE_SERVING_STATUS=""
if TAILSCALE_URL=$($TAILSCALE_CMD serve status | grep $WEBSERVER_NAME | sed 's/ (tailnet only)//'); then
	TAILSCALE_SERVING_STATUS="serving"
	log "Tailscale serving status: ${TAILSCALE_SERVING_STATUS} at ${TAILSCALE_URL}/munki"
else
	TAILSCALE_SERVING_STATUS="not serving"
	log "Tailscale serving status: ${TAILSCALE_SERVING_STATUS}"
	info "Attempting to start tailscale serve..."
	$TAILSCALE_CMD serve --bg --set-path /munki http://127.0.0.1:${WEBSERVER_PORT}/
fi

# rsync options checks
RSYNC_URL=""
RSYNC_DESTINATION_PATH=""

function verify_autopkg_settings {
	defaults write com.github.autopkg RECIPE_OVERRIDE_DIRS "${OVERRIDES_DIR}"
	defaults write com.github.autopkg MUNKI_REPO "${MUNKI_REPO_PATH}"
	defaults write com.github.autopkg GITHUB_TOKEN "${GITHUB_TOKEN}"
	for repo in $(cat autopkg-repos); do
		"${AUTOPKG_CMD}" repo-add "${repo}"
	done
	info "Autopkg recipe override directory: $(defaults read com.github.autopkg RECIPE_OVERRIDE_DIRS)"
	info "Autopkg munki repo: $(defaults read com.github.autopkg MUNKI_REPO)"
}

function verify_munki_settings {
	# Check if running from launch agent (no TTY available)
	if [ -t 0 ] && [ -t 1 ]; then
		if $(defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL) != "${TAILSCALE_URL}/munki"; then
			info "Setting Munki repo URL to ${TAILSCALE_URL}/munki - will prompt for sudo password"
			sudo defaults write /Library/Preferences/ManagedInstalls SoftwareRepoURL "${TAILSCALE_URL}/munki"
			info "Munki repo URL: $(defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL)"
		else
			info "Munki repo URL is already set to ${TAILSCALE_URL}/munki"
		fi
	else
		warn "Running from launch agent - skipping Munki settings update (requires sudo)"
		info "Current Munki repo URL: $(defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL 2>/dev/null || echo 'Unable to read - may require sudo')"
	fi
}

function run_repoclean {
	log "Running repoclean..."
	repoclean -k "${REPOCLEAN_VERSIONS}" -a "${MUNKI_REPO_PATH}"
}

function run_all_overrides {
	log "Running autopkg repo-update all..."
	"${AUTOPKG_CMD}" repo-update all
	for override in "${OVERRIDES_DIR}"/*; do
		log "Running autopkg ${override}..."
		"${AUTOPKG_CMD}" run -v "${override}" -k force_munkiimport=true
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
	log "Running autopkg for specified overrides: ${1}..."
	"${AUTOPKG_CMD}" run -v "${1}" -k force_munkiimport=true
	name="${1%.munki.recipe}"
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
	info "Checking for an adding new overrides from ${OVERRIDES_DIR} since ${current_date}..."
	while IFS= read -r new_override; do
		installer_name=$(xmllint --xpath 'string(//key[.="NAME"]/following-sibling::string[1])' "$new_override")
		log "Adding ${installer_name} to munki repo..."
		manifestutil add-pkg "$installer_name" --manifest site_default --section managed_updates
	done < <(find "$OVERRIDES_DIR" -type f -newermt "$current_date")
}

function run_makecatalogs {
	log "Running makecatalogs..."
	/usr/local/munki/makecatalogs --skip-pkg-check "$MUNKI_REPO_PATH"
}

# Save changes to git
function save_changes_to_git {
	commit_date_and_time=$(date +%Y%m%d_%H%M%S)
	log "Changing to munki directory"
	cd "${MUNKI_REPO_PATH}"
	log "Adding all changes to git"
	git add --all
	git status
	log "Commiting changes..."
	git commit -m "${commit_date_and_time} Updating munki"
	git push origin main
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