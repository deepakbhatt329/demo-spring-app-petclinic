# IDP Custom Integration — demo environment bootstrap

This directory contains everything needed to spin up the demo. See `~/.claude/plans/i-want-you-to-kind-diffie.md` for the full plan.

## Quick start

```
cp bootstrap/demo.env.example bootstrap/demo.env
# ... fill in bootstrap/demo.env from manual steps M2–M5 ...

./bootstrap/setup.sh
kubectl -n custom-integrartion-ipd-demo port-forward svc/jenkins 8080:8080
open http://localhost:8080
```

## Manual prerequisites

Do these before running `setup.sh` (all details in the plan):

| # | Step | Time |
|---|---|---|
| M1 | Fork + clone (**done**: this repo) | 0 |
| M2 | Create Harness dev API key with IDP Integration Edit permission | 2 min |
| M3 | Create 6 Custom Integrations in Harness dev IDP UI (5 api-mode + 1 webhook-mode) | 6 min |
| M4 | Log in to SonarCloud via GitHub SSO, analyze this fork, copy `SONAR_TOKEN` | 3 min |
| M5 | Sign up for PagerDuty free-tier, create service + V3 webhook subscription pointed at IID_INCIDENTS_WEBHOOK_URL, copy signing secret into `account.pd_signing_secret` Harness secret | 4 min |
| M6 | Fill `bootstrap/demo.env` with values from M2–M5 | 2 min |
| M7 | Push `demo-setup` branch after reviewing files | 2 min |
| M8 | Set GitHub Actions secrets on the fork | 1 min |

## Cluster-side commands

Wrapped by `setup.sh`, but reproducible one at a time:

```bash
kubectl get ns custom-integrartion-ipd-demo >/dev/null 2>&1 \
  || kubectl create ns custom-integrartion-ipd-demo

kubectl -n custom-integrartion-ipd-demo create secret generic harness-idp-secrets \
  --from-env-file=bootstrap/demo.env --dry-run=client -o yaml \
  | kubectl apply -f -

kubectl -n custom-integrartion-ipd-demo apply -f k8s/deploy.yaml   # image is placeholder until first pipeline run

helm repo add jenkins https://charts.jenkins.io
helm repo update
helm upgrade --install jenkins jenkins/jenkins \
  -n custom-integrartion-ipd-demo -f bootstrap/jenkins-values.yaml

kubectl -n custom-integrartion-ipd-demo rollout status statefulset/jenkins --timeout=5m
kubectl -n custom-integrartion-ipd-demo port-forward svc/jenkins 8080:8080
```

## GitHub Actions secrets (M8)

```bash
set -a && source bootstrap/demo.env && set +a
gh secret set SONAR_TOKEN         --body "$SONAR_TOKEN"         --repo deepakbhatt329/demo-spring-app-petclinic
gh secret set SONAR_PROJECT_KEY   --body "$SONAR_PROJECT_KEY"   --repo deepakbhatt329/demo-spring-app-petclinic
gh secret set SONAR_ORGANIZATION  --body "$SONAR_ORGANIZATION"  --repo deepakbhatt329/demo-spring-app-petclinic
gh secret set HARNESS_API_KEY     --body "$HARNESS_API_KEY"     --repo deepakbhatt329/demo-spring-app-petclinic
gh secret set HARNESS_ACCOUNT_ID  --body "$HARNESS_ACCOUNT_ID"  --repo deepakbhatt329/demo-spring-app-petclinic
gh secret set HARNESS_IM_URL      --body "$HARNESS_IM_URL"      --repo deepakbhatt329/demo-spring-app-petclinic
gh secret set IID_QUALITY         --body "$IID_QUALITY"         --repo deepakbhatt329/demo-spring-app-petclinic
gh secret set IID_CUSTOM          --body "$IID_CUSTOM"          --repo deepakbhatt329/demo-spring-app-petclinic
gh secret set IDP_ENTITY_REF      --body "$IDP_ENTITY_REF"      --repo deepakbhatt329/demo-spring-app-petclinic
```

## Demo runbook

```bash
# 1. Build + deploy + build/deployment/security/quality upserts
git commit --allow-empty -m "demo tick" && git push

# 2. Custom entity via GitHub Action
gh pr create --title "demo PR" --body "trigger idp-custom"
gh pr close <PR#>

# 3. Incident lifecycle
set -a && source bootstrap/demo.env && set +a
./bootstrap/demo/trigger-incident.sh --dedup-key demo-1 --action trigger
./bootstrap/demo/trigger-incident.sh --dedup-key demo-1 --action acknowledge
./bootstrap/demo/trigger-incident.sh --dedup-key demo-1 --action resolve

# 4. Force a build failure to exercise the failure branch
./bootstrap/demo/force-build-failure.sh
```

## Verify records landed

```bash
set -a && source bootstrap/demo.env && set +a
for pair in "build:$IID_BUILD" "deployment:$IID_DEPLOYMENT" "quality:$IID_QUALITY" "security_issues:$IID_SECURITY" "custom:$IID_CUSTOM"; do
  KIND="${pair%%:*}"; IID="${pair##*:}"
  echo "--- $KIND ---"
  curl -sSf -X POST \
    -H "Authorization: Bearer $HARNESS_API_KEY" \
    -H "Content-Type: application/json" \
    "$HARNESS_IM_URL/api/v1/accounts/$HARNESS_ACCOUNT_ID/entities/custom" \
    -d "{\"integration_id\":\"$IID\",\"kind\":\"$KIND\",\"page\":0,\"size\":10}" \
    | jq '.records[] | {identifier, status, timestamp}'
done
```

## Known limitation

**Incidents flow depends on a separate Integration Manager task** — extending the webhook signature verifier at `integration-manager/util/signatureverifier/verifier.go` to accept PagerDuty's `X-PagerDuty-Signature: v1=<hex>` format, plus a small envelope adapter in `ingestionwebhook/receive.go`. Until that lands, PagerDuty webhooks will hit IM but be rejected with `ErrAlgoMismatch`.
