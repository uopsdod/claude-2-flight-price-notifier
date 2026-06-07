---
name: aws-best-practice
description: Hard rules and operational SOP for the AWS side of the Flight Price Notifier course — a SERVERLESS stack (Lambda + DynamoDB + SQS + S3 + API Gateway + EventBridge + Secrets Manager). Use whenever a student is packaging a Lambda, writing to DynamoDB, wiring SQS, handling the Stripe webhook, managing secrets, or debugging an AWS-side failure in M1+. Sourced from this stack's real failure modes.
---

# AWS Best Practice (Flight Price Notifier — serverless)

This course's AWS side is **100% serverless** — there is **no EC2, no SSH, no SSM, no systemd**. The pieces are: **6 Lambdas**, **2 DynamoDB tables** (`subscriptions`, `notification_history`), **2 SQS queues**, an **S3** routes config, **API Gateway (HTTP API v2)**, **EventBridge**, and **Secrets Manager**. AWS access is the **`[default]` profile** (IAM user `admin-for-cowork` with `AdministratorAccess`), read by the **AWS API MCP** in Cowork; every command pins **`--region us-east-1`**.

When guiding a student through AWS operations, **apply these rules proactively** — stop them before they break one. Each rule maps to a real failure mode of *this* stack.

> Adapted from a Course 2 AWS skill that was EC2/SSM-based. Those rules (SSH-vs-SSM, systemd PATH, instance tagging) **do not apply** — this stack has no servers to log into. Only the secrets-hygiene and IAM-user rules carried over; the rest below are serverless-native.

---

## Execution mode: Cowork vs CLI

The hard rules apply identically in both — only the command surface differs.

| Operation | CLI mode | Cowork mode |
|---|---|---|
| Run any AWS API call | `aws <service> <verb> ... --region us-east-1` | `call_aws <service> <verb> ...` via AWS API MCP (set region/creds in the connector) |
| Deploy a 1-file Lambda | `aws lambda create-function --zip-file fileb://fn.zip ...` | inline CFN `Code.ZipFile` (Method 1 below) — no file transfer |
| Deploy a >4096-char / layered Lambda | `zip` the dir → `--zip-file fileb://fn.zip` | S3 via the `flight-seed` base64 bridge → `Code.S3Bucket/S3Key` (Method 2 below) |
| Read a Lambda's logs | `aws logs tail /aws/lambda/<fn> --since 10m --follow` | `aws logs filter-log-events --log-group-name /aws/lambda/<fn> --query "events[].message"` (the MCP rejects `logs tail`) |
| Inspect a DynamoDB row | `aws dynamodb get-item --table-name subscriptions --key '{...}'` | `call_aws dynamodb get-item ...` |

**Profile/region:** the course uses the **`[default]`** AWS profile (no `--profile` flag needed). It has **no default region**, so **every** call passes `--region us-east-1`. In Cowork the AWS API MCP reads `~/.aws/credentials`'s `[default]` block (written via a Claude CLI session — see [[m1-1-subscribe-to-a-plan-prerequisites]]). Forgetting the region is the #1 "it works for me but not in the script" gap.

---

## Cowork execution constraints (read before you deploy)

In Cowork there are **two separate hosts**, and the gap between them — **not** an auth gap — is what bites:

