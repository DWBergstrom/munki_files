#!/usr/bin/env bash
# KeepAlive LaunchAgent entrypoint: wait for the Munki volume, ensure Tailscale
# serve is configured, then run python http.server in the foreground so launchd
# can restart it on crash/exit (including after reboot once the volume is up).

set -euo pipefail

VOLUME_NAME="M4_Dock"
MUNKI_REPO_PATH="/Volumes/${VOLUME_NAME}/munki_files/munki_web/munki_repo"
WEBSERVER_PORT="8080"
LOG_FILE="${HOME}/Library/Logs/munki-webserver.log"
MAX_WAIT_SECONDS=600   # 10 minutes for external volume after reboot
POLL_SECONDS=5

mkdir -p "$(dirname "${LOG_FILE}")"

log() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "${LOG_FILE}"
}

wait_for_repo() {
	local waited=0
	while [ ! -d "${MUNKI_REPO_PATH}" ]; do
		if [ "${waited}" -eq 0 ]; then
			log "Waiting for Munki repo at ${MUNKI_REPO_PATH}..."
		fi
		if [ "${waited}" -ge "${MAX_WAIT_SECONDS}" ]; then
			log "ERROR: repo not available after ${MAX_WAIT_SECONDS}s"
			exit 1
		fi
		sleep "${POLL_SECONDS}"
		waited=$((waited + POLL_SECONDS))
	done
	log "Munki repo available: ${MUNKI_REPO_PATH}"
}

ensure_tailscale_serve() {
	local ts
	ts="$(command -v tailscale || true)"
	if [ -z "${ts}" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
		ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
	fi
	if [ -z "${ts}" ]; then
		log "WARNING: tailscale not found; skipping serve configure"
		return 0
	fi
	# Serve config usually persists across reboots; re-apply so /munki stays correct
	if ! "${ts}" serve --bg --set-path /munki "http://127.0.0.1:${WEBSERVER_PORT}/" >/dev/null 2>&1; then
		"${ts}" serve reset >/dev/null 2>&1 || true
		sleep 1
		if ! "${ts}" serve --bg --set-path /munki "http://127.0.0.1:${WEBSERVER_PORT}/" >/dev/null 2>&1; then
			log "WARNING: failed to configure Tailscale serve (will still start python)"
			return 0
		fi
	fi
	log "Tailscale serve: /munki -> http://127.0.0.1:${WEBSERVER_PORT}/"
}

wait_for_repo
ensure_tailscale_serve

log "Starting python http.server on 127.0.0.1:${WEBSERVER_PORT}"
cd "${MUNKI_REPO_PATH}"
exec /usr/bin/python3 -m http.server "${WEBSERVER_PORT}" --bind 127.0.0.1
