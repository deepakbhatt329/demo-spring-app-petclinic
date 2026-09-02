#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="$SCRIPT_DIR/demo.env"

if [[ ! -f "$ENV_FILE" ]]; then
  echo "error: $ENV_FILE not found" >&2
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

EVENTS_API="https://events.pagerduty.com/v2/enqueue"
REST_API="https://api.pagerduty.com"

usage() {
  cat <<USAGE
Usage:
  $(basename "$0") trigger  [--summary "text"] [--dedup-key KEY] [--severity warning|error|critical|info]
  $(basename "$0") resolve  --dedup-key KEY
  $(basename "$0") reassign --incident-id INC --user-id USER [--email EMAIL]

Subcommands:
  trigger   Fire an incident.triggered event via Events API v2 (routing_key auth).
            If --dedup-key is omitted, a random one is generated and printed so
            you can resolve the same incident later.
  resolve   Fire an incident.resolved event for the given dedup_key.
  reassign  PUT /incidents/{id} on the REST API to reassign to another user.
            Requires PAGERDUTY_API_TOKEN and PAGERDUTY_USER_EMAIL in demo.env
            (email is the actor making the change; can be overridden by --email).

Environment (loaded from bootstrap/demo.env):
  PAGERDUTY_ROUTING_KEY   required for trigger/resolve
  PAGERDUTY_API_TOKEN     required for reassign (Personal REST API key)
  PAGERDUTY_USER_EMAIL    required for reassign (From header)

Examples:
  $(basename "$0") trigger --summary "smoke test"
  $(basename "$0") trigger --dedup-key smoke-1
  $(basename "$0") resolve --dedup-key smoke-1
  $(basename "$0") reassign --incident-id Q1F6JPQK8386FP --user-id PL51ZE6
USAGE
}

die() { echo "error: $*" >&2; exit 1; }

require_env() {
  local var="$1"
  [[ -n "${!var:-}" ]] || die "$var is not set (expected in $ENV_FILE)"
}

random_hex8() {
  od -An -N4 -tx1 /dev/urandom | tr -d ' \n'
}

now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

cmd_trigger() {
  local summary="" dedup_key="" severity="warning"
  while (( $# > 0 )); do
    case "$1" in
      --summary)    summary="$2"; shift 2 ;;
      --dedup-key)  dedup_key="$2"; shift 2 ;;
      --severity)   severity="$2"; shift 2 ;;
      -h|--help)    usage; exit 0 ;;
      *)            die "unknown flag: $1" ;;
    esac
  done

  require_env PAGERDUTY_ROUTING_KEY

  local ts
  ts="$(now_iso)"
  [[ -z "$dedup_key" ]] && dedup_key="scripted-probe-$(random_hex8)"
  [[ -z "$summary"   ]] && summary="Scripted probe at ${ts}"

  local payload
  payload=$(cat <<JSON
{
  "routing_key": "${PAGERDUTY_ROUTING_KEY}",
  "event_action": "trigger",
  "dedup_key": "${dedup_key}",
  "payload": {
    "summary": "${summary}",
    "source": "custom-integration-setup/bootstrap",
    "severity": "${severity}",
    "timestamp": "${ts}",
    "component": "petclinic-webhook-probe",
    "group": "custom-integration",
    "class": "probe",
    "custom_details": {
      "purpose": "verify integration-manager PagerDuty webhook end-to-end",
      "trigger_time": "${ts}"
    }
  }
}
JSON
)

  echo "action     : trigger"
  echo "dedup_key  : ${dedup_key}"
  echo "summary    : ${summary}"
  echo "severity   : ${severity}"
  echo "occurred_at: ${ts}"
  echo "--- request ---"
  curl -sS -i -X POST "$EVENTS_API" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload"
  echo
}

cmd_resolve() {
  local dedup_key=""
  while (( $# > 0 )); do
    case "$1" in
      --dedup-key) dedup_key="$2"; shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *)           die "unknown flag: $1" ;;
    esac
  done

  require_env PAGERDUTY_ROUTING_KEY
  [[ -n "$dedup_key" ]] || die "--dedup-key is required for resolve"

  local payload
  payload=$(cat <<JSON
{
  "routing_key": "${PAGERDUTY_ROUTING_KEY}",
  "event_action": "resolve",
  "dedup_key": "${dedup_key}"
}
JSON
)

  echo "action    : resolve"
  echo "dedup_key : ${dedup_key}"
  echo "--- request ---"
  curl -sS -i -X POST "$EVENTS_API" \
    -H 'Content-Type: application/json' \
    --data-binary "$payload"
  echo
}

cmd_reassign() {
  local incident_id="" user_id="" email=""
  while (( $# > 0 )); do
    case "$1" in
      --incident-id) incident_id="$2"; shift 2 ;;
      --user-id)     user_id="$2"; shift 2 ;;
      --email)       email="$2"; shift 2 ;;
      -h|--help)     usage; exit 0 ;;
      *)             die "unknown flag: $1" ;;
    esac
  done

  require_env PAGERDUTY_API_TOKEN
  [[ -n "$incident_id" ]] || die "--incident-id is required"
  [[ -n "$user_id"     ]] || die "--user-id is required"
  [[ -n "$email"       ]] || email="${PAGERDUTY_USER_EMAIL:-}"
  [[ -n "$email"       ]] || die "PAGERDUTY_USER_EMAIL not set and --email not provided"

  local payload
  payload=$(cat <<JSON
{
  "incident": {
    "type": "incident_reference",
    "assignments": [
      {
        "assignee": {
          "id": "${user_id}",
          "type": "user_reference"
        }
      }
    ]
  }
}
JSON
)

  echo "action      : reassign"
  echo "incident_id : ${incident_id}"
  echo "user_id     : ${user_id}"
  echo "actor_email : ${email}"
  echo "--- request ---"
  curl -sS -i -X PUT "${REST_API}/incidents/${incident_id}" \
    -H "Authorization: Token token=${PAGERDUTY_API_TOKEN}" \
    -H "From: ${email}" \
    -H 'Accept: application/vnd.pagerduty+json;version=2' \
    -H 'Content-Type: application/json' \
    --data-binary "$payload"
  echo
}

if (( $# == 0 )); then usage; exit 1; fi

sub="$1"; shift
case "$sub" in
  trigger)  cmd_trigger  "$@" ;;
  resolve)  cmd_resolve  "$@" ;;
  reassign) cmd_reassign "$@" ;;
  -h|--help|help) usage ;;
  *)  die "unknown subcommand: $sub (expected trigger|resolve|reassign)" ;;
esac
