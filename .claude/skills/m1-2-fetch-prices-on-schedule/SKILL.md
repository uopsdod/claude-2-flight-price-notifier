---
name: m1-2-fetch-prices-on-schedule
description: Flight Price Notifier Milestone 1.2 — build the scheduled price-check pipeline that periodically fetches the cheapest fares for the watched routes (TPE→Tokyo, TPE→Seoul) via Travelpayouts. A parser_wrapper Lambda (EventBridge, every 30 min) reads the routes from an S3 config and invokes a parser Lambda per route; the parser scans the DynamoDB subscriptions, finds whose target is met, and enqueues matches to an SQS queue (the email send is M1.3). Use when the student says "啟動 M1.2", "start M1.2", "做定時抓票", or "讓系統自動抓機票價格".
---

# M1.2 — Fetch Prices on a Schedule（讓系統定時自動抓機票，並找出該通知誰）

## What this skill does

By the end the student has the **fetch + match** half of the notifier (the email send is M1.3):

1. A **`flight-routes.json` config in S3** listing which routes to check (Tokyo, Seoul) — add a route here later with no code change.
2. A **`flight-parser-wrapper` Lambda** triggered by **EventBridge every 30 minutes**: it reads `flight-routes.json` from S3 and invokes the parser once per route.
3. A **`flight-parser` Lambda**: for one route, it calls **Travelpayouts** (an inline stdlib `fetch_cheapest`) to get the cheapest fare, **scans the DynamoDB `subscriptions`** for that route, and for every subscriber whose `target_price >= cheapest`, **enqueues a message to the fare SQS queue**.
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

> **The M1.2 deploy difference (read [[aws-best-practice]] *Cowork execution constraints* → "Method 2" first):** M1.1's Lambdas were a single ≤4096-char file, so they deployed as **inline CFN `Code.ZipFile`**. M1.2's `parser` folds into one `index.py` too, but it **runs past the 4096-char inline cap** (the inline `fetch_cheapest` + match logic), so it must deploy **from S3**. The common Cowork **AWS connector runs `aws` commands only** — it can't author files or `zip`, and `s3api put-object` can't take an inline body — so a tiny **`flight-seed` Lambda** base64-decodes the zip into S3 (Step 3), then `create-function --code S3Bucket/S3Key` deploys it. No layer needed — `fetch_cheapest` is stdlib (`urllib`); the `stripe`+`requests` layer is an M2 thing.

## Architecture

M1.2 **explodes the Flight Fare Checker box** — the parser side of the Subscriptions table M1.1 filled. EventBridge drives `Parser Wrapper`, which reads **Flight Routes [S3]** (admin-edited) and fans out one `Parser` per route; each Parser fetches the cheapest fare from **Travelpayouts** and scans **Subscriptions [DynamoDB]** to find whose target is met, enqueuing matches for M1.3.

```
                       ┌────────────────────┐
                       │   Product Site     │   ← Vercel host (writes subs in M1.1)
                       │   [Vercel host] ▲  │
                       └─────────┬──────────┘
                                 │ POST /subscribe (M1.1)
 ┌──── Flight Fare Checker ──────┼───────────────────────────────────────────┐
 │                               ▼                                            │
 │                   ┌────────────────────────┐    1. subscriber             │
 │                   │  Subscriptions         │    2. target price           │
 │                   │  [DynamoDB]            │◀───(Scan per route)──┐        │
 │                   └────────────────────────┘                     │        │
 │   ┌──────────┐     ┌────────────────┐         ┌──────────────────┴──┐     │
 │   │  Event   │────▶│  Parser        │────────▶│  Parser  (×N routes) │     │
 │   │  Bridge  │ 30m │  Wrapper  λ    │ invoke  │          λ  λ  λ      │     │
 │   └──────────┘     └───────┬────────┘  /route └─────────┬───────────┘     │
 │                            │ 1.from 2.to                ▲ from / to        │
 │              admin ✈ ──▶   ▼ (read routes)              │ fetch cheapest   │
 │                   ┌────────────────┐         ┌──────────┴───────────┐     │
 │                   │ Flight Routes  │         │ 3rd-party Parser API │     │
 │                   │ [S3]           │         │ [travelpayouts] 🐞   │     │
 │                   └────────────────┘         └──────────────────────┘     │
 │                                                                            │
 │   each match → SQS flight-fare-queue {1.from 2.to 3.subscriber            │
 │                                       4.target price 5.flight link} ─▶ M1.3│
 └────────────────────────────────────────────────────────────────────────────┘

 Legend:  ▮ orange = manual input (admin edits Flight Routes [S3])
          ▮ teal   = main component (Parser Wrapper / Parser λ)
          ▮ pink   = user data (Subscriptions [DynamoDB])
          ▮ grey   = 3rd-party (Travelpayouts) / shared Lambda + Library Layer
```

