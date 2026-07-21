# pd-incident.sh

Fire PagerDuty webhook events at the Harness IDP integration-manager for demo
and end-to-end testing.

## What it does

Wraps two PagerDuty APIs so the demo webhook subscription
(`account.custom-integration-pagerduty-webhook-secret` →
`/api/v1/accounts/{acct}/webhooks/{webhookId}`) receives real
`incident.triggered`, `incident.resolved`, and `incident.reassigned`
webhook payloads. Each subcommand causes PagerDuty to POST to the
webhook endpoint that integration-manager has configured for the
`demoincidentwebhookmode-…` integration.

| Subcommand | PagerDuty API                             | Webhook fired by PagerDuty |
|------------|-------------------------------------------|----------------------------|
| `trigger`  | Events API v2 `POST /v2/enqueue`          | `incident.triggered`       |
| `resolve`  | Events API v2 `POST /v2/enqueue`          | `incident.resolved`        |
| `reassign` | REST API `PUT /incidents/{id}`            | `incident.reassigned`      |

## Prerequisites

Values are loaded from `bootstrap/demo.env` (never commit that file).

| Variable | Used by             | How to get it |
|---------|---------------------|---------------|
| `PAGERDUTY_ROUTING_KEY` | `trigger`, `resolve` | Integration key from the PagerDuty service (Events API v2 integration). |
| `PAGERDUTY_API_TOKEN`   | `reassign`           | PagerDuty user setting → API Access → create a "General Access REST API Key". |
| `PAGERDUTY_USER_EMAIL`  | `reassign`           | Email of any valid PagerDuty user in the account (used as the `From:` actor header). Overridable with `--email`. |

For `reassign` to produce a webhook, the subscription must have
`incident.reassigned` checked in its "Events to send" list. Same for
`incident.resolved`.

## Usage

```
pd-incident.sh trigger  [--summary "text"] [--dedup-key KEY] [--severity warning|error|critical|info]
pd-incident.sh resolve  --dedup-key KEY
pd-incident.sh reassign --incident-id INC --user-id USER [--email EMAIL]
```

### trigger

Fires an `incident.triggered` event.

```
bootstrap/pd-incident.sh trigger
bootstrap/pd-incident.sh trigger --summary "smoke test"
bootstrap/pd-incident.sh trigger --dedup-key smoke-1 --severity error
```

- `--summary`  defaults to `"Scripted probe at <ISO-8601 UTC>"`.
- `--dedup-key` defaults to `scripted-probe-<random-8-hex>`. Save this — you
  need it to `resolve` the same incident later.
- `--severity` one of `warning` (default), `error`, `critical`, `info`.

Sample output prints the dedup key and the HTTP response from PagerDuty:

```
action     : trigger
dedup_key  : scripted-probe-1e9c69de
summary    : smoke test
severity   : warning
occurred_at: 2026-07-15T06:17:08Z
--- request ---
HTTP/1.1 202 Accepted
{"message":"Event processed","status":"success","dedup_key":"scripted-probe-1e9c69de"}
```

### resolve

Fires `incident.resolved` on the incident matching `--dedup-key`. PagerDuty
matches by dedup_key, so this must be the same one used at trigger time (or a
key belonging to an incident PagerDuty auto-generated one for).

```
bootstrap/pd-incident.sh resolve --dedup-key smoke-1
```

If PagerDuty can't find a matching live incident, the response is still 202
Accepted but nothing changes on their side and no webhook fires.

### reassign

PUT `/incidents/{id}` on the REST API. Requires the incident's PagerDuty ID
(e.g. `Q1F6JPQK8386FP` — the top-level `spec.identifier` you saw in Mongo)
and the target user ID (also a PagerDuty ID, e.g. `PL51ZE6`).

```
bootstrap/pd-incident.sh reassign \
  --incident-id Q1F6JPQK8386FP \
  --user-id PL51ZE6
```

- `--email` is the actor's email (populates the `From:` header the REST API
  requires). Defaults to `$PAGERDUTY_USER_EMAIL`.

## End-to-end verification (Harness side)

After running a subcommand, wait 5–15 seconds for PagerDuty's webhook to fire,
then check:

1. Webhook receipt in integration-manager logs:
   ```
   kubectl logs deploy/integration-manager --since=2m \
     | grep -E 'webhook payload accepted|webhook ingest event processed|entity_rejected'
   ```
2. The entity in Mongo (`entities` collection):
   ```javascript
   db.entities.find({
     integration_id: "demoincidentwebhookmode-mbpyu5",
     kind: "incidents"
   }).sort({ created: -1 }).limit(1).pretty()
   ```
   The top-level `identifier` matches `spec.identifier` (both = the PagerDuty
   incident ID from `event.data.id`). `spec.status` reflects the last event
   type. `related_fields` should include `entity_ref:<service>` and
   `type:incident.<action>`.

## Gotchas

- Multiple replicas: `kubectl logs deploy/…` shows only one pod. If a webhook
  isn't visible, grep every pod:
  ```
  for p in $(kubectl get pods -l app=integration-manager -o name); do
    echo "=== $p ==="; kubectl logs "$p" --since=2m | grep webhook
  done
  ```
- PagerDuty delivery latency: 3–8 seconds is normal. If you `sleep` too little
  after `trigger` you'll miss the webhook in the log grep.
- `trigger` without `--dedup-key` always creates a NEW incident (random key).
  To poke the same incident twice, pass a fixed `--dedup-key` both times.
- The `event.data.id` PagerDuty assigns is NOT the same as the `dedup_key`.
  `dedup_key` is what YOU pass; `event.data.id` is what PagerDuty mints and
  puts in the webhook payload. Only `event.data.id` shows up in the entity.
