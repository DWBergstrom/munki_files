#!/usr/bin/env bash
# Periodic health check for the Munki web server.
# KeepAlive restarts python if it *exits*, but not if it stays alive serving
# 404s (e.g. stale cwd after the external volume remounts) or if the
# Tailscale serve config is lost. This watchdog checks the real URLs
# clients use and repairs whichever layer is broken.

set -uo pipefail

WEBSERVER_PORT="8080"
WEBSERVER_LABEL="com.dwbergstrom.munki-webserver"
LOG_FILE="${HOME}/Library/Logs/munki-webserver-watchdog.log"
LOCK_DIR="/tmp/munki-webserver-watchdog.lock"

mkdir -p "$(dirname "${LOG_FILE}")"

# Rotate log if > 5MB
if [ -f "${LOG_FILE}" ] && [ "$(stat -f%z "${LOG_FILE}" 2>/dev/null || echo 0)" -gt 5242880 ]; then
	mv "${LOG_FILE}" "${LOG_FILE}.old"
fi

log() {
	echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" >> "${LOG_FILE}"
}

# Single-instance lock
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
	exit 0
fi
trap 'rmdir "${LOCK_DIR}" 2>/dev/null' EXIT

tailscale_cmd() {
	local ts
	ts="$(command -v tailscale || true)"
	if [ -z "${ts}" ] && [ -x /Applications/Tailscale.app/Contents/MacOS/Tailscale ]; then
		ts="/Applications/Tailscale.app/Contents/MacOS/Tailscale"
	fi
	echo "${ts}"
}

local_ok() {
	curl -fsS --max-time 5 -o /dev/null "http://127.0.0.1:${WEBSERVER_PORT}/manifests/site_default" 2>/dev/null
}

tailscale_url() {
	defaults read /Library/Preferences/ManagedInstalls SoftwareRepoURL 2>/dev/null || true
}

tailscale_ok() {
	local repo_url
	repo_url="$(tailscale_url)"
	[ -n "${repo_url}" ] || return 1
	curl -fsS --max-time 8 -o /dev/null "${repo_url}/manifests/site_default" 2>/dev/null
}

repair_local() {
	local uid_num i
	uid_num="$(id -u)"
	log "Local check FAILED - kickstarting ${WEBSERVER_LABEL}"
	launchctl kickstart -k "gui/${uid_num}/${WEBSERVER_LABEL}" 2>/dev/null \
		|| launchctl kill SIGTERM "gui/${uid_num}/${WEBSERVER_LABEL}" 2>/dev/null \
		|| true
	for i in 1 2 3 4 5 6; do
		sleep 5
		if local_ok; then
			log "Local server recovered after kickstart"
			return 0
		fi
	done
	log "ERROR: local server still failing after kickstart"
	return 1
}

repair_tailscale() {
	local ts
	ts="$(tailscale_cmd)"
	if [ -z "${ts}" ]; then
		log "ERROR: Tailscale check failed and tailscale CLI not found"
		return 1
	fi
	log "Tailscale check FAILED - reapplying serve config"
	if ! "${ts}" serve --bg --set-path /munki "http://127.0.0.1:${WEBSERVER_PORT}/" >/dev/null 2>&1; then
		"${ts}" serve reset >/dev/null 2>&1 || true
		sleep 1
		"${ts}" serve --bg --set-path /munki "http://127.0.0.1:${WEBSERVER_PORT}/" >/dev/null 2>&1 || true
	fi
	sleep 2
	if tailscale_ok; then
		log "Tailscale serve recovered"
		return 0
	fi
	log "ERROR: Tailscale serve still failing after reapply"
	return 1
}

# Healthy? Stay silent.
if local_ok && tailscale_ok; then
	exit 0
fi

# Repair local first (Tailscale proxies to it, so it may heal both)
if ! local_ok; then
	repair_local || true
fi

if ! tailscale_ok; then
	# If local is healthy, this is a serve-config problem; fix just that.
	# If local is still down, serve can't succeed yet - next run will retry.
	if local_ok; then
		repair_tailscale || true
	else
		log "Skipping Tailscale repair: local server still down"
	fi
fi

# Final state, for the log
if local_ok && tailscale_ok; then
	log "All checks passing after repair"
	exit 0
fi
log "WARNING: checks still failing (local=$(local_ok && echo ok || echo FAIL) tailscale=$(tailscale_ok && echo ok || echo FAIL))"
exit 1
