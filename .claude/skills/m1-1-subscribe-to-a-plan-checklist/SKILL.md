---
name: m1-1-subscribe-to-a-plan-checklist
description: Flight Price Notifier Milestone 1.1 verification — confirms the DynamoDB subscriptions table exists, the save_subscription Lambda + API Gateway work, and submitting the subscribe form creates a subscription row (M1 has no subscription_status — that's M2). Use when the student says "驗收 M1.1", "check M1.1", or after `m1-1-subscribe-to-a-plan` Step 5.
---

# M1.1 — Subscribe Checklist

## What this skill does

Confirms M1.1 is really done: DynamoDB tables, secret, IAM, Lambda, API Gateway, and the end-to-end "form → subscription row" path. Emits a `READY for M1.2` verdict. Run after `m1-1-subscribe-to-a-plan` Step 5.

## Flow structure (what these checks prove)

The checks below verify the **Product Site → Subscriptions [DynamoDB]** arrow is real end-to-end.

```
                       ┌────────────────────┐
                       │  Database          │   ← Supabase (AUTH ONLY)
                       │  [Supabase] ⚡     │
                       └─────────┬──────────┘
                                 │ sign-in (auth)
                       ┌─────────▼──────────┐
                       │   Product Site     │   ← Vercel host (your M0 site)
                       │   [Vercel host] ▲  │
                       └─────────┬──────────┘
                                 │ POST /subscribe   ← Section D proves this arrow
   ┌──── Flight Fare Checker ────┼──────────────────────────────────┐
   │                             ▼                                   │
   │              ┌──────────────────────────┐                      │
   │              │  Subscriptions           │  ◀── Sections A–C     │
   │              │  [DynamoDB]              │      (table/Lambda/row)│
   │              └──────────────────────────┘                      │
   │   (Parser / EventBridge / S3 side of this box = M1.2)          │
   └────────────────────────────────────────────────────────────────┘
```

## Execution mode

CLI mode uses `aws`; Cowork mode uses the AWS MCP or the console. All `aws` commands use `--region us-east-1`.

## How to run

You (Claude Code) actively run each check and report. Ask the student for: the API Gateway base URL and the live Vercel site URL.

### Section A — DynamoDB tables
- **A1** `subscriptions` exists & ACTIVE:
  ```bash
  aws dynamodb describe-table --table-name subscriptions --region us-east-1 \
    --query 'Table.{status:TableStatus,keys:KeySchema}'
  ```
  Expect `ACTIVE`, HASH=email, RANGE=route.
- **A1b** `notification_history` exists & ACTIVE (created in M1.1 Step 1, used in M1.3):
  ```bash
  aws dynamodb describe-table --table-name notification_history --region us-east-1 \
    --query 'Table.{status:TableStatus,keys:KeySchema}'
  ```
  Expect `ACTIVE`, HASH=pk, RANGE=sent_at.

### Section B — AWS plumbing
- **B1** Secret present (no `flight/supabase`):
  ```bash
  aws secretsmanager list-secrets --region us-east-1 --query "SecretList[].Name"
  ```
  Look for `flight/travelpayouts` in the list (others arrive in later milestones). **Don't** use a backtick JMESPath filter like `SecretList[?starts_with(Name,\`flight/\`)]` — it errors through the AWS API MCP ("Unknown token"); list all names and scan.
- **B2** Role has DynamoDB perms: `aws iam get-role-policy --role-name flight-lambda-role --policy-name flight-data --query 'PolicyDocument.Statement[].Action'`
- **B3** Lambda exists: `aws lambda get-function --function-name flight-save-subscription --region us-east-1 --query 'Configuration.FunctionName'`

### Section C — Lambda works (direct invoke)
- **C1** Plain invoke (no `--query`/`--cli-binary-format` — they fail through the MCP; and don't `cat` the output file — the MCP can't read it back):
  ```bash
  aws lambda invoke --function-name flight-save-subscription \
    --payload '{"body":"{\"email\":\"checklist@test.com\",\"plan_name\":\"tokyo\",\"target_price\":10000}"}' \
    m11.json --region us-east-1
  ```
  Don't judge success by the output file. **C2 is the real check.**
- **C2** The row landed (this is the authoritative "the Lambda worked" check):
  ```bash
  aws dynamodb get-item --table-name subscriptions \
    --key '{"email":{"S":"checklist@test.com"},"route":{"S":"TPE-TYO"}}' \
    --region us-east-1
  ```
  Expect `route` = `TPE-TYO`, `currency` = `TWD`, `target_price` set, and **no `subscription_status`** (that field is M2).

### Section D — API Gateway + form (end-to-end)
- **D1** Route responds — **mode-dependent:**
  - **CLI:** `curl -s -X POST "<api>/subscribe" -H "content-type: application/json" -d '{"email":"e2e@test.com","plan_name":"seoul","target_price":7000}'`
  - **Cowork (no POST client):** you **can't** run a POST (no shell with AWS network; the web tool is GET-only). Prove the API→Lambda plumbing two other ways: the **direct `invoke` (C1/C2)** proves the Lambda, and the **live-form submit (D2)** is the authoritative POST + CORS proof. *(Optional: if you added the `GET /subscriptions` route in main-Step 6, hitting it from the browser/web-fetch tool also exercises the API-Gateway→Lambda path without a POST client.)*
- **D2** The student submits the **real form** on the live Vercel site → a new subscription row appears in DynamoDB (no `subscription_status` — that's M2). **(The decisive POST + CORS test, both modes.)**
- **D3** CORS works — the browser `fetch` from the Vercel origin succeeds (no console CORS error).

### Section E — Subscribed state shows (the closed loop)
- **E1** `GET /subscriptions?email=…` returns the user's rows (a GET — testable from a browser or the Cowork web-fetch tool):
  ```
  GET <api>/subscriptions?email=e2e@test.com   → JSON array including the seoul row
  ```
- **E2** **On the live site**, after subscribing + reloading, the subscribed plan's card shows a **已訂閱 / Subscribed** badge, the saved target price, and an **更新目標價 / Update** button (not a fresh-looking 開始追蹤). Confirms M1.1 isn't write-only.

## Reporting

| Check | Status | Notes |
|---|---|---|
| A1 subscriptions ACTIVE | ✅/❌ | |
| A1b notification_history ACTIVE | ✅/❌ | used in M1.3 |
| B1 secret present | ✅/❌ | |
| B2 IAM has DynamoDB | ✅/❌ | |
| B3 Lambda exists | ✅/❌ | |
| C1 invoke ok | ✅/❌ | plain invoke; judge by C2 |
| C2 subscription row written (no status) | ✅/❌ | authoritative |
| D1 API route reachable | ✅/❌ | CLI: curl POST · Cowork: via D2 / GET |
| D2 form → row (live) | ✅/❌ | the key one (POST + CORS) |
| D3 CORS ok | ✅/❌ | |
| E1 GET /subscriptions returns rows | ✅/❌ | |
| E2 subscribed-state shows on site | ✅/❌ | closes the write-only loop |

**Verdict:**
- All ✅ → 「M1.1 驗收通過 ✅ READY for M1.2。跟我說『啟動 M1.2』。」
- Any ❌ → name the failed checks + recovery (CORS → set on HTTP API; no row → check the Lambda's `put_item` + IAM DynamoDB perms + Decimal conversion; subscribed-state missing → add the `GET /subscriptions` route + the dashboard fetch from main-Step 6; MCP errors → see [[aws-best-practice]] *Cowork execution constraints*), then re-run `驗收 M1.1`.
