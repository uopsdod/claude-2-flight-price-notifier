---
name: m1-1-subscribe-to-a-plan
description: Flight Price Notifier Milestone 1.1 — let a signed-in user subscribe to a flight notification plan (pick Tokyo/Seoul + TWD target price), saved to a DynamoDB subscriptions table via an AWS Lambda behind API Gateway. M1 has NO payment guard — a row simply means "eligible for alerts" (the subscription_status field is introduced in M2). Supabase is auth-only. Use when the student says "啟動 M1.1", "start M1.1", "做訂閱功能", "讓使用者訂閱航線", or any variant mapping to "使用者選方案+目標價並存進 DynamoDB".
---

# M1.1 — Subscribe to a Plan（讓使用者訂閱一條航線）

## What this skill does

By the end the student has:

1. A **DynamoDB table `subscriptions`** (PK `email`, SK `route`) — **all app data lives on AWS, not Supabase** (Supabase is auth-only).
2. A **subscribe UI** (added to the M0 site) offering **two fixed plans** — the user picks one and enters a **target price in TWD**:
   - **Plan A — 台北 ✈ 東京 (TPE → TYO)**
   - **Plan B — 台北 ✈ 首爾 (TPE → SEL)**
   - **No dates.** Target customers are budget-driven travelers who don't care *when* they fly — they just want a ticket under their budget. So a subscription is just `(plan, target_price)`, nothing about dates.
3. An **AWS Lambda `flight-save-subscription`** behind **API Gateway** `POST /subscribe` that validates the form and writes a row to **DynamoDB**. **In M1 there is NO `subscription_status`** — the row's mere existence means "eligible for alerts."
4. End state: pick a plan + enter a TWD budget → a new subscription row appears in DynamoDB `subscriptions`.

**Out of scope for M1.1:** the price-fetch loop (M1.2), email (M1.3), Stripe payment (M2). **No payment guard in M1** — anyone who subscribes is eligible (the `subscription_status` field + the paywall are *introduced in M2*). **Also out of scope (deliberately simplified):** letting users choose dates, origins, or other routes — M1 ships exactly two fixed routes.

> **Architecture note:** Supabase = **auth only** (the M0 login). All subscription data lives in **one DynamoDB table on AWS**. The join key across Supabase-auth / DynamoDB / Stripe is the user's **email**. The browser never holds AWS credentials — it POSTs to API Gateway; only the Lambda touches DynamoDB (via its IAM role).

## When to load this skill

- "啟動 M1.1" / "start M1.1" / "做訂閱功能" / "讓使用者訂閱航線"

Requires M0 done. **Before Step 1, confirm `m0-landing-and-signin-checklist` is green** and `m1-1-subscribe-to-a-plan-prerequisites` is complete (AWS access (`[default]` profile) + Travelpayouts token). If not, load those first.

## Execution mode: Cowork vs CLI

AWS resources are created with the `aws` CLI in this skill. In Cowork, use the AWS MCP equivalents (or have the student run the `aws` commands in their own terminal). Every command uses `--region us-east-1`.

## Required external accounts (new this milestone)

| # | Service | Used for |
|---|---|---|
| 5 | AWS (`[default]` profile, user `admin-for-cowork`) | Lambda + API Gateway |
| 6 | Travelpayouts (`travelpayouts.com`) | flight price API token (used heavily in M1.2; set up now) |

## Flow structure (what M1.1 builds)

M1.1 wires the **Product Site → Subscriptions [DynamoDB]** path inside the **Flight Fare Checker**. The Parser / EventBridge / S3 side of that box is built later (M1.2) — it's intentionally empty here.

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
                                 │ POST /subscribe
   ┌──── Flight Fare Checker ────┼──────────────────────────────────┐
   │                             ▼                                   │
   │              ┌──────────────────────────┐                      │
   │              │  Subscriptions           │  ◀── user data (pink)│
   │              │  [DynamoDB]              │                      │
   │              └──────────────────────────┘                      │
   │                                                                │
   │   (the Parser / Parser Wrapper / EventBridge / S3 side of      │
   │    this box is M1.2 — empty for now)                           │
   └────────────────────────────────────────────────────────────────┘

   Legend:  ▮ orange = manual input   ▮ teal = main component   ▮ pink = user data
   Shared Structure:   [Library Layer]    [Lambda ƛ]
   Repo loop:   Landing Page (Lovable) ──▶ Repo (GitHub) ──R──▶ Product Site (Vercel)
