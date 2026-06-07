---
name: m1-3-email-on-target-prerequisites
description: Prerequisites before M1.3 of the Flight Price Notifier course — a Resend account + API key for sending alert emails, plus confirmation that M1.2's parser pipeline + the fare SQS queue + the notification_history table are in place. Use when the student starts M1.3, or when `m1-3-email-on-target` / `-checklist` detects Resend is missing.
---

# M1.3 Prerequisites — Resend

## What this skill does

M1.3 adds one account: **Resend** (transactional email). Everything else carries over from M1.2 (the `flight-parser`/`flight-parser-wrapper` Lambdas, the **`flight-fare-queue`** SQS that they enqueue matches to, the AWS role, and the **`notification_history`** DynamoDB table used for dedup). This skill gets Resend ready and confirms that carryover.

## Flow structure (where M1.3 sits)

M1.3 builds the **Notification box** — the consumer that drains the **SQS** queue M1.2 fills, dedups against **Notification History [DynamoDB]**, and sends **Email [Resend]**. This prereq gets **Resend** ready and confirms the M1.2 carryover (the queue + the history table) that box depends on.

```
  (M1.2 fills) ┌─────┐     ┌──── Notification (M1.3 builds this) ──────────┐
   ───────────▶│ SQS │────▶│  ┌─────────────────────────┐                  │
               └─────┘     │  │ Flight Fare Notification│   Notification   │
                           │  │   λ   · 24h floor /      │◀─ History        │
                           │  │       ≥20% / ≥NT$2000    │   [DynamoDB]     │
                           │  │   · email_render →Resend │   (dedup)        │
                           │  └────────────┬────────────┘                  │
                           └───────────────┼────────────────────────────────┘
                                           ▼
                                   ┌────────────────┐
                                   │ Email [Resend] │  ◀ this prereq sets up the Resend account/key
                                   └────────────────┘

 Legend:  ▮ teal = main component (λ)   ▮ pink = user data (Notification History [DynamoDB])   ▮ grey = SQS
```

## When to load this skill

- "M1.3 環境準備" / any time M1.3 detects Resend is missing.

## Execution mode: Cowork (default) vs CLI

This course runs mainly in **Cowork** — you paste the **`ask """ … """`** blocks below to the Cowork agent verbatim (the agent makes the HTTP calls / runs the `aws` commands for you). You never need a local terminal. On the local Claude CLI instead, run the `curl`/`aws` equivalents directly. `aws` commands use `--region us-east-1`.

## Step 1 — Resend account + API key

