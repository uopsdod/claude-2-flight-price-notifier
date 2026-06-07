---
name: m1-2-fetch-prices-on-schedule-checklist
description: Flight Price Notifier Milestone 1.2 verification — confirms the parser_wrapper + parser Lambdas read routes from S3, fetch cheapest fares for the two routes (TPE→TYO, TPE→SEL) via Travelpayouts, match subscribers (no payment guard in M1), enqueue to the fare SQS queue, and the EventBridge schedule is wired. Use when the student says "驗收 M1.2", "check M1.2", or after `m1-2-fetch-prices-on-schedule` Step 4.
---

# M1.2 — Fetch-on-Schedule Checklist

## What this skill does

Confirms M1.2 really works: routes load from S3, the parser fetches real fares + matches subscribers + enqueues to SQS, and EventBridge triggers the wrapper. Emits `READY for M1.3`. Run after `m1-2-fetch-prices-on-schedule` Step 5 (EventBridge wired).

## Flow being verified

```
 ┌──── Flight Fare Checker ──────────────────────────────────────────────────┐
 │   ┌──────────┐     ┌────────────────┐         ┌─────────────────────┐     │
 │   │  Event   │────▶│  Parser Wrapper│────────▶│  Parser  (×N routes)│     │  D = schedule
 │   │  Bridge  │ 30m │  λ             │ invoke  │          λ  λ  λ     │     │  B = Lambdas run
 │   └──────────┘     └───────┬────────┘  /route └────┬──────────┬─────┘     │
 │              admin ✈ ──▶   ▼ read routes           │ scan     ▲ fetch     │
 │              ┌────────────────┐  ┌────────────────┐│cheapest  │           │
 │              │ Flight Routes  │  │ Subscriptions  │◀┘  ┌───────┴────────┐  │  A = config+queue
 │              │ [S3]      (A)  │  │ [DynamoDB](C)  │    │ travelpayouts  │  │  C = match+enqueue
 │              └────────────────┘  └────────────────┘    └────────────────┘  │
 │   match → SQS flight-fare-queue (A2/C1) ─▶ M1.3                            │
 └────────────────────────────────────────────────────────────────────────────┘
```
(Letters map to the check sections below: **A** config+queue+zip, **B** Lambdas run, **C** match→enqueue, **D** schedule wired.)

## Execution mode

Mainly **Cowork** — paste each check to the agent with the **AWS API MCP**; CLI mode runs the same `aws` lines directly. All commands `--region us-east-1`, `[default]` profile (no `--profile`). Two Cowork rules apply here: **don't try to read an `aws lambda invoke` output file** (the MCP can't read it back) — verify the **effect** (logs / queue depth); and **no JMESPath backtick literals** in `--query`.

## How to run

Run each check, report results. (Seed a test subscriber whose `target_price` is above the live fare — see the main skill Step 4 — so the match path runs.)

### Section A — Config + queue + deploy artifact exist
- **A1** S3 routes config loads:
  ```bash
  aws s3 cp s3://flight-config-<ACCOUNT_ID>/flight-routes.json - --region us-east-1
  ```
  Expect the two routes (tokyo / seoul).
- **A2** Fare queue exists:
  ```bash
  aws sqs get-queue-url --queue-name flight-fare-queue --region us-east-1
  ```
- **A3** The parser zip was uploaded to S3 (the Cowork S3-deploy artifact):
  ```bash
  aws s3 ls s3://flight-config-<ACCOUNT_ID>/lambda/ --region us-east-1
  ```
  Expect `parser.zip` (and `wrapper.zip`). Absent → the Step 3 MCP-zip→`s3 cp` didn't run; the functions can't have deployed from S3.

### Section B — Lambdas exist & run
- **B1** Both functions exist:
  ```bash
  aws lambda get-function --function-name flight-parser --region us-east-1 --query 'Configuration.FunctionName'
  aws lambda get-function --function-name flight-parser-wrapper --region us-east-1 --query 'Configuration.FunctionName'
  ```
