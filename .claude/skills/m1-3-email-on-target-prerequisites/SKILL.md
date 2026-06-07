---
name: m1-3-email-on-target-prerequisites
description: Prerequisites before M1.3 of the Flight Price Notifier course — a Resend account + API key for sending alert emails, plus confirmation that M1.2's parser pipeline + the fare SQS queue + the notification_history table are in place. Use when the student starts M1.3, or when `m1-3-email-on-target` / `-checklist` detects Resend is missing.
---

# M1.3 Prerequisites — Resend

## What this skill does

M1.3 adds one account: **Resend** (transactional email). Everything else carries over from M1.2 (the `flight-parser`/`flight-parser-wrapper` Lambdas, the **`flight-fare-queue`** SQS that they enqueue matches to, the AWS role, and the **`notification_history`** DynamoDB table used for dedup). This skill gets Resend ready and confirms that carryover.

## When to load this skill

- "M1.3 環境準備" / any time M1.3 detects Resend is missing.

## Execution mode

CLI uses `aws`/`curl`; Cowork uses MCP/dashboards. `aws` commands `--region us-east-1`.

## Step 1 — Resend account + API key

1. Sign up free at https://resend.com/.
2. **API Keys → Create API Key** → copy `re_...`.
3. For the course demo you'll send from **`onboarding@resend.dev`** (no domain setup needed). Verifying your own sending domain (SPF/DKIM) is part of M3 go-live.

**Verify** (a real send to your own inbox):
```bash
curl -s -X POST https://api.resend.com/emails \
  -H "Authorization: Bearer re_REPLACE" -H "Content-Type: application/json" \
  -d '{"from":"onboarding@resend.dev","to":"you@example.com","subject":"resend test","html":"<p>it works</p>"}'
```
Expect a JSON `{"id": "..."}` and the email in your inbox (check spam).

## Step 2 — Confirm M1.2 carryover

```bash
# parser Lambdas exist (the pipeline that enqueues matches)
aws lambda get-function --function-name flight-parser --region us-east-1 --query 'Configuration.FunctionName'
aws lambda get-function --function-name flight-parser-wrapper --region us-east-1 --query 'Configuration.FunctionName'
# fare queue exists (M1.3's consumer reads it)
aws sqs get-queue-url --queue-name flight-fare-queue --region us-east-1
# notification_history table exists (dedup target)
aws dynamodb describe-table --table-name notification_history --region us-east-1 --query 'Table.TableStatus'
```
If the parser Lambdas / queue are missing → finish M1.2. If `notification_history` is missing → redo M1.1 Step 1.

## Verify (all must pass)

- Resend test email received ✅
- `flight-parser` + `flight-parser-wrapper` Lambdas exist ✅
- `flight-fare-queue` resolves ✅
- `notification_history` table ACTIVE ✅

## Next step

Return to `m1-3-email-on-target` Step 1 (store the Resend secret).
