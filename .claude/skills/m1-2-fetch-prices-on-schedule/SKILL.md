---
name: m1-2-fetch-prices-on-schedule
description: Flight Price Notifier Milestone 1.2 — build the scheduled price-check pipeline that periodically fetches the cheapest fares for the watched routes (TPE→Tokyo, TPE→Seoul) via Travelpayouts. A parser_wrapper Lambda (EventBridge, every 30 min) reads the routes from an S3 config and invokes a parser Lambda per route; the parser scans the DynamoDB subscriptions, finds whose target is met, and enqueues matches to an SQS queue (the email send is M1.3). Use when the student says "啟動 M1.2", "start M1.2", "做定時抓票", or "讓系統自動抓機票價格".
---

# M1.2 — Fetch Prices on a Schedule（讓系統定時自動抓機票，並找出該通知誰）

## What this skill does

By the end the student has the **fetch + match** half of the notifier (the email send is M1.3):

1. A **`flight-routes.json` config in S3** listing which routes to check (Tokyo, Seoul) — add a route here later with no code change.
2. A **`flight-parser-wrapper` Lambda** triggered by **EventBridge every 30 minutes**: it reads `flight-routes.json` from S3 and invokes the parser once per route.
3. A **`flight-parser` Lambda**: for one route, it calls **Travelpayouts** (`fetch_cheapest`, reusing `flightproxy/travelpayouts.py`) to get the cheapest fare, **scans the DynamoDB `subscriptions`** for that route, and for every subscriber whose `target_price >= cheapest`, **enqueues a message to the fare SQS queue**.
4. A **`flight-fare-queue` (SQS)** that collects those matches. (M1.3 adds the consumer that dedups + emails.)

End state: the schedule fires every 30 min → each route's cheapest fare is fetched (Tokyo ≈ NT$9,531, Seoul ≈ NT$5,989 recently) → matching subscribers are enqueued. **No email yet** (M1.3) and **no payment guard** (M1 emails anyone — the `active` filter is M2).

> **Why two Lambdas + a queue (not one inline loop)?** This is the production shape from the project diagram: `parser_wrapper` (the scheduler/fan-out) and `parser` (the per-route worker) mirror the bag-notification service; the fare SQS **decouples** "finding matches" (fast) from "sending email" (the M1.3 consumer that owns dedup + retries). At 30-min cadence the queue + dedup are what stop a still-cheap fare from emailing every run.

> **M1 has NO payment guard.** The parser's subscription scan matches **every** subscriber whose target is met — it does NOT filter on `subscription_status` (that attribute doesn't even exist yet — it's introduced in M2). M2 adds `AND subscription_status = active` here.
>
> **Dates:** M1 has no user dates. The parser picks **next month** (`YYYY-MM`) for the Travelpayouts call — "cheapest ticket within budget, sometime soon." Currency `twd` (plus a `usd` call for the email headline in M1.3).

## When to load this skill

- "啟動 M1.2" / "start M1.2" / "做定時抓票" / "讓系統自動抓機票價格"

Requires M1.1 done (`m1-1-subscribe-to-a-plan-checklist` green) — reuses the same AWS role, the `flight/travelpayouts` secret, and the DynamoDB `subscriptions` table. No new external accounts.

## Execution mode: Cowork (default) vs CLI

This course runs mainly in **Cowork** — you talk to a Cowork agent with the **AWS API MCP** (it has AWS creds + network and a writable workdir), and you paste the **`ask """ … """`** blocks below to it verbatim. On the local Claude CLI instead, run the equivalent `aws`/`zip` commands directly. Every AWS command uses `--region us-east-1`; the `[default]` profile means **no `--profile` flag**.

> **The M1.2 deploy difference (read [[aws-best-practice]] *Cowork execution constraints* → "Method 2 — S3" first):** M1.1's Lambdas were a single ≤4096-char file, so they deployed as **inline CFN `Code.ZipFile`**. M1.2's `parser` is **multiple files** (`index.py` + `travelpayouts.py` + `routes.py`, and `travelpayouts.py` alone is ~7.4 KB), so inline won't fit. Instead the **AWS API MCP builds the zip in its own workdir and uploads it to S3**, then CloudFormation points the function's `Code` at that S3 object — all inside Cowork, no terminal, no `fileb://`. `travelpayouts.py` is **stdlib-only**, so M1.2 needs **no layer** (the `stripe`+`requests` layer is an M2 thing).