- **The AWS API MCP** *does* have AWS access: it authenticates from `~/.aws/credentials` (the `[default]` profile written in prereqs) and runs `aws` calls. **Creds and network are fine.** But — verified on a real M1.2 run — the common connector is **`aws`-CLI-only: it executes `aws` API commands and nothing else.** It has **no shell**, so it **cannot author files, run `zip`, or `cat` an output** in any workdir. (Some connector builds *do* expose a writable workdir; **don't assume it** — see the capability fork below.)
- **The bash/build sandbox** is a *different* host. It can build a zip, but has **no AWS creds and no network route to AWS** (DNS to `*.amazonaws.com` is blackholed; s3/sts/lambda return **HTTP 000**), and **no shared path to the connector** — so it can't hand the built zip to the MCP, and can't upload to S3 itself.

So you **cannot** get a built zip to S3 by any direct path: the sandbox has the file but no network; the MCP has the network but can't author the file. The bridge that closes this gap is a tiny **`flight-seed` Lambda** (Method 2 below). Other gotchas from real runs:

1. **The zip-transfer gap (above):** no direct file→S3 path. → single small files deploy **inline** (Method 1); anything bigger goes through the **`flight-seed` base64→S3 bridge** (Method 2).
2. **The build sandbox has no AWS network:** `curl`/uploads to AWS from it return **HTTP 000**; the web-fetch tool is **GET-only**.
3. **You can't read MCP-written files.** `aws lambda invoke … out.json` writes the response body where you **can't `cat` it back**. **Verify the effect instead** — `get-item` (DynamoDB), a queue depth, or `logs filter-log-events`.
4. **The MCP's command surface ≠ the full CLI.** It runs core AWS **API operations**, not the CLI's convenience wrappers or client-side binary handling. Verified rejections/quirks (every milestone inherits these):
   - `aws logs tail` → **rejected** ("operation 'tail' does not exist"). Use **`aws logs filter-log-events --log-group-name … --query "events[].message"`** (optional `--start-time <epoch_ms>`).
   - `aws cloudformation wait …` → **rejected** ("operation 'wait' is not allowed"). **Poll** `describe-stacks --query "Stacks[0].StackStatus"` until `CREATE_COMPLETE` (sleep between calls).
   - `aws lambda invoke` → **rejects `--query` and `--cli-binary-format`.** And **`--payload` is forwarded RAW, not base64** — send plain JSON (`'{"k":"v"}'`); base64-encoding it fails with `InvalidRequestContentException`.
   - **JMESPath backtick literals fail to parse** anywhere (`SecretList[?starts_with(Name,\`flight/\`)]` → "Unknown token"). Use plain projections: `--query "SecretList[].Name"`.
   - **`s3api put-object` Body can't be inlined.** `--cli-input-json '{"Body":"…"}'` is a streaming blob the CLI **silently drops → a 0-byte object**, and there's **no `--body <file>`** to point at without a shell. This is *why* the `flight-seed` bridge exists, not a clever one-liner.
5. **Git on the mounted folder fails.** `git clone`/ops in the mounted workspace folder error (`config.lock: Operation not permitted` — FUSE can't do git's locking). **Clone into a native dir** (the agent's home); treat the working copy as **ephemeral** — GitHub + Vercel are the source of truth.

**→ The Cowork way to deploy Lambda code (two methods):**

**Method 1 — inline `Code.ZipFile` (single small file).** Send the code *inside* the API call — **CloudFormation with inline `Code.ZipFile`**: `aws cloudformation create-stack --template-body '<json>'`, function code inline, no file transfer. **Limits: single file, ≤4096 chars, handler `index.handler`.** This is how M1.1's one-file Lambdas (`save_subscription`, `list_subscriptions`) deploy — they use only boto3 (already in the runtime), so no extra files.

**Method 2 — S3 `Code.S3Bucket/S3Key` via the `flight-seed` bridge (>4096 chars or a layer zip).** When a function's code **exceeds the inline 4096-char cap**, or you need to land a **layer zip** (M2's `stripe`+`requests`) or any other bytes in S3, inline won't fit and `s3api put-object` can't take an inline body (see constraint #4). **First check your connector** (capability fork):

- **`aws`-only connector (the common case):** use the **`flight-seed` bridge** below — it's the only path that works.
- **Connector with a writable shell workdir (rare):** you *may* instead author the files there, `zip`, and `aws s3 cp` directly — but if you're unsure, use the bridge; it works in both.

**The `flight-seed` base64→S3 bridge** (canonical for `aws`-only connectors):

1. **Deploy a tiny `flight-seed` Lambda once**, via inline CFN `Code.ZipFile` (it fits — it's ~6 lines):
   ```python
   import base64, boto3
   def handler(e, c):
       boto3.client("s3").put_object(
           Bucket=e["bucket"], Key=e["key"],
           Body=base64.b64decode(e["b64"]),
           ContentType=e.get("ct", "application/octet-stream"))
       return {"ok": True, "key": e["key"]}
   ```
   Its role needs **`s3:PutObject`** on the target bucket (add it to `flight-lambda-role`, or give `flight-seed` its own role).
2. **Build each zip in the sandbox** (it has `zip`), then `base64 -w0` it to a single line.
3. **Materialize each object in S3** by invoking the bridge with **raw JSON** (the MCP forwards `--payload` verbatim — do **not** base64 the payload itself):
   ```bash
   aws lambda invoke --function-name flight-seed \
     --payload '{"bucket":"flight-config-<ACCOUNT_ID>","key":"lambda/parser.zip","b64":"<BASE64_OF_ZIP>","ct":"application/zip"}' \
     /tmp/aws-api-mcp/workdir/out.json --region us-east-1
   ```
   (Use the same bridge to write `flight-routes.json`, layer zips — any bytes.)
4. **Deploy the function from S3:** `aws lambda create-function --code S3Bucket=flight-config-<ACCOUNT_ID>,S3Key=lambda/parser.zip …` (or CFN `Code:{S3Bucket,S3Key}`). Redeploy after an edit = re-seed the new zip, then `aws lambda update-function-code --s3-bucket … --s3-key …`.

> **Always verify the uploaded object size == the local zip size** — a mangled base64 paste yields a same-name object that fails at deploy with `InvalidZipFileException`. And a function whose create **failed** on a bad zip is stuck `State=Failed` — `update-function-code` is blocked; you must **delete and recreate** it.

This is the standard way to land bytes in S3 from an `aws`-only connector — for both **>4096-char function zips** and the **M2 `stripe`+`requests` layer** (`publish-layer-version --content S3Bucket=…,S3Key=…` after seeding `layer.zip`). Note most M1.x functions actually **fold into a single `index.py`** that only uses boto3/stdlib — they need **no layer**; the reason to use S3 is the size cap (and the checklist's S3-artifact check), not file count.

---

## Hard rules

### Rule 1 — Pin `--region us-east-1` on every command (the `[default]` profile has no region)

> **The rule:** No bare `aws ...` without a region. Always `--region us-east-1`. All ARNs hardcode `us-east-1` and the account ID. (No `--profile` flag — the course uses `[default]`.)

**Why:** The `[default]` profile has no region configured, so a call without `--region` either errors (`You must specify a region`) or, worse, silently hits a *different* default region where none of your resources exist — and you get `ResourceNotFoundException` for a table that demonstrably exists (in us-east-1). The same drift bites ARNs: an EventBridge rule ARN or SQS ARN with the wrong region/account silently never matches. Pin both, everywhere.

**How to apply:** In `scripts/env.sh`: `REGION=us-east-1; ACCOUNT=<your account id>` and reference `--region "$REGION"` in every script (resolve `ACCOUNT` once via `aws sts get-caller-identity --query Account --output text`). When a call returns "not found" for something you just created, **check the region first** before assuming it wasn't created.

---

### Rule 2 — Store every credential in Secrets Manager; the browser/Vercel holds NO AWS keys

> **The rule:** `flight/travelpayouts`, `flight/resend`, `flight/stripe` (M2), `flight/telegram` + `flight/anthropic` (M4) live in **Secrets Manager**. Lambdas read them at runtime via `boto3.client("secretsmanager").get_secret_value`. **No keys in code, in env files committed to git, or in the front-end.** The browser only POSTs to API Gateway; only Lambdas touch AWS.

**Why:** Every other home for a key has a leak story — committed `.env` is indexed by GitHub's secret scanner instantly; a key in client JS is visible in every visitor's network tab. Secrets Manager is KMS-encrypted, IAM-scoped, and `GetSecretValue` is CloudTrail-logged with caller + timestamp. And crucially: **DynamoDB/SQS/S3 need NO secret at all** — the Lambda's IAM role authorizes them. The only things in Secrets Manager are *third-party* keys (Travelpayouts/Resend/Stripe/etc.).

**How to apply:**
- `aws secretsmanager create-secret --name flight/travelpayouts --secret-string '{"token":"…"}' --region us-east-1` (token only — the notifier authenticates on the token alone; the optional `marker` affiliate ID is a skippable M1.3 add-on for booking-link commission, not required)
- Scope the role's `secretsmanager:GetSecretValue` to `arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:flight/*` — **never** `Resource: "*"`.
- **Chat-retention caveat:** a key briefly appears in the chat transcript on its way to `create-secret`. Fine for course-grade keys (cap spend, rotate at course end). For real production, type values in the console.
- M3 go-live check greps the deployed front-end for `AKIA…` / `service_role` / any secret → must be absent.

---

### Rule 3 — DynamoDB numbers are `Decimal`, not `float` — convert on the way in AND out

> **The rule:** When writing `target_price` / `price` to DynamoDB, pass a `Decimal`, not a Python `float`. When reading them back for arithmetic or JSON, convert `Decimal` → `int`/`float`/`str` explicitly.

**Why:** boto3's DynamoDB resource **rejects `float`** with `TypeError: Float types are not supported. Use Decimal types instead` — so a handler that does `{"target_price": 12000.0}` crashes on the very first `put_item`. Coming back the other way, a `Decimal` is **not JSON-serializable**, so `json.dumps(item)` throws `TypeError: Object of type Decimal is not JSON serializable` when the Lambda tries to return the row or log it. Both are first-hour M1.1 failures.

**How to apply:**
- Write: `from decimal import Decimal; item["target_price"] = Decimal(str(target_price))` (via `str` to avoid binary-float artifacts like `12000.00000001`).
- Read/return: convert before `json.dumps` — `int(item["target_price"])` for whole TWD, or a small `default=` encoder that maps `Decimal→int/float`.
- Keep this in `aws/common/ddb.py` so every handler shares one correct conversion.

---

### Rule 4 — The Stripe webhook must verify the signature on the RAW body — decode `isBase64Encoded` first (M2)

> **The rule:** In `subscription_webhook`, read the **raw** request body exactly as bytes before calling `stripe.Webhook.construct_event`. API Gateway HTTP API v2 may deliver the body **base64-encoded** (`event["isBase64Encoded"] == True`) — decode it first. Never `json.loads` then re-serialize before verifying.

**Why:** Stripe signs the exact bytes it sent. Any re-encoding — base64 left undecoded, or a JSON round-trip that reorders keys / changes whitespace — changes the bytes, so the computed signature won't match and **every webhook 400s** with `SignatureVerificationError`. This is the single highest-risk file in the whole course; a wrong body handling here means payments "succeed" in Stripe but never activate the subscription.

**How to apply:**
```python
raw = event["body"]
if event.get("isBase64Encoded"):
    raw = base64.b64decode(raw)            # bytes
elif isinstance(raw, str):
    raw = raw.encode("utf-8")
stripe.Webhook.construct_event(raw, headers["stripe-signature"], signing_secret)
```
Test with `stripe listen --forward-to <api>/stripe-webhook` + `stripe trigger checkout.session.completed`; a `400` almost always = body handling, not the secret.

---

### Rule 5 — SQS visibility timeout ≥ the consumer Lambda's timeout, and the consumer must be idempotent

> **The rule:** Each queue's `VisibilityTimeout` must be **≥** the timeout of the Lambda that consumes it (fare-queue → `fare_notification`, status-queue → `status_notification`). And the consumers must tolerate a message being delivered more than once.

**Why:** If the visibility timeout is shorter than the Lambda runtime, SQS makes the message visible again **while the Lambda is still processing it**, a second invocation picks it up, and the user gets a **duplicate email**. SQS is at-least-once by design, so even with correct timeouts a retry can re-deliver. The defense is the `notification_history` dedup (24h floor + re-alert thresholds) — which is exactly why dedup lives in the consumer, not the parser.

**How to apply:**
- Set `VisibilityTimeout` to ≥ (Lambda timeout) when creating the queue; a common safe value is 6× the function timeout.
- `fare_notification` checks `notification_history` **before** sending and writes a history row **after** — so a re-delivered message finds the recent row and skips.
- Add an event-source mapping (`aws lambda create-event-source-mapping`) rather than polling; let Lambda manage receive/delete.

---

### Rule 6 — Don't bundle boto3; DO bundle the stdlib helpers. Build the layer pure-Python.

> **The rule:** The Lambda runtime already includes **boto3** — never add it to the zip or layer. The shared layer `flight-deps` is **`stripe` + `requests`** only (both pure-Python). Stdlib-only project files (`travelpayouts.py`, `email_render.py`) are **copied into the function zip** at build, not layered.

**Why:** Bundling boto3 bloats the zip and can shadow the runtime's version with a subtly different one → confusing `botocore` errors. Putting a **C-extension** library in a Mac-built zip/layer fails at runtime on Lambda's Linux (`invalid ELF header` / `cannot import name ...`); `stripe`/`requests` are pure-Python so a Mac-built zip works. `travelpayouts.py` and `email_render.py` are stdlib-only by design, so a plain `cp` into the function dir is all that's needed.

**How to apply (CLI mode):**
- `03_build_layer.sh`: `pip install stripe requests -t python/` → zip → `publish-layer-version`. Nothing else.
- `04_deploy_lambdas.sh`: `cp flightproxy/travelpayouts.py aws/parser/` and `cp flightproxy/email_render.py aws/fare_notification/` before zipping each function.
- If you ever need a C-extension dep later, build it with `--platform manylinux2014_x86_64` (or Docker), not on the Mac directly.

**In Cowork** the build-sandbox can't hand a zip to the MCP (see *Cowork execution constraints* above), so:
- **Small single-file Lambdas** (M1.1's `save_subscription`, `list_subscriptions`; M1.2's `flight-seed`) deploy as **inline CFN `Code.ZipFile`** with **no layer** (they only use boto3/stdlib, in the runtime). M1.2's `parser`/`wrapper` also **fold into one `index.py` each** (inline `fetch_cheapest` + routes-read) — they need no layer either.
- **Over the 4096-char inline cap** (a big handler, or any layer zip) → land the zip in S3 via the **`flight-seed` base64 bridge** (Method 2 above), then deploy `Code:{S3Bucket,S3Key}`. The reason here is the **size cap** (and the checklist's S3-artifact check), not file count.
- **The `stripe`+`requests` layer** is an **M2** need, not M1.2. Seed `layer.zip` to S3 the same way, then `publish-layer-version --content S3Bucket=…,S3Key=…`.

---

### Rule 7 — Lambdas are NOT in a VPC — keep it that way

> **The rule:** Create every Lambda with **no VPC config**. They reach the public internet (Travelpayouts, Stripe, Resend) and AWS service endpoints directly.

**Why:** Putting a Lambda in a VPC removes its default internet route — outbound calls to `api.resend.com` / `api.stripe.com` / Travelpayouts hang and time out unless you also add a NAT gateway (extra cost + setup) or VPC endpoints for every service. For this course there's no reason to be in a VPC; staying out keeps outbound HTTPS working with zero config. (DynamoDB/SQS/S3 are reached over their public endpoints via the SDK, authorized by IAM — no VPC needed.)

**How to apply:** Don't pass `--vpc-config` to `create-function`. If a student copied a VPC config from elsewhere and Resend calls start timing out, the VPC is the first suspect.

---

### Rule 8 — Use a dedicated IAM user/role; never root keys; one shared `flight-lambda-role`

> **The rule:** AWS access for the CLI/MCP uses a named IAM user (**`admin-for-cowork`**, `AdministratorAccess`) whose access key is written to the `[default]` profile — **never AWS root keys** (root is only used once, to *create* that IAM user). All Lambdas assume one **`flight-lambda-role`** scoped to exactly this project's resources.

**Why:** Root keys can't be scoped, audited per-key, or cleanly rotated — a leak means rotating everything. A named IAM user is auditable and deletable. For the Lambdas, one shared role is fine at course scale; its inline policy is scoped to the two table ARNs, the two queue ARNs, the `flight/*` secrets, the S3 routes prefix, and `lambda:InvokeFunction` on `flight-parser` — **not** `Resource: "*"`.

**How to apply:**
- If an `AKIA…` key is ever pasted into chat / a commit / a screenshot → delete it immediately and issue a new one; anyone who sees it has full access until revoked.
- Keep the role's policy in `scripts/iam-policy.json` (version-controlled), so it's reproducible.
- For a course, scoping to specific resource ARNs (not full admin on the role) is the teaching-grade floor; production would split per-Lambda least-privilege.

---

## How to debug a serverless failure (there's no server to log into)

Everything surfaces in **CloudWatch Logs**, one group per function:

```bash
# CLI mode:
aws logs tail /aws/lambda/flight-parser --since 15m --follow --region us-east-1
aws logs tail /aws/lambda/flight-fare-notification --since 15m --region us-east-1
# Cowork (the MCP rejects `logs tail`) — use filter-log-events:
aws logs filter-log-events --log-group-name /aws/lambda/flight-parser \
  --query "events[].message" --region us-east-1
```

Trace the path by following the data, not a process:
1. **Did the schedule fire?** `flight-parser-wrapper` logs (EventBridge target).
2. **Did the parser find subscribers + a cheap fare?** `flight-parser` logs (the `Scan` + `fetch_cheapest`).
3. **Did a message land on the queue?** `aws sqs get-queue-attributes --attribute-names ApproximateNumberOfMessages …`.
4. **Did the sender send / dedup?** `flight-fare-notification` logs (Resend response + "skipped (deduped)").

A silent "no email" is almost always: empty Travelpayouts result (skip), the dedup floor (working as intended), or a `Decimal`/region error in the logs of one of the four steps.

---

## Things to actively watch out for

1. **`Float types are not supported`** on `put_item` → Rule 3 (use `Decimal(str(x))`).
2. **`Object of type Decimal is not JSON serializable`** when returning a row → Rule 3 (convert before `json.dumps`).
3. **Stripe webhook `400` / `SignatureVerificationError`** → Rule 4 (raw body + `isBase64Encoded`), not the signing secret.
4. **Resend/Stripe calls time out from inside a Lambda** → Rule 7 (the function is in a VPC; take it out).
5. **`ResourceNotFoundException` for a resource you just created** → Rule 1 (wrong region; you're hitting a default that isn't us-east-1).
6. **Duplicate alert emails** → SQS visibility timeout too short (Rule 5) and/or the consumer skipped the `notification_history` check.
7. **`AccessDeniedException` on DynamoDB/SQS/S3** → the `flight-lambda-role` inline policy is missing that ARN; re-apply `scripts/iam-policy.json`.
8. **`Runtime.ImportModuleError` after deploy** → a C-extension snuck into the Mac-built layer (Rule 6), or `travelpayouts.py`/`email_render.py` wasn't copied into the zip.
9. **CORS error in the browser console on subscribe** → set CORS on the HTTP API (`AllowOrigins`, `AllowMethods=POST,OPTIONS`, `AllowHeaders=content-type`).
10. **Travelpayouts `429`/empty** → treat as "skip this route this run," never crash the loop.

---

## Out of scope for this course (real prod, not enforced here)

- Per-Lambda least-privilege roles (course uses one shared, resource-scoped role).
- DLQs on the SQS queues + alarm on queue depth.
- Multi-stage beta/prod aliases + canary deploys.
- Customer-managed KMS keys + rotation policies.
- GSIs on the DynamoDB tables (course `Scan`s at tens-of-rows scale).

When a student asks "shouldn't we add a DLQ / split the role / add a GSI?" → "Yes, for production. The course optimizes for the minimum serverless surface that works end-to-end; hardening is a separate pass once the milestones are stable."

---

## Cross-references

- [[m1-1-subscribe-to-a-plan]] — DynamoDB table + `save_subscription` Lambda + API Gateway (Rule 3, IAM).
- [[m1-2-fetch-prices-on-schedule]] — `parser_wrapper`/`parser` + EventBridge + S3 routes.
- [[m1-3-email-on-target]] — `fare_notification` + SQS + `notification_history` dedup (Rules 5).
- [[m2-stripe-subscription]] — the webhook + the raw-body signature rule (Rule 4).
- [[stripe-best-practice]] — the application side of the same webhook.
- [[supabase-best-practice]] — why no AWS key lives in the front-end (Supabase is the only thing the browser talks to, auth-only).