1. Sign up free at https://resend.com/.
2. **API Keys → Create API Key** → a **Sending-access** key is enough (this course never writes contacts/audiences) → copy `re_...`. (https://resend.com/api-keys)
3. For the course demo you'll send from **`onboarding@resend.dev`** (no domain setup needed). Verifying your own sending domain (SPF/DKIM) is part of M3 go-live.

> ⚠️ **The demo sender only delivers to your OWN Resend-account email.** While `from` is `onboarding@resend.dev`, a send to any *other* address is **accepted (shows in the Resend log) but never arrives**. So test below — and seed the M1.3 test subscriber — with **the email you signed up to Resend with**. (To email a real, different user, verify your own domain first — M3.) See [[resend-best-practice]] Rule 1.

**Verify** the key works by actually sending a test email. **Why this isn't a `curl` in Cowork:** the Cowork sandbox **can't reach `api.resend.com`** — the network proxy blocks it (`403` on `CONNECT`), and the agent's web-fetch tool is **GET-only**, so a POST to Resend can't run there. The one place in your stack that *does* have outbound internet is a **Lambda** — which is exactly where the real alert email will be sent from. So we verify from there. (Same two-host reality as the AWS deploy — see [[aws-best-practice]] *Cowork execution constraints*, and [[resend-best-practice]] Rule 0.)

**1. Store the key as the `flight/resend` secret** (check-then-collect — if a previous session already stored it, skip). Paste to the Cowork agent — swap in your key and your **Resend-account email**:

ask """
>
Store the Resend secret in Secrets Manager, us-east-1 — check first, then create or update:
>
```bash
aws secretsmanager describe-secret --secret-id flight/resend --region us-east-1 --query "Name"
```
>
If that returns `flight/resend`, it already exists — skip. If ResourceNotFoundException, create it:
>
```bash
aws secretsmanager create-secret --name flight/resend --secret-string '{"api_key":"re_REPLACE","from":"onboarding@resend.dev","test_to":"YOUR_RESEND_ACCOUNT_EMAIL"}' --region us-east-1
```
>
(`test_to` is only used by the throwaway test below; M1.3 reads `api_key` + `from`.)
>
"""

**2. Deploy a throwaway `flight-resend-test` Lambda, invoke it, and read the result from its logs** — all in one prompt. It's an inline-CFN single file that reads the secret and POSTs to Resend from *inside AWS* (which has internet); you verify by the logs + your inbox (in Cowork you can't read the invoke's output file). Paste to the agent, replacing `<ACCOUNT_ID>`:

ask """
>
Create a one-off `flight-resend-test` Lambda via inline CloudFormation in us-east-1. Handler `index.handler`, Runtime python3.12, Role `arn:aws:iam::<ACCOUNT_ID>:role/flight-lambda-role`, Timeout 15. JSON-escape this code into the template's `Code.ZipFile`:
>
```python
import json, urllib.request, boto3
def handler(e, c):
    s = json.loads(boto3.client("secretsmanager").get_secret_value(SecretId="flight/resend")["SecretString"])
    body = {"from": s["from"], "to": s["test_to"], "subject": "resend test", "html": "<p>it works</p>", "text": "it works"}
    req = urllib.request.Request("https://api.resend.com/emails", data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + s["api_key"], "Content-Type": "application/json"}, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            print("RESEND_OK", r.status, r.read().decode())
    except urllib.error.HTTPError as ex:
        print("RESEND_ERR", ex.code, ex.read().decode())
    return {"done": True}
```
>
Then poll until the stack is ready:
>
```bash
aws cloudformation describe-stacks --stack-name flight-resend-test --query "Stacks[0].StackStatus" --region us-east-1
```
>
Once it's CREATE_COMPLETE, invoke it and show me its logs:
>
```bash
aws lambda invoke --function-name flight-resend-test --payload '{}' out.json --region us-east-1
aws logs filter-log-events --log-group-name /aws/lambda/flight-resend-test --query "events[].message" --region us-east-1
```
>
"""

**Expect** a log line `RESEND_OK 200 {"id":"..."}` **and** the test email in your Resend-account inbox (check spam). `RESEND_ERR 401` = wrong key; `RESEND_ERR 403/422` = a `from` you're not allowed to send from (stay on `onboarding@resend.dev` until M3). When it passes, delete the throwaway:

```bash
aws cloudformation delete-stack --stack-name flight-resend-test --region us-east-1
```

> *(CLI fallback only — if you have a local terminal: `curl -s -X POST https://api.resend.com/emails -H "Authorization: Bearer re_REPLACE" -H "Content-Type: application/json" -d '{"from":"onboarding@resend.dev","to":"<YOUR_RESEND_ACCOUNT_EMAIL>","subject":"resend test","html":"<p>it works</p>","text":"it works"}'`. Or skip code entirely: **Resend dashboard → Emails → Send** — no network needed from your side.)*

## Step 2 — Confirm M1.2 carryover

Paste this to the Cowork agent (it runs each `aws` call via the AWS API MCP):

ask """
>
Confirm my M1.2 carryover is in place — run these in us-east-1 and show me each result:
>
1. Parser Lambdas exist: `aws lambda get-function --function-name flight-parser --region us-east-1 --query "Configuration.FunctionName"` and the same for `flight-parser-wrapper`.
>
2. Fare queue exists: `aws sqs get-queue-url --queue-name flight-fare-queue --region us-east-1`
>
3. notification_history table is ACTIVE: `aws dynamodb describe-table --table-name notification_history --region us-east-1 --query "Table.TableStatus"`
>
"""

If the parser Lambdas / queue are missing → finish M1.2. If `notification_history` is missing → redo M1.1 Step 1.

## Verify (all must pass)

- Resend test email received ✅
- `flight-parser` + `flight-parser-wrapper` Lambdas exist ✅
- `flight-fare-queue` resolves ✅
- `notification_history` table ACTIVE ✅

## Next step

Return to `m1-3-email-on-target` Step 1 (store the Resend secret).
