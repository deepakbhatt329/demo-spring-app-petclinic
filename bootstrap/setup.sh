#!/usr/bin/env bash
# One-command bootstrap for the IDP Custom Integration demo environment.
# Idempotent: safe to re-run.
#
# Prereqs (see bootstrap/README.md):
#   - kubectl context set to the target dev cluster
#   - bootstrap/demo.env fully populated (from manual steps M2–M5)
#   - helm, kubectl, jq installed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
NAMESPACE="custom-integrartion-ipd-demo"
ENV_FILE="$SCRIPT_DIR/demo.env"

log()  { printf '\n\033[1;36m▶ %s\033[0m\n' "$*"; }
die()  { printf '\033[1;31m✗ %s\033[0m\n' "$*" >&2; exit 1; }

# --- 0. Preflight ------------------------------------------------------------
command -v kubectl >/dev/null || die "kubectl not found on PATH"
command -v helm    >/dev/null || die "helm not found on PATH"
[[ -f "$ENV_FILE" ]] || die "bootstrap/demo.env missing (copy from demo.env.example)"

REQUIRED=(HARNESS_IM_URL HARNESS_ACCOUNT_ID HARNESS_API_KEY IID_BUILD IID_DEPLOYMENT IID_QUALITY IID_SECURITY IID_SECURITY_SCAN IID_CUSTOM GHCR_USERNAME GHCR_TOKEN IDP_ENTITY_REF)
set -a; source "$ENV_FILE"; set +a
for v in "${REQUIRED[@]}"; do
  val="${!v-}"
  if [[ -z "$val" || "$val" == *REPLACE_ME* ]]; then
    die "demo.env: '$v' is missing or still contains REPLACE_ME"
  fi
done
log "demo.env preflight OK"

# --- 1. Namespace ------------------------------------------------------------
log "Ensuring namespace $NAMESPACE"
kubectl get namespace "$NAMESPACE" >/dev/null 2>&1 \
  || kubectl create namespace "$NAMESPACE"

# --- 2. Secret from demo.env ------------------------------------------------
log "Applying harness-idp-secrets from demo.env"
kubectl -n "$NAMESPACE" create secret generic harness-idp-secrets \
  --from-env-file="$ENV_FILE" \
  --dry-run=client -o yaml \
  | kubectl apply -f -

# --- 3. Petclinic Deployment placeholder ------------------------------------
log "Applying k8s/deploy.yaml (image placeholder — pipeline substitutes on first run)"
kubectl -n "$NAMESPACE" apply -f "$REPO_ROOT/k8s/deploy.yaml"

# --- 4. Helm repo ------------------------------------------------------------
log "Adding jenkins helm repo"
helm repo add jenkins https://charts.jenkins.io >/dev/null 2>&1 || true
helm repo update jenkins >/dev/null

# --- 5. Install / upgrade Jenkins -------------------------------------------
log "helm upgrade --install jenkins"
helm upgrade --install jenkins jenkins/jenkins \
  -n "$NAMESPACE" \
  -f "$SCRIPT_DIR/jenkins-values.yaml"

# --- 6. Wait for rollout -----------------------------------------------------
log "Waiting for jenkins rollout (up to 5m)"
kubectl -n "$NAMESPACE" rollout status statefulset/jenkins --timeout=5m

# --- 7. Print next steps -----------------------------------------------------
cat <<EOF

$(tput bold 2>/dev/null || true)Setup complete.$(tput sgr0 2>/dev/null || true)

Next steps (do these manually):

  1. kubectl -n $NAMESPACE port-forward svc/jenkins 8080:8080
  2. Open http://localhost:8080  (admin password: kubectl -n $NAMESPACE exec -it sts/jenkins -c jenkins -- cat /run/secrets/additional/chart-admin-password)
  3. The 'petclinic' job is auto-created via JCasC. Trigger it manually the first time.
  4. In PagerDuty (M5) create the V3 webhook subscription pointing at:
       \$IID_INCIDENTS_WEBHOOK_URL
     (URL is in demo.env once you fill it in.)
  5. Set GitHub Actions secrets — see bootstrap/README.md for the gh commands.

EOF
