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
| Deploy a multi-file Lambda | `zip` the dir → `--zip-file fileb://fn.zip` | S3: MCP zips in its workdir → `s3 cp` → CFN `Code.S3Bucket/S3Key` (Method 2 below) |
| Read a Lambda's logs | `aws logs tail /aws/lambda/<fn> --since 10m --follow` | `call_aws logs tail ...` or the CloudWatch console |
| Inspect a DynamoDB row | `aws dynamodb get-item --table-name subscriptions --key '{...}'` | `call_aws dynamodb get-item ...` |

**Profile/region:** the course uses the **`[default]`** AWS profile (no `--profile` flag needed). It has **no default region**, so **every** call passes `--region us-east-1`. In Cowork the AWS API MCP reads `~/.aws/credentials`'s `[default]` block (written via a Claude CLI session — see [[m1-1-subscribe-to-a-plan-prerequisites]]). Forgetting the region is the #1 "it works for me but not in the script" gap.

---

## Cowork execution constraints (read before you deploy)

In Cowork there are **two separate hosts**, and the gap between them — **not** an auth gap — is what bites:

- **The AWS API MCP** *does* have AWS access: it authenticates from `~/.aws/credentials` (the `[default]` profile written in prereqs) and runs every `aws` command. **Creds and network are fine.** Its one limit: a `--zip-file fileb://…` path must be **inside the MCP's own workdir** (`/tmp/aws-api-mcp/workdir`); any other path is rejected ("outside allowed working directory").
- **The bash/build sandbox** is a *different* host. It can build a zip, but has **no AWS creds and no network route to AWS** (s3/sts/lambda return **HTTP 000**), and **no shared path into the MCP's workdir** — so it can't hand the built zip to the MCP, and can't upload to S3 itself (`aws s3 presign` only mints **GET** URLs).

So `aws lambda create-function --zip-file fileb://fn.zip` fails because **the zip lives on the build host while the MCP can only read its own workdir — a file-transfer gap, not an auth gap.** The other gotchas from a real M1.1 run:

1. **The zip-transfer gap (above):** you can't get a built zip to the MCP. → deploy code **without a file** (inline CFN — see the box below). The `create-function --zip-file fileb://…` flow is **CLI-mode only**.
2. **The build sandbox has no AWS network:** `curl`/uploads to AWS from it return **HTTP 000**; the web-fetch tool is **GET-only**. (So don't try to upload a layer to S3 from the sandbox.)
3. **You can't read MCP-written files.** `aws lambda invoke … out.json` writes the response body where you **can't read it back** (no shell to `cat`). **Verify the effect instead** — `get-item` (DynamoDB) or a **GET** endpoint.
4. **CLI flags that break through the MCP:** `lambda invoke` **rejects `--cli-binary-format`** and **errors on `--query`**; **JMESPath backtick literals fail to parse** (`SecretList[?starts_with(Name,\`flight/\`)]` → "Unknown token"). Use plain `aws lambda invoke … out.json` and `--query "SecretList[].Name"` (no backticks).
5. **Git on the mounted folder fails.** `git clone`/ops in the mounted workspace folder error (`config.lock: Operation not permitted` — FUSE can't do git's locking). **Clone into a native dir** (the agent's home); treat the working copy as **ephemeral** — GitHub + Vercel are the source of truth.

**→ The Cowork way to deploy Lambda code (two methods):**

**Method 1 — inline `Code.ZipFile` (single small file).** Send the code *inside* the API call — **CloudFormation with inline `Code.ZipFile`**: `aws cloudformation create-stack --template-body '<json>'`, function code inline, no file transfer. **Limits: single file, ≤4096 chars, handler `index.handler`.** This is how M1.1's one-file Lambdas (`save_subscription`, `list_subscriptions`) deploy — they use only boto3 (already in the runtime), so no extra files.

**Method 2 — S3 `Code.S3Bucket/S3Key` (multi-file or >4096 chars).** When a Lambda needs **more than one file** (e.g. M1.2's parser = `index.py` + `travelpayouts.py` + `routes.py`) or one file **exceeds 4096 chars** (`travelpayouts.py` alone is ~7.4 KB), inline won't fit. The fix stays inside Cowork because **the AWS API MCP has both AWS network AND a writable workdir** — so the MCP can build the zip itself and upload it, with no build-host involved:

1. Ask the MCP to **write the handler files into its own workdir** (`/tmp/aws-api-mcp/workdir`) — it can create files there.
2. Ask it to **`zip`** them and **`aws s3 cp parser.zip s3://flight-config-<ACCOUNT_ID>/lambda/parser.zip`** (reuses the bucket M1.2 already makes; the MCP has creds+network, so this `cp` works — unlike the build sandbox, which returns HTTP 000).
3. Deploy with **CloudFormation `Code:{S3Bucket,S3Key}`** (or `aws lambda create-function --code S3Bucket=…,S3Key=…`). Lambda fetches the object **server-side from S3** — no `fileb://`, no host gap. Redeploy after an edit = re-`cp` the new zip + `aws lambda update-function-code --s3-bucket … --s3-key …`.

This is the standard deploy for **every multi-file or layered Lambda** from M1.2 on. (M1.2's `travelpayouts.py` is **stdlib-only** — `urllib`, not `requests` — so the parser needs **no layer**, just these multiple stdlib files. The `stripe`+`requests` **layer** is an **M2-only** concern; publish it the same S3 way — `aws s3 cp layer.zip …` from the MCP workdir, then `publish-layer-version --content S3Bucket=…,S3Key=…`.)

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
- **Single-file Lambdas** (M1.1's `save_subscription`, `list_subscriptions`) deploy as **inline CFN `Code.ZipFile`** with **no layer** (they only use boto3, in the runtime).
- **Multi-file Lambdas** (M1.2's `parser` = `index.py`+`travelpayouts.py`+`routes.py`) deploy via **S3** (Method 2 above): the MCP writes the files into its workdir, zips, `s3 cp`s, and CFN points `Code` at the S3 object. **M1.2 needs no layer** — `travelpayouts.py` is stdlib-only.
- **The `stripe`+`requests` layer** is an **M2** need, not M1.2. Publish it the same S3 way (MCP workdir → `s3 cp layer.zip` → `publish-layer-version --content S3Bucket=…,S3Key=…`).

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
aws logs tail /aws/lambda/flight-parser --since 15m --follow --region us-east-1
aws logs tail /aws/lambda/flight-fare-notification --since 15m --region us-east-1
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