```

**Under the hood of that one arrow:** the Vercel form `POST /subscribe` → **API Gateway** → **`flight-save-subscription` Lambda** → `PutItem` into **DynamoDB `subscriptions`** (M1: no `subscription_status` — a row existing = eligible). The Lambda writes via its **IAM role** (no keys, no external DB); the browser holds **no AWS credentials** — it only POSTs to API Gateway.

## Conversational flow (drive the student; wait after each step)

### Step 1 — Create the DynamoDB table

One table holds everything. PK `email`, SK `route` (`TPE-TYO` / `TPE-SEL` — no dates). PAY_PER_REQUEST so there's no capacity to manage.

```bash
aws dynamodb create-table \
  --table-name subscriptions \
  --attribute-definitions AttributeName=email,AttributeType=S AttributeName=route,AttributeType=S \
  --key-schema AttributeName=email,KeyType=HASH AttributeName=route,KeyType=RANGE \
  --billing-mode PAY_PER_REQUEST \
  --region us-east-1
```

**Row shape** (attributes written by the handlers — DynamoDB is schemaless, so these aren't declared up front):
`email` (PK), `route` (SK, `TPE-TYO`|`TPE-SEL`), `plan_name` (`tokyo`|`seoul`), `origin` (`TPE`), `destination` (`TYO`|`SEL`), `target_price` (N, TWD), `currency` (`TWD`), `created_at`, `updated_at`. **`subscription_status` + `stripe_customer_id` + `stripe_subscription_id` are NOT written in M1 — they're introduced in M2 (the paywall).**

> **Also create the dedup/audit table now** (M1.3 uses it; create it here while you're in the storage step): **`notification_history`** — PK `pk` (S, = `"{email}#{route}"`), SK `sent_at` (S). It records every alert sent (dedup + audit).
> ```bash
> aws dynamodb create-table --table-name notification_history \
>   --attribute-definitions AttributeName=pk,AttributeType=S AttributeName=sent_at,AttributeType=S \
>   --key-schema AttributeName=pk,KeyType=HASH AttributeName=sent_at,KeyType=RANGE \
>   --billing-mode PAY_PER_REQUEST --region us-east-1
> ```

**The two plans** (fixed, seeded in the UI + known to the Lambda — no separate table):

| plan_name | 顯示名稱 | origin | destination | route |
|---|---|---|---|---|
| `tokyo` | 台北 ✈ 東京 | TPE | TYO | TPE-TYO |
| `seoul` | 台北 ✈ 首爾 | TPE | SEL | TPE-SEL |

**Verify before moving on:**
```bash
aws dynamodb describe-table --table-name subscriptions --region us-east-1 \
  --query 'Table.{name:TableName,status:TableStatus,keys:KeySchema}'
```
Shows `ACTIVE` with HASH=email, RANGE=route.

### Step 2 — Store the secrets the Lambda needs

*(No `flight/supabase` — Supabase is auth-only; the Lambda reaches DynamoDB via IAM, not a key.)*

```bash
aws secretsmanager create-secret --name flight/travelpayouts \
  --secret-string '{"token":"REPLACE","marker":"736582"}' \
  --region us-east-1
```
(The Travelpayouts token + marker are in their dashboard → Profile → API token / the ID in the corner. DynamoDB needs no secret — the Lambda uses its IAM role.)

**Verify before moving on:** `aws secretsmanager list-secrets --region us-east-1 --query 'SecretList[].Name'` lists `flight/travelpayouts`.

### Step 3 — Create the Lambda IAM role

> Replace **`<ACCOUNT_ID>`** in the policy below with your account ID — resolve it once: `aws sts get-caller-identity --query Account --output text`. (In Cowork, just tell the agent "use my account ID in the ARNs" and it'll fill it in.)

```bash
aws iam create-role --role-name flight-lambda-role \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
 
aws iam attach-role-policy --role-name flight-lambda-role \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
aws iam put-role-policy --role-name flight-lambda-role --policy-name flight-data \
  --policy-document '{"Version":"2012-10-17","Statement":[
    {"Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":"arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:flight/*"},
    {"Effect":"Allow","Action":["dynamodb:PutItem","dynamodb:UpdateItem","dynamodb:GetItem","dynamodb:Query","dynamodb:Scan"],"Resource":["arn:aws:dynamodb:us-east-1:<ACCOUNT_ID>:table/subscriptions","arn:aws:dynamodb:us-east-1:<ACCOUNT_ID>:table/notification_history"]}
  ]}' \
 