- **B2** Parser invoke succeeds for one route — **verify by logs, not the output file** (in Cowork the MCP can't read the file `invoke` writes; `invoke` also rejects `--query`/`--cli-binary-format`):
  ```bash
  aws lambda invoke --function-name flight-parser \
    --payload '{"origin":"TPE","destination":"TYO","route":"TPE-TYO"}' out.json \
    --region us-east-1
  # the real check is B3's logs (a clean run, no Runtime.ImportModuleError / AccessDeniedException)
  ```
  A `Runtime.ImportModuleError` here = a file missing from the S3 zip (re-do main Step 3); `AccessDeniedException` = the Step 1 role merge dropped a statement.
- **B3** Logs show a realistic cheapest fare per route:
  ```bash
  aws logs tail /aws/lambda/flight-parser --since 10m --region us-east-1 | grep -iE "TPE|cheapest|price|match|enqueue"
  ```
  TWD fare in a sane range (Tokyo ~NT$8–12k, Seoul ~NT$5–8k — not a placeholder).

### Section C — Matching + enqueue (no payment guard in M1)
- **C1** With a seeded subscriber whose `target_price` is ABOVE the live fare, invoking the parser **enqueues a message**:
  ```bash
  aws sqs get-queue-attributes --queue-url <fare-queue-url> \
    --attribute-names ApproximateNumberOfMessages --region us-east-1
  ```
  Count > 0.
- **C2** **No payment guard:** the matched subscriber has **no `subscription_status`** and is still matched — confirms M1 emails anyone eligible (the `active` filter is M2, not here).
- **C3** A subscriber whose `target_price` is BELOW the live fare is NOT enqueued (the comparison direction is correct).

### Section D — Schedule wired
- **D1** Rule exists & enabled:
  ```bash
  aws events describe-rule --name flight-price-check --region us-east-1 \
    --query '{state:State,sched:ScheduleExpression}'
  ```
  Expect `ENABLED`, `rate(30 minutes)`.
- **D2** Target is `flight-parser-wrapper`:
  ```bash
  aws events list-targets-by-rule --rule flight-price-check --region us-east-1 --query 'Targets[].Arn'
  ```
- **D3** EventBridge has invoke permission (the `add-permission` succeeded). Optional live proof: set `rate(2 minutes)`, wait one cycle, confirm fresh parser logs for both routes, then revert to `rate(30 minutes)`.

## Reporting

| Check | Status | Notes |
|---|---|---|
| A1 S3 routes load | ✅/❌ | |
| A2 fare queue exists | ✅/❌ | |
| A3 parser.zip in S3 (lambda/) | ✅/❌ | Cowork S3-deploy artifact |
| B1 both Lambdas exist | ✅/❌ | |
| B2 parser invoke ok (clean logs) | ✅/❌ | verify by logs, not output file |
| B3 realistic TWD fares | ✅/❌ | |
| C1 match → enqueued | ✅/❌ | the key one |
| C2 no payment guard (status-less row matched) | ✅/❌ | M1 design |
| C3 below-target NOT enqueued | ✅/❌ | comparison correct |
| D1 rule enabled (30 min) | ✅/❌ | |
| D2 target = parser_wrapper | ✅/❌ | |
| D3 schedule fires | ✅/⚠️ | |

**Verdict:**
- All ✅ → 「M1.2 驗收通過 ✅ READY for M1.3。跟我說『啟動 M1.3』。」
- Any ❌ → name failures + recovery:
  - **`Runtime.ImportModuleError`** → a file missing from the S3 zip; re-do main Step 3 (zip `index.py`+`travelpayouts.py`+`routes.py` flat, re-`s3 cp`, `update-function-code --s3-bucket/--s3-key`).
  - **`AccessDeniedException`** → the Step 1 `put-role-policy` merge dropped a statement; re-apply `flight-data` with S3+SQS+InvokeFunction **and** the original DynamoDB+Secrets.
  - **No fares** → check the Travelpayouts token + next-month/TWD + `CONFIG_BUCKET` env + S3 routes; **empty fares** → Travelpayouts cache, try another month.
  - **Nothing enqueued** → check the `Scan` filter (route only, NO status in M1) + SQS `SendMessage` perm.
  - **Schedule not firing** → check `add-permission` + the wrapper reading routes from S3.
  Then re-run `驗收 M1.2`.