## Architecture

```
[EventBridge rate(30 min)] ─▶ [flight-parser-wrapper λ]
                                 · 從 S3 讀 flight-routes.json（兩條：TPE-TYO, TPE-SEL）
                                 · 每條 route → invoke [flight-parser λ]
                              [flight-parser λ]（每條 route 各一次）
                                 · travelpayouts.fetch_cheapest(origin,dest,next-month,twd)  ← 重用既有程式
                                 · Scan subscriptions WHERE route = <this route>   (M1: 全部；M2 才加 active)
                                 · 對每個 target_price >= cheapest 的訂閱者：
                                      SendMessage {email,route,fare} → [SQS flight-fare-queue]
                                                                          ▼
                                                          (M1.3：消費這個 queue → 去重 → 寄信)
```

## Conversational flow

### Step 1 — Create the routes config (S3) + the fare queue (SQS)

This bucket does double duty: it holds **`flight-routes.json`** (the config) **and** later the **Lambda zip** (`lambda/parser.zip`) you deploy from in Step 3. First resolve your account ID — paste to the Cowork agent:

ask """
>
Run `aws sts get-caller-identity --query Account --output text --region us-east-1` and tell me my AWS account ID. I'll use it as <ACCOUNT_ID> below.
>
"""

Then create the bucket, upload the routes config, and create the fare queue:

ask """
>
Using the AWS API MCP, do these in us-east-1 (replace <ACCOUNT_ID> with my account ID):
>
1. Create the bucket: `aws s3api create-bucket --bucket flight-config-<ACCOUNT_ID> --region us-east-1`
>
2. Write this exact JSON to a file in your workdir and upload it as flight-routes.json:
   [{"plan":"tokyo","origin":"TPE","destination":"TYO"},{"plan":"seoul","origin":"TPE","destination":"SEL"}]
   → `aws s3 cp <that file> s3://flight-config-<ACCOUNT_ID>/flight-routes.json --region us-east-1`
>
3. Create the fare queue: `aws sqs create-queue --queue-name flight-fare-queue --region us-east-1`
>
Then show me: the routes JSON read back from S3, and the queue URL.
>
"""

> *(CLI mode: `printf '%s' '[…]' > flight-routes.json` then `aws s3 cp flight-routes.json s3://… --region us-east-1`, and `aws sqs create-queue …`.)*