> **Deploy-time only (not in the runtime flow above):** a tiny **`flight-seed` λ** exists solely to land the routes JSON + the function zips in the S3 bucket — the Cowork `aws`-only connector can't upload objects any other way (Step 3). It plays no part once the parser is running.

**Operational sequence (what each Lambda does):**

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

This bucket does double duty: it holds **`flight-routes.json`** (the config) **and** the **Lambda zips** (`lambda/parser.zip`, `lambda/wrapper.zip`) you deploy from in Step 3. First resolve your account ID — paste to the Cowork agent:

ask """
>
Run `aws sts get-caller-identity --query Account --output text --region us-east-1` and tell me my AWS account ID. I'll use it as <ACCOUNT_ID> below.
>
"""

Then create the bucket and the fare queue. (The routes JSON and the zips get **uploaded in Step 3** through the `flight-seed` bridge — the `aws`-only connector can't author a file to `s3 cp`, and `s3api put-object` can't take an inline body, so all object uploads go through the bridge.)

ask """
>
In us-east-1 (replace <ACCOUNT_ID> with my account ID):
>
1. Create the bucket: `aws s3api create-bucket --bucket flight-config-<ACCOUNT_ID> --region us-east-1`
>
2. Create the fare queue: `aws sqs create-queue --queue-name flight-fare-queue --region us-east-1`
>
Then show me the queue URL.
>
"""

> *(CLI mode only — if you have a shell, you can seed the routes config now instead of via the bridge: `printf '%s' '[{"plan":"tokyo","origin":"TPE","destination":"TYO"},{"plan":"seoul","origin":"TPE","destination":"SEL"}]' > flight-routes.json && aws s3 cp flight-routes.json s3://flight-config-<ACCOUNT_ID>/flight-routes.json --region us-east-1`.)*