```
**DynamoDB (both tables) + Secrets.** This one shared role is reused by all of M1's Lambdas. **No SNS, no VPC** — Lambdas reach Stripe/Resend/Travelpayouts over plain HTTPS and DynamoDB via the SDK. *(Later milestones extend this same policy: M1.2/M1.3 add `sqs:*` on the two queues + `s3:GetObject` on the routes config + `lambda:InvokeFunction` on `flight-parser`; M2 needs no new perms. Add them as you reach those skills.)*

**Verify before moving on:** `aws iam get-role --role-name flight-lambda-role` succeeds.

### Step 4 — Write & deploy the save_subscription Lambda

The handler takes `{email, plan_name, target_price}`, maps `plan_name` → `(origin, destination)`, builds `route = origin-destination`, and `PutItem`s the row to **DynamoDB** — **no `subscription_status` in M1**. It uses **boto3** (already in the Lambda runtime — no layer/secret needed for DynamoDB). (Implementation: `aws/save_subscription/handler.py` + shared `aws/common/ddb.py`; deploy via `scripts/04_deploy_lambdas.sh` or `aws lambda create-function`.)

```python
import boto3, json, time
from decimal import Decimal
PLANS = {  # the two fixed plans the handler knows about
    "tokyo": {"origin": "TPE", "destination": "TYO"},
    "seoul": {"origin": "TPE", "destination": "SEL"},
}
ddb = boto3.resource("dynamodb").Table("subscriptions")
# validate plan_name in PLANS; target_price a positive number (TWD).
# route = f"{origin}-{destination}"
# ddb.put_item(Item={"email":…, "route":…, "plan_name":…, "origin":…, "destination":…,
#                    "target_price": Decimal(str(target_price)), "currency":"TWD",
#                    "created_at":…, "updated_at":…})   # NO subscription_status — that's M2
```

**Verify before moving on:**
```bash
aws lambda invoke --function-name flight-save-subscription \
  --payload '{"body":"{\"email\":\"test@example.com\",\"plan_name\":\"tokyo\",\"target_price\":10000}"}' \
  /tmp/out.json --region us-east-1 && cat /tmp/out.json
# then read the row back from DynamoDB:
aws dynamodb get-item --table-name subscriptions \
  --key '{"email":{"S":"test@example.com"},"route":{"S":"TPE-TYO"}}' \
  --region us-east-1
```
Expect `route = TPE-TYO`, `currency = TWD`, `target_price = 10000`, and **no `subscription_status`** (that field arrives in M2).

### Step 5 — Expose it via API Gateway + wire the form

```bash
aws apigatewayv2 create-api --name flight-api --protocol-type HTTP --region us-east-1
# create AWS_PROXY integration → route 'POST /subscribe' → $default stage --auto-deploy
# add CORS: AllowOrigins=* AllowMethods=POST,OPTIONS AllowHeaders=content-type
# aws lambda add-permission for apigateway.amazonaws.com
```
Then add the subscribe UI to the M0 site: **two plan cards** (台北✈東京 / 台北✈首爾), each with a **TWD target-price input** and a 「開始追蹤」 button that `fetch`es `POST <api>/subscribe` with `{email, plan_name, target_price}`. (Hint the user with the current cheapest so they pick a sane budget — e.g. Tokyo recently ~NT$9,531, Seoul ~NT$5,989.)

**Verify before moving on:** picking 台北✈東京 + entering NT$10,000 on the live site creates a row in DynamoDB with `route` = `TPE-TYO` (no `subscription_status` — that's M2).

## Things to watch out for

1. **CORS** — the Vercel form is a different origin; without CORS the `fetch` fails silently in the browser. Set it on the HTTP API.
2. **AWS credentials in the front-end** — NEVER. The browser POSTs to API Gateway; only the Lambda (via its IAM role) touches DynamoDB. (The Supabase anon key in the front-end is fine — but it's auth-only, no data.)
3. **Compute `route` in the handler** — `route = origin + "-" + destination` (`TPE-TYO`). It's the DynamoDB sort key. No dates.
4. **Only two plans** — the handler must reject any `plan_name` not in `{tokyo, seoul}`. Don't accept arbitrary origin/destination from the client.
5. **PutItem overwrites by key** — re-subscribing the same (email, route) overwrites the row (idempotent). **In M2** this watch-out grows teeth: there, a re-subscribe must NOT clobber an existing `subscription_status` (don't knock a paid user back). In M1 there's no status, so a plain overwrite is fine.
6. **No payment guard in M1** — M1.1 writes no `subscription_status` at all; everyone who subscribes is eligible for alerts. The paywall (status field + Stripe webhook + active-only filter) is *introduced in M2*. Don't add a status here.
7. **DynamoDB numbers** — `target_price` stored as a Number; boto3's `resource` API wants `Decimal`, not `float`. Convert (`Decimal(str(target_price))`). See [[aws-best-practice]] Rule 3.

## Expected duration

60–90 minutes (first DynamoDB table + first AWS Lambda).

## Next step

When `m1-1-subscribe-to-a-plan-checklist` is green: 「M1.1 完成！使用者能訂閱航線了，資料進到 DynamoDB（這階段還沒有付款門檻，訂閱即可收通知）。跟我說『啟動 M1.2』，我們來讓系統定時自動抓機票價格。」Then load `m1-2-fetch-prices-on-schedule`.

## Reference

- DynamoDB CLI: https://docs.aws.amazon.com/cli/latest/reference/dynamodb/
- AWS HTTP API: https://docs.aws.amazon.com/apigatewayv2/
- Reused price client: `flightproxy/travelpayouts.py`
