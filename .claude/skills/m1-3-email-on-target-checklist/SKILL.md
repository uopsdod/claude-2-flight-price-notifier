---
name: m1-3-email-on-target-checklist
description: Flight Price Notifier Milestone 1.3 verification — confirms the fare-notification Lambda consumes the fare SQS queue, sends the price-drop email via Resend (no payment guard in M1), dedups against notification_history (24h floor), and re-alerts on a notably cheaper fare. Use when the student says "驗收 M1.3", "check M1.3", or after `m1-3-email-on-target` Step 3.
---

# M1.3 — Email-on-Target Checklist

## What this skill does

Confirms M1.3 really works: the fare-SQS consumer sends a real email, dedups via `notification_history`, re-alerts only on a meaningfully cheaper fare, and emails **without** any payment guard. Emits `READY for M2`. Run after `m1-3-email-on-target` Step 3.

## Flow being verified (the Notification box)

```
 (M1.2) ┌─────┐    ┌──── Notification ───────────────────────────────┐
  ─────▶│ SQS │───▶│  ┌────────────────────────┐   ┌───────────────┐ │
        └─────┘    │  │ Flight Fare            │──▶│ Notification  │ │  A = secret + wired
        (A)        │  │ Notification λ  (A,B)  │◀──│ History [DDB] │ │  B = email fires (Resend)
                   │  └───────────┬────────────┘   └───────────────┘ │  C = dedup blocks repeat
                   └──────────────┼───────(C,D)─────────────────────┘  D = re-alert + negative
                                  ▼
                          ┌────────────────┐
                          │ Email [Resend] │  ◀ B = the alert lands in a real inbox
                          └────────────────┘
```
(Letters map to the check sections below: **A** Resend+consumer wired, **B** email fires, **C** dedup, **D** re-alert/negative.)

## How to run

Run each check and report. You'll seed a test match (a subscriber whose `target_price` is above the live fare) so the parser enqueues it; use a real inbox you can check. All `aws` commands `--region us-east-1`.

### Section A — Resend + consumer wired
- **A1** Resend secret present:
  ```bash
  aws secretsmanager describe-secret --secret-id flight/resend --region us-east-1 --query 'Name'
  ```
- **A2** The consumer exists and is wired to the fare queue (event-source mapping):
  ```bash
  aws lambda get-function --function-name flight-fare-notification --region us-east-1 --query 'Configuration.FunctionName'
  aws lambda list-event-source-mappings --function-name flight-fare-notification --region us-east-1 --query 'EventSourceMappings[].{src:EventSourceArn,state:State}'
  ```
  Expect a mapping from `flight-fare-queue`, `Enabled`.
- **A3** The dedup knobs are set:
  ```bash
  aws lambda get-function-configuration --function-name flight-fare-notification --region us-east-1 --query 'Environment.Variables'
  ```
  Expect `NOTIFY_FLOOR_HOURS`, `REALERT_PCT`, `REALERT_ABS_TWD`.

### Section B — Email fires on a target hit (no payment guard)
- **B1** Seed a test subscriber with `target_price` ABOVE the live fare (e.g. TPE→TYO target NT$12,000 vs live ~NT$9,531) — **and no `subscription_status`** (M1 has none). Run the parser so it enqueues, then watch the consumer:
  ```bash
  aws lambda invoke --function-name flight-parser \
    --payload '{"origin":"TPE","destination":"TYO","route":"TPE-TYO"}' out.json \
    --region us-east-1
  # read the consumer's logs (the MCP rejects `logs tail` — use filter-log-events):
  aws logs filter-log-events --log-group-name /aws/lambda/flight-fare-notification \
    --query "events[].message" --region us-east-1
  ```
- **B2** **The decisive test:** the inbox receives the alert (subject 「✈️ 台北 → 東京 降價通知！NT$9,531 已達標」). Confirm the card shows the USD headline + 約 NT$, the user's target, and the 「立即訂購」 button.
- **B3** **No payment guard:** the subscriber was emailed despite having **no `subscription_status`** — confirms M1 emails anyone eligible (the guard is M2).

### Section C — Dedup blocks repeats
- **C1** Re-run the parser immediately (same match re-enqueues) → **no second email** arrives (within `NOTIFY_FLOOR_HOURS`); logs say "skipped (deduped)".
- **C2** A `notification_history` row was written:
  ```bash
  aws dynamodb query --table-name notification_history \
    --key-condition-expression 'pk = :p' \
    --expression-attribute-values '{":p":{"S":"you@example.com#TPE-TYO"}}' \
    --no-scan-index-forward --max-items 3 --region us-east-1
  ```
  Shows a recent `sent_at` + `price`.

### Section D — Re-alert on a notably cheaper fare + negative case
- **D1** Simulate a cheapest that's ≥20% OR ≥NT$2,000 below the last alerted price → a fresh email DOES go out despite the window (a new `notification_history` row appears).
- **D2** A subscriber whose `target_price` is BELOW the live fare gets no email (the parser never enqueues it).

## Reporting

| Check | Status | Notes |
|---|---|---|
| A1 Resend secret | ✅/❌ | |
| A2 consumer wired to fare queue | ✅/❌ | |
| A3 dedup env vars set | ✅/❌ | |
| B1/B2 email received | ✅/❌ | the key one |
| B3 no payment guard (status-less emailed) | ✅/❌ | M1 design |
| C1 dedup blocks repeat | ✅/❌ | |
| C2 history row written | ✅/❌ | |
| D1 re-alert on big drop | ✅/❌ | |
| D2 below-target → no email | ✅/❌ | |

**Verdict:**
- All ✅ → 「M1.3 驗收通過 ✅ 你有一個會動的*免費*通知器了。READY for M2。跟我說『啟動 M2』來加上付款門檻。」
- Any ❌ → name failures + recovery (no email → Resend key/from + the SQS event-source mapping + the consumer's history-query logic; duplicate sent → dedup window/`notification_history` write; re-alert not firing → the `REALERT_PCT`/`REALERT_ABS_TWD` comparison), then re-run `驗收 M1.3`.