Then **extend the M1.1 IAM role** so the Lambdas can read the S3 config, send to SQS, and invoke each other. This is a real policy update — paste to the agent (it edits `flight-lambda-role`'s inline `flight-data` policy, **keeping** the M1.1 DynamoDB + Secrets statements):

ask """
>
Update the inline policy named `flight-data` on IAM role `flight-lambda-role` so it ALSO allows (keep all existing DynamoDB/Secrets statements — add these as new statements):
>
- `s3:GetObject` **and `s3:PutObject`** on `arn:aws:s3:::flight-config-<ACCOUNT_ID>/*` (GetObject: the wrapper reads the routes config; **PutObject: the `flight-seed` bridge writes the routes JSON + zips in Step 3**)
>
- `sqs:SendMessage` and `sqs:GetQueueUrl` on `arn:aws:sqs:us-east-1:<ACCOUNT_ID>:flight-fare-queue`
>
- `lambda:InvokeFunction` on `arn:aws:lambda:us-east-1:<ACCOUNT_ID>:function:flight-parser`
>
Use `aws iam put-role-policy --role-name flight-lambda-role --policy-name flight-data --policy-document '<the full merged JSON>' --region us-east-1`. Read the current policy first with `get-role-policy` so you don't drop the existing statements. Show me the final policy.
>
"""

> ⚠️ `put-role-policy` **replaces** the named policy wholesale — the agent must fetch the current `flight-data` document and **merge**, or it silently strips M1.1's DynamoDB/Secrets access and the parser breaks at runtime with `AccessDeniedException`. (`flight-seed` reuses this same role, so its `s3:PutObject` lives here too.)

**Verify before moving on:** the `flight-fare-queue` URL resolves, and the merged `flight-data` policy lists S3 (Get+Put) + SQS + InvokeFunction **alongside** the original DynamoDB + Secrets statements. (The routes JSON gets seeded + read back in Step 3.)

### Step 2 — Write the parser + parser_wrapper Lambdas

Each function is **one self-contained `index.py`** (entry function `handler` → Lambda handler `index.handler`). Everything folds inline — the fare fetch, the S3 routes read — so there's **no separate `travelpayouts.py`/`routes.py` to ship** (that file isn't in the repo; don't go looking for it). They still deploy via **S3** in Step 3, but only because `index.py` for the parser runs **past the 4096-char inline cap**, not because of file count.

**`index.py` for `flight-parser`** (one route per invocation):
1. Read `flight/travelpayouts` from Secrets Manager (cold start) → get the `token`.
2. From the event, get `{origin, destination, route}`. Compute **next month** `YYYY-MM`.
3. Call Travelpayouts and parse the cheapest fare (inline `fetch_cheapest`, below). **Empty/`429` → log + return** (skip this route this run; never crash).
4. **`Scan subscriptions`** with `FilterExpression route = :r` (boto3). **M1: no status filter** — match every subscriber. *(M2 adds `AND subscription_status = :active`.)*
5. For each subscriber where `target_price >= cheapest["price"]`: `SendMessage` to `flight-fare-queue` with `{email, route, plan_name, target_price, cheapest:{price,currency,airline,depart_date,return_date}}`. (M1.2 logs the match; M1.3's consumer dedups + sends.)

**Inline `fetch_cheapest` (stdlib only — `urllib`, no `requests`, no layer).** Hit `/v1/prices/cheap` and parse the **real response shape** — the result is `data[<DEST>][<index>]` objects whose keys are **`departure_at` / `return_at`** (ISO datetimes — **not** `depart_date`/`return_date`), plus `price` and `airline`. Parsing the wrong keys yields empty fares:
```python
import os, json, urllib.request, urllib.parse
def fetch_cheapest(origin, destination, month, token, currency="twd"):
    q = urllib.parse.urlencode({"origin": origin, "destination": destination,
        "depart_date": month, "currency": currency, "token": token})
    url = f"https://api.travelpayouts.com/v1/prices/cheap?{q}"
    with urllib.request.urlopen(url, timeout=10) as r:
        body = json.loads(r.read())
    if not body.get("success") or not body.get("data"):
        return None                                  # empty/cached → skip this route
    offers = body["data"].get(destination, {})
    if not offers:
        return None
    best = min(offers.values(), key=lambda o: o["price"])   # cheapest of the bucket
    return {"price": best["price"], "currency": currency.upper(),
            "airline": best.get("airline"),
            "depart_date": best.get("departure_at"),  # note the API's key name
            "return_date": best.get("return_at")}
```
(For M1.3's email headline you'll also want a `currency="usd"` call — same parse. Keep both inline.)

**`index.py` for `flight-parser-wrapper`** (EventBridge target) — also one self-contained file (it inlines the S3 routes read):
1. Read `flight-routes.json` from S3: `boto3.client("s3").get_object(Bucket=os.environ["CONFIG_BUCKET"], Key="flight-routes.json")` → `json.loads(...)` → `[{plan,origin,destination}, …]`.
2. For each route, `boto3.client("lambda").invoke(FunctionName="flight-parser", InvocationType="Event", Payload=json.dumps({"origin":…, "destination":…, "route":f"{origin}-{destination}"}))` (async fan-out — one slow/empty route can't block the others).

### Step 3 — Deploy both Lambdas via the `flight-seed` S3 bridge

The parser's `index.py` is over the 4096-char inline cap, so it deploys **from S3**. But the common Cowork **AWS connector runs `aws` commands only** — it can't author a file or `zip`, the build sandbox has no AWS network, and `s3api put-object` can't take an inline body. The bridge that closes this gap is a tiny **`flight-seed` Lambda** that base64-decodes bytes into S3. (Read [[aws-best-practice]] *Cowork execution constraints* → Method 2 once; **if your connector instead has a writable shell workdir**, you can skip the bridge and `zip`+`s3 cp` directly — but the bridge works either way.)

**3a — Deploy `flight-seed` once** (inline CFN — it's tiny, fits the cap). Paste to the agent:

ask """
>
Create a one-off `flight-seed` Lambda via inline CloudFormation in us-east-1 (replace <ACCOUNT_ID>). Handler `index.handler`, Runtime python3.12, Role `arn:aws:iam::<ACCOUNT_ID>:role/flight-lambda-role`, Timeout 30. The code (escape it for the template):
>
import base64, boto3
def handler(e, c):
    boto3.client("s3").put_object(Bucket=e["bucket"], Key=e["key"], Body=base64.b64decode(e["b64"]), ContentType=e.get("ct","application/octet-stream"))
    return {"ok": True, "key": e["key"]}
>
Then poll `aws cloudformation describe-stacks --stack-name flight-seed --query "Stacks[0].StackStatus" --region us-east-1` until it returns CREATE_COMPLETE (the connector can't use `cloudformation wait`).
>
"""

> The role already has `s3:PutObject` from Step 1's policy merge — that's what lets `flight-seed` write the bucket.

**3b — Seed the routes config + the two zips through the bridge.** Build each zip in the sandbox (it has `zip`), base64 it, and invoke `flight-seed` to land each object in S3. Paste to the agent:

ask """
>
Land three objects in S3 via the flight-seed bridge, in us-east-1 (replace <ACCOUNT_ID>). Each is a `lambda invoke` with a RAW JSON payload — do NOT base64 the payload itself, only the `b64` field is base64 (this connector forwards --payload verbatim):
>
1. The routes config — `b64` is base64 of the JSON `[{"plan":"tokyo","origin":"TPE","destination":"TYO"},{"plan":"seoul","origin":"TPE","destination":"SEL"}]`:
   `aws lambda invoke --function-name flight-seed --payload '{"bucket":"flight-config-<ACCOUNT_ID>","key":"flight-routes.json","b64":"<BASE64_OF_THE_JSON>","ct":"application/json"}' /tmp/aws-api-mcp/workdir/out.json --region us-east-1`
>
2. The parser zip — in the sandbox: `zip -j parser.zip index.py && base64 -w0 parser.zip`, then:
   `aws lambda invoke --function-name flight-seed --payload '{"bucket":"flight-config-<ACCOUNT_ID>","key":"lambda/parser.zip","b64":"<BASE64_OF_parser.zip>","ct":"application/zip"}' /tmp/aws-api-mcp/workdir/out.json --region us-east-1`
>
3. The wrapper zip — same, `key":"lambda/wrapper.zip"`, `b64` = base64 of `wrapper.zip`.
>
Then confirm all three landed and the zips match the local sizes: `aws s3 ls s3://flight-config-<ACCOUNT_ID>/ --recursive --region us-east-1` — the zip byte sizes must equal the local zips (a mangled base64 paste makes a same-name object that fails at deploy with InvalidZipFileException), and `flight-routes.json` is present. Also read it back: `aws s3 cp s3://flight-config-<ACCOUNT_ID>/flight-routes.json - --region us-east-1` shows the two routes.
>
"""

**3c — Create both functions from S3.** Paste to the agent:

ask """
>
Create both Lambda functions pointing Code at the seeded S3 objects, in us-east-1 (replace <ACCOUNT_ID>). Same role `arn:aws:iam::<ACCOUNT_ID>:role/flight-lambda-role`, Runtime python3.12, Handler `index.handler`, Environment `CONFIG_BUCKET=flight-config-<ACCOUNT_ID>`:
>
`aws lambda create-function --function-name flight-parser --runtime python3.12 --handler index.handler --role arn:aws:iam::<ACCOUNT_ID>:role/flight-lambda-role --timeout 30 --environment 'Variables={CONFIG_BUCKET=flight-config-<ACCOUNT_ID>}' --code S3Bucket=flight-config-<ACCOUNT_ID>,S3Key=lambda/parser.zip --region us-east-1`
>
Repeat for `flight-parser-wrapper` with `--timeout 60` and `S3Key=lambda/wrapper.zip`.
>
"""

> **Redeploy after a code edit:** re-seed the new zip (3b), then `aws lambda update-function-code --function-name flight-parser --s3-bucket flight-config-<ACCOUNT_ID> --s3-key lambda/parser.zip --region us-east-1`. **If a function got stuck `State=Failed`** from a bad zip, `update-function-code` is blocked — **delete and recreate** it. The deployed zip is the source of truth; the working copy is ephemeral in Cowork.
>
> *(CLI mode: `zip -j parser.zip aws/parser/index.py`, then `aws lambda create-function --zip-file fileb://parser.zip …` — no bridge needed.)*

**Verify before moving on** — invoke the parser for one route, then read the **effect** (logs), not the invoke output (the MCP can't read the file `invoke` writes; `invoke` also chokes on `--query`/`--cli-binary-format`):

ask """
>
Invoke the parser for one route and show me its logs:
>
`aws lambda invoke --function-name flight-parser --payload '{"origin":"TPE","destination":"TYO","route":"TPE-TYO"}' out.json --region us-east-1`
>
then read the logs with filter-log-events (the connector rejects `logs tail`):
`aws logs filter-log-events --log-group-name /aws/lambda/flight-parser --query "events[].message" --region us-east-1`
>
"""

The logs show the cheapest fare (e.g. `TPE-TYO … 9325 TWD`) and how many subscribers matched/enqueued. (No matches yet is fine — Step 4 seeds one.) If you see `Runtime.ImportModuleError`, the zip is bad (re-do 3b — check the uploaded size matches); if `AccessDeniedException`, the role merge in Step 1 dropped a statement.

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
`aws logs filter-log-events --log-group-name /aws/lambda/flight-parser --query "events[].message" --region us-east-1`
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
7. **Token plumbing** — read the `token` from the `flight/travelpayouts` secret and pass it into `fetch_cheapest`; the cheap API authenticates on the token alone.
8. **Async fan-out** — `parser_wrapper` invokes `parser` with `InvocationType="Event"` so one slow/empty route doesn't block the others.
9. **Parse the API's real keys** — `data[<DEST>][<idx>]` uses **`departure_at` / `return_at`** (not `depart_date`/`return_date`), plus `price`, `airline`. Parsing the wrong keys → silently empty fares (looks like "no deals" when the API actually returned some).
10. **Deploy is via the `flight-seed` bridge, not inline** — the parser's `index.py` exceeds the 4096-char inline cap, and the `aws`-only connector can't author files / `zip` / inline an `s3 put-object` body. So: deploy `flight-seed` once (inline), then base64→S3 the zips (Step 3). A mangled base64 → wrong object size → `InvalidZipFileException`; a function stuck `State=Failed` must be **deleted + recreated** (`update-function-code` is blocked). See [[aws-best-practice]] Method 2.
11. **`CONFIG_BUCKET` env var** — both Lambdas read `flight-routes.json` from the bucket named in `CONFIG_BUCKET`; set it at deploy (Step 3c). Missing → the parser_wrapper can't find the routes and fans out to nothing.
12. **MCP command surface** — `logs tail` and `cloudformation wait` are rejected (use `filter-log-events` / poll `describe-stacks`); `lambda invoke --payload` is **raw, not base64**; no JMESPath backtick literals. (See [[aws-best-practice]] *Cowork execution constraints* #4.)

## Expected duration

60–90 minutes (first S3 config + SQS + the two-Lambda fan-out).

## Next step

When `m1-2-fetch-prices-on-schedule-checklist` is green: 「M1.2 完成！系統每 30 分鐘自動抓兩條航線最低價，並把『達標的訂閱者』丟進 SQS 佇列。跟我說『啟動 M1.3』，我們來真的把達標通知用 email 寄出去（含去重）。」Then load `m1-3-email-on-target`.

## Reference

- Travelpayouts `/v1/prices/cheap`: https://travelpayouts.github.io/slate/ — response is `data[<DEST>][<idx>]` with keys `price`, `airline`, `departure_at`, `return_at`.
- EventBridge schedules: https://docs.aws.amazon.com/eventbridge/
- SQS: https://docs.aws.amazon.com/sqs/
- `fetch_cheapest` is written **inline** in the parser's `index.py` (stdlib `urllib`, no layer) — see Step 2.
- [[aws-best-practice]] — *Cowork execution constraints* (Method 2: the `flight-seed` base64→S3 bridge + MCP command-surface gaps), Decimal, region discipline, the IAM-policy merge gotcha.