Then **extend the M1.1 IAM role** so the Lambdas can read the S3 config, send to SQS, and invoke each other. This is a real policy update — paste to the agent (it edits `flight-lambda-role`'s inline `flight-data` policy, **keeping** the M1.1 DynamoDB + Secrets statements):

ask """
>
Update the inline policy named `flight-data` on IAM role `flight-lambda-role` so it ALSO allows (keep all existing DynamoDB/Secrets statements — add these as new statements):
>
- `s3:GetObject` on `arn:aws:s3:::flight-config-<ACCOUNT_ID>/*`
>
- `sqs:SendMessage` and `sqs:GetQueueUrl` on `arn:aws:sqs:us-east-1:<ACCOUNT_ID>:flight-fare-queue`
>
- `lambda:InvokeFunction` on `arn:aws:lambda:us-east-1:<ACCOUNT_ID>:function:flight-parser`
>
Use `aws iam put-role-policy --role-name flight-lambda-role --policy-name flight-data --policy-document '<the full merged JSON>' --region us-east-1`. Read the current policy first with `get-role-policy` so you don't drop the existing statements. Show me the final policy.
>
"""

> ⚠️ `put-role-policy` **replaces** the named policy wholesale — the agent must fetch the current `flight-data` document and **merge**, or it silently strips M1.1's DynamoDB/Secrets access and the parser breaks at runtime with `AccessDeniedException`.

**Verify before moving on:** the routes JSON read back from S3 shows the two routes, the `flight-fare-queue` URL resolves, and the merged `flight-data` policy lists S3 + SQS + InvokeFunction **alongside** the original DynamoDB + Secrets statements.

### Step 2 — Write the parser + parser_wrapper Lambdas

**`aws/parser/handler.py`** (one route per invocation):
1. Read `flight/travelpayouts` from Secrets Manager (cold start) → set `os.environ["TRAVELPAYOUTS_TOKEN"]`.
2. From the event, get `{origin, destination, route}`. Compute **next month** `YYYY-MM`.
3. `cheapest = travelpayouts.fetch_cheapest(origin, destination, next_month, currency="twd")`. **Empty/`429` → log + return** (skip this route this run; never crash).
4. **`Scan subscriptions`** with `FilterExpression route = :r` (boto3). **M1: no status filter** — match every subscriber. *(M2 adds `AND subscription_status = :active`.)*
5. For each subscriber where `target_price >= cheapest.price`: `SendMessage` to `flight-fare-queue` with `{email, route, plan_name, target_price, cheapest:{price,currency,airline,depart_date,return_date}}`. (M1.2 logs the match; M1.3's consumer dedups + sends.)

The parser is **three files** — `index.py` (this handler, named `handler` → so the Lambda handler is `index.handler`), the reused **`travelpayouts.py`**, and **`routes.py`** (the S3 reader, below). That's why it deploys via **S3**, not inline (Step 3).

**`routes.py`** — the tiny S3-config reader both Lambdas use (≈10 lines):
```python
import json, os, boto3
def load_routes():
    bucket = os.environ["CONFIG_BUCKET"]          # flight-config-<ACCOUNT_ID>
    obj = boto3.client("s3").get_object(Bucket=bucket, Key="flight-routes.json")
    return json.loads(obj["Body"].read())          # [{plan,origin,destination}, …]
```

**`index.py` for `parser_wrapper`** (EventBridge target) — note this one is also multi-file (`index.py` + `routes.py`), so it deploys via S3 too:
1. `routes = routes.load_routes()` (reads `flight-routes.json` from S3).
2. For each route, `boto3.client("lambda").invoke(FunctionName="flight-parser", InvocationType="Event", Payload=json.dumps({"origin":…, "destination":…, "route":f"{origin}-{destination}"}))` (async fan-out — one slow/empty route can't block the others).

### Step 3 — Deploy both Lambdas via S3 (Cowork-native, no terminal)

Inline `Code.ZipFile` can't carry these multi-file functions, so the **MCP builds each zip in its own workdir and uploads to the S3 bucket from Step 1**, then CloudFormation points the function `Code` at the S3 object (see [[aws-best-practice]] *Cowork execution constraints* → Method 2). Paste to the Cowork agent:

ask """
>
Deploy two Lambda functions from S3, in us-east-1 (replace <ACCOUNT_ID>). Do it all inside your own workdir — you have AWS network there, so the s3 cp works:
>
1. Write these files into your workdir:
   · `index.py` = the parser handler we just wrote (entry function named `handler`)
   · `travelpayouts.py` = copied verbatim from the repo's `flightproxy/travelpayouts.py`
   · `routes.py` = the S3 reader above
>
2. Zip them flat (no parent folder): `zip parser.zip index.py travelpayouts.py routes.py`
>
3. Upload: `aws s3 cp parser.zip s3://flight-config-<ACCOUNT_ID>/lambda/parser.zip --region us-east-1`
>
4. Create the function via CloudFormation pointing Code at S3 (Handler `index.handler`, Runtime python3.12, Role `arn:aws:iam::<ACCOUNT_ID>:role/flight-lambda-role`, Timeout 30, Environment `CONFIG_BUCKET=flight-config-<ACCOUNT_ID>`):
   `aws cloudformation create-stack --stack-name flight-parser --capabilities CAPABILITY_IAM --region us-east-1 --template-body '{"Resources":{"Fn":{"Type":"AWS::Lambda::Function","Properties":{"FunctionName":"flight-parser","Runtime":"python3.12","Handler":"index.handler","Role":"arn:aws:iam::<ACCOUNT_ID>:role/flight-lambda-role","Timeout":30,"Environment":{"Variables":{"CONFIG_BUCKET":"flight-config-<ACCOUNT_ID>"}},"Code":{"S3Bucket":"flight-config-<ACCOUNT_ID>","S3Key":"lambda/parser.zip"}}}}}'`
>
5. Repeat for the wrapper: zip `index.py`(wrapper) + `routes.py` → `wrapper.zip` → `s3 cp … lambda/wrapper.zip` → `create-stack flight-parser-wrapper` (same role/runtime, `CONFIG_BUCKET` env, Timeout 60).
>
Tell me when both stacks reach CREATE_COMPLETE.
>
"""

> **Redeploy after a code edit:** re-`s3 cp` the new zip, then `aws lambda update-function-code --function-name flight-parser --s3-bucket flight-config-<ACCOUNT_ID> --s3-key lambda/parser.zip --region us-east-1`. The **deployed zip is the source of truth** — the working copy is ephemeral in Cowork.
>
> *(CLI mode: `cp flightproxy/travelpayouts.py aws/parser/`, `zip -j parser.zip aws/parser/*.py`, then `aws lambda create-function --zip-file fileb://parser.zip …` — or `scripts/04_deploy_lambdas.sh`.)*

**Verify before moving on** — invoke the parser for one route, then read the **effect** (logs), not the invoke output (in Cowork the MCP can't read the file `invoke` writes, and `invoke` chokes on `--query`/`--cli-binary-format`):

ask """
>
Invoke the parser for one route and show me its logs:
>
`aws lambda invoke --function-name flight-parser --payload '{"origin":"TPE","destination":"TYO","route":"TPE-TYO"}' out.json --region us-east-1`
>
then `aws logs tail /aws/lambda/flight-parser --since 5m --region us-east-1`
>
"""

The logs show the cheapest fare (e.g. `TPE-TYO … 9531 TWD`) and how many subscribers matched/enqueued. (No matches yet is fine — Step 4 seeds one.) If you see `Runtime.ImportModuleError`, a file didn't make it into the zip (re-check Step 3 step 2); if `AccessDeniedException`, the role merge in Step 1 dropped a statement.

### Step 4 — Seed a test subscriber so the match path runs

For the demo, make sure at least one subscription's target is **above** the live fare so it matches. Paste to the agent:

ask """
>
Bump a test subscriber's target above the live fare so the match path fires, then re-invoke the parser:
>
`aws dynamodb update-item --table-name subscriptions --key '{"email":{"S":"test@example.com"},"route":{"S":"TPE-TYO"}}' --update-expression 'SET target_price = :t' --expression-attribute-values '{":t":{"N":"12000"}}' --region us-east-1`
>
(No `subscription_status` to set — M1 has no guard.) Then invoke `flight-parser` again for TPE-TYO and show me the fare-queue depth:
>
`aws sqs get-queue-attributes --queue-url <fare-queue-url> --attribute-names ApproximateNumberOfMessages --region us-east-1`
>
"""

**Verify before moving on:** `ApproximateNumberOfMessages` ≥ 1 after the re-invoke — the matched subscriber was enqueued. (Get `<fare-queue-url>` from Step 1's `get-queue-url`.)

### Step 5 — Wire EventBridge → parser_wrapper (every 30 min, configurable)

The schedule rate is `rate(30 minutes)` (in CLI mode it lives in `scripts/env.sh` as `SCHEDULE_RATE`). Paste to the Cowork agent:

ask """
>
Wire EventBridge to run the wrapper every 30 minutes, in us-east-1 (replace <ACCOUNT_ID>):
>
1. `aws events put-rule --name flight-price-check --schedule-expression "rate(30 minutes)" --region us-east-1`
>
2. `aws lambda add-permission --function-name flight-parser-wrapper --statement-id eventbridge --action lambda:InvokeFunction --principal events.amazonaws.com --source-arn arn:aws:events:us-east-1:<ACCOUNT_ID>:rule/flight-price-check --region us-east-1`
>
3. `aws events put-targets --rule flight-price-check --targets 'Id=1,Arn=arn:aws:lambda:us-east-1:<ACCOUNT_ID>:function:flight-parser-wrapper' --region us-east-1`
>
Then invoke the wrapper once manually so I don't have to wait for the schedule, and show me both routes' parser logs:
>
`aws lambda invoke --function-name flight-parser-wrapper --payload '{}' out.json --region us-east-1`
>
`aws logs tail /aws/lambda/flight-parser --since 5m --region us-east-1`
>
"""

**Change the frequency live** without redeploying: `aws events put-rule --name flight-price-check --schedule-expression 'rate(...)'`. **Demo tip:** temporarily `rate(2 minutes)` to watch it fire, then revert.

**Verify before moving on:** after the manual wrapper invoke (or once the rule fires), the parser logs show **both** routes (TPE-TYO and TPE-SEL) ran, and the fare queue depth went up for the seeded match.

## Things to watch out for

1. **No payment guard in M1** — the parser scan matches **every** subscriber whose target is met; do NOT filter on `subscription_status` (it doesn't exist yet). M2 adds the `active` filter here.
2. **Travelpayouts cache/empty/`429`** — `/v1/prices/cheap` is cached; some months return empty or rate-limit. Skip that route this run, don't crash the parser.
3. **One call per route, not per subscriber** — fetch the cheapest **once** per route, then compare against all that route's subscribers. (2 routes = 2 calls/run, far under 200/hr.)
4. **Next month, currency=twd** — the parser computes next month `YYYY-MM` (M1 has no user dates) and fetches in TWD.
5. **Enqueue, don't email** — M1.2 stops at `SendMessage`. The fare-queue consumer (dedup + Resend) is M1.3. Keeping them separate is the whole point of the SQS decoupling.
6. **Region/account in ARNs** — all `us-east-1` / `<ACCOUNT_ID>`. A wrong-region ARN silently never matches (see [[aws-best-practice]] Rule 1).
7. **Token plumbing** — set `os.environ["TRAVELPAYOUTS_TOKEN"]` from the secret before calling `travelpayouts`, or pass `token=`.
8. **Async fan-out** — `parser_wrapper` invokes `parser` with `InvocationType="Event"` so one slow/empty route doesn't block the others.
9. **Multi-file = S3 deploy, not inline** — the parser is 3 files (`index.py`+`travelpayouts.py`+`routes.py`), so it **cannot** use M1.1's inline `Code.ZipFile`. The MCP zips in its workdir → `s3 cp` → CFN `Code.S3Bucket/S3Key` (see [[aws-best-practice]] Method 2). A missing file in the zip → `Runtime.ImportModuleError`; zip **flat** (`zip -j` / no parent dir) so imports resolve.
10. **`CONFIG_BUCKET` env var** — both Lambdas read `flight-routes.json` from the bucket named in `CONFIG_BUCKET`; set it at deploy (Step 3). Missing → the parser_wrapper can't find the routes and fans out to nothing.

## Expected duration

60–90 minutes (first S3 config + SQS + the two-Lambda fan-out).

## Next step

When `m1-2-fetch-prices-on-schedule-checklist` is green: 「M1.2 完成！系統每 30 分鐘自動抓兩條航線最低價，並把『達標的訂閱者』丟進 SQS 佇列。跟我說『啟動 M1.3』，我們來真的把達標通知用 email 寄出去（含去重）。」Then load `m1-3-email-on-target`.

## Reference

- Travelpayouts `/v1/prices/cheap`: https://travelpayouts.github.io/slate/
- EventBridge schedules: https://docs.aws.amazon.com/eventbridge/
- SQS: https://docs.aws.amazon.com/sqs/
- Reused client: `flightproxy/travelpayouts.py` (`fetch_cheapest`), copied into the parser zip
- [[aws-best-practice]] — *Cowork execution constraints* (Method 2: S3 deploy for multi-file Lambdas), Decimal, region discipline, the IAM-policy merge gotcha.
