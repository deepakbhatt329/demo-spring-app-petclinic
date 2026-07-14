#!/usr/bin/env bash
# Trigger / acknowledge / resolve a PagerDuty incident via Events API v2.
# The V3 webhook subscription in PagerDuty will then post to your Harness webhook URL.
#
# Usage:
#   ./trigger-incident.sh --dedup-key demo-incident-1 --action trigger
#   ./trigger-incident.sh --dedup-key demo-incident-1 --action acknowledge
#   ./trigger-incident.sh --dedup-key demo-incident-1 --action resolve

set -euo pipefail

DEDUP_KEY=""
ACTION="trigger"
SUMMARY="petclinic demo incident"
SEVERITY="warning"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dedup-key) DEDUP_KEY="$2"; shift 2 ;;
    --action)    ACTION="$2"; shift 2 ;;
    --summary)   SUMMARY="$2"; shift 2 ;;
    --severity)  SEVERITY="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ -z "$DEDUP_KEY" ]]; then
  echo "--dedup-key required" >&2; exit 2
fi
if [[ -z "${PAGERDUTY_ROUTING_KEY:-}" ]]; then
  echo "PAGERDUTY_ROUTING_KEY env var required (source bootstrap/demo.env)" >&2; exit 2
fi

BODY=$(cat <<JSON
{
  "routing_key": "$PAGERDUTY_ROUTING_KEY",
  "event_action": "$ACTION",
  "dedup_key": "$DEDUP_KEY",
  "payload": {
    "summary": "$SUMMARY",
    "source": "jenkins.petclinic.dev",
    "severity": "$SEVERITY",
    "component": "petclinic",
    "group": "petclinic-demo",
    "class": "deployment"
  }
}
JSON
)

echo "$BODY" | jq .
curl -sSf -X POST \
  -H 'Content-Type: application/json' \
  --data-binary "$BODY" \
  https://events.pagerduty.com/v2/enqueue \
  | jq .
