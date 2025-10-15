dry run
TOKEN="xx" ./cleanup_stale_hosts.sh

run
TOKEN="xx" ./cleanup_stale_hosts.sh -f -d 120

Specify custom AAP URL & log file
./cleanup_stale_hosts.sh -f -u https://aap.lnx.corp.lan -l /tmp/cleanup.log


#!/usr/bin/env bash
#
# cleanup_stale_hosts.sh
# Delete AAP 2.5 hosts that haven't run automation in the last N days.
# Handles pagination automatically across all host_metrics pages.
#
# Requirements: curl, jq, date (GNU)

set -euo pipefail

# ======== Configuration ========
AAP_URL="${AAP_URL:-https://aap.lnx.corp.lan}"     # or export before running
TOKEN="${TOKEN:-}"                                 # or export TOKEN=<your_token>
DAYS="${DAYS:-90}"                                 # cutoff days
LOG_FILE="${LOG_FILE:-/var/log/aap_stale_hosts.log}"
DRY_RUN=true                                       # default is dry-run
PAGE_SIZE=200

# ======== Helper Functions ========
usage() {
  echo "Usage: $0 [-f] [-d <days>] [-u <url>] [-t <token>] [-l <logfile>]"
  echo "  -f             Actually delete (disable dry-run)"
  echo "  -d <days>      Number of days since last automation (default: 90)"
  echo "  -u <url>       AAP base URL (default: $AAP_URL)"
  echo "  -t <token>     Bearer token"
  echo "  -l <logfile>   Log file path (default: $LOG_FILE)"
  exit 1
}

log() {
  echo "$(date -u +"%Y-%m-%dT%H:%M:%SZ") | $*" | tee -a "$LOG_FILE"
}

# ======== Parse Options ========
while getopts ":fd:u:t:l:" opt; do
  case ${opt} in
    f ) DRY_RUN=false ;;
    d ) DAYS="$OPTARG" ;;
    u ) AAP_URL="$OPTARG" ;;
    t ) TOKEN="$OPTARG" ;;
    l ) LOG_FILE="$OPTARG" ;;
    * ) usage ;;
  esac
done

if [[ -z "$TOKEN" ]]; then
  log "ERROR: Bearer token is required (set TOKEN or use -t)"
  exit 1
fi

# ======== Main ========
CUTOFF_DATE=$(date -u -d "-${DAYS} days" +"%Y-%m-%dT%H:%M:%SZ")
TMPFILE=$(mktemp)
trap 'rm -f "$TMPFILE"' EXIT

log "Starting stale host cleanup (older than $DAYS days, cutoff: $CUTOFF_DATE)"
log "AAP URL: $AAP_URL"
log "Mode: $([[ "$DRY_RUN" == true ]] && echo "DRY-RUN" || echo "DELETE")"
log "-----------------------------------------"

NEXT_URL="$AAP_URL/api/v2/host_metrics/?page_size=$PAGE_SIZE"
PAGE=1

while [[ -n "$NEXT_URL" && "$NEXT_URL" != "null" ]]; do
  log "Fetching page $PAGE: $NEXT_URL"
  RESPONSE=$(curl -sk -H "Authorization: Bearer $TOKEN" "$NEXT_URL")

  echo "$RESPONSE" | jq -r --arg CUTOFF "$CUTOFF_DATE" '
    .results[]
    | select(.last_automation and .last_automation < $CUTOFF)
    | [.id, .host_name, .last_automation]
    | @tsv' >> "$TMPFILE"

  NEXT_PATH=$(echo "$RESPONSE" | jq -r '.next')
  if [[ "$NEXT_PATH" != "null" && -n "$NEXT_PATH" ]]; then
    # If .next is a relative path, prepend base URL
    if [[ "$NEXT_PATH" =~ ^/ ]]; then
      NEXT_URL="$AAP_URL$NEXT_PATH"
    else
      NEXT_URL="$NEXT_PATH"
    fi
  else
    NEXT_URL=""
  fi
  PAGE=$((PAGE + 1))
done

if [[ ! -s "$TMPFILE" ]]; then
  log "✅ No stale hosts found."
  exit 0
fi

log "-----------------------------------------"
log "Processing stale hosts:"
while IFS=$'\t' read -r id name last_auto; do
  log "Found stale host: $name (ID $id, last automation $last_auto)"
  if [[ "$DRY_RUN" == false ]]; then
    RESPONSE=$(curl -sk -o /dev/null -w "%{http_code}" \
      -X DELETE -H "Authorization: Bearer $TOKEN" \
      "$AAP_URL/api/v2/host_metrics/$id/")
    if [[ "$RESPONSE" == "204" ]]; then
      log "✅ Deleted $name (ID $id)"
    else
      log "⚠️  Failed to delete $name (HTTP $RESPONSE)"
    fi
  fi
done < "$TMPFILE"

log "Cleanup complete."
