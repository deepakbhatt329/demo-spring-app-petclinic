#!/usr/bin/env bash
# Convenience wrapper: resolves a previously-triggered demo incident.
# Usage: ./trigger-incident-resolve.sh --dedup-key demo-incident-1

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/trigger-incident.sh" --action resolve "$@"
