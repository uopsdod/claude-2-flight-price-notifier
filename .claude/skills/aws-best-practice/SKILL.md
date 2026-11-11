---
name: aws-best-practice
description: Hard rules and operational SOP for the AWS side of the Flight Price Notifier course — a SERVERLESS stack (Lambda + DynamoDB + SQS + S3 + API Gateway + EventBridge + Secrets Manager). Use whenever a student is packaging a Lambda, writing to DynamoDB, wiring SQS, handling the ECPay callbacks (CheckMacValue), managing secrets, or debugging an AWS-side failure in M1+. Sourced from this stack's real failure modes.
---

# AWS Best Practice (Flight Price Notifier — serverless)

This course's AWS side is **100% serverless** — there is **no EC2, no SSH, no SSM, no systemd**. The pieces are: **6 Lambdas**, **2 DynamoDB tables** (`subscriptions`, `notification_history`), **2 SQS queues**, an **S3** routes config, **API Gateway (HTTP API v2)**, **EventBridge**, and **Secrets Manager**. AWS access in Cowork is the official **AWS MCP** connector, signed in through the browser (OAuth — no IAM user, no access key; set up in [[m0-landing-and-signin]] Step 5.2); every command pins **`--region us-east-1`** (`region_name="us-east-1"` in AWS MCP scripts).

When guiding a student through AWS operations, **apply these rules proactively** — stop them before they break one. Each rule maps to a real failure mode of *this* stack.

> **Multi-account variant (M3 go-live):** the AWS MCP uses **one `[default]` profile**, but the **domain's Route 53 hosted zone** can live in a **different AWS account** than the flight project (Lambdas/secrets/API Gateway). When they differ, **switch the `[default]` profile between DNS steps (domain account) and secret/Lambda steps (project account)** — see [[m3-domain-prerequisites]]. For a single-account student this doesn't arise; treat it as the advanced case.

> Adapted from a Course 2 AWS skill that was EC2/SSM-based. Those rules (SSH-vs-SSM, systemd PATH, instance tagging) **do not apply** — this stack has no servers to log into. Only the secrets-hygiene and IAM-user rules carried over; the rest below are serverless-native.

---

## Execution mode: Cowork vs CLI

The hard rules apply identically in both — only the command surface differs.

| Operation | CLI mode | Cowork mode |
|---|---|---|
| Run any AWS API call | `aws <service> <verb> ... --region us-east-1` | AWS MCP `aws___run_script` → `await call_boto3(service_name="<service>", operation_name="<PascalCaseOperation>", region_name="us-east-1", params={...})` |
| Deploy a source-only Lambda (any size) | `aws lambda create-function --zip-file fileb://fn.zip ...` | `ascii_zip()` in the script → `lambda CreateFunction` / `UpdateFunctionCode` with `Code.ZipFile` (**Method A** below) |
| Land binary bytes in S3 (a dependency zip, an image) | `aws s3 cp file s3://…` | the `flight-seed` base64 bridge (**Method C** below) — `call_boto3` corrupts binary bodies |
| Land a text object in S3 (`flight-routes.json`) | `aws s3 cp` | `s3 PutObject` with a **str** `Body` — text bodies arrive intact |
| Read a Lambda's logs | `aws logs tail /aws/lambda/<fn> --since 10m --follow` | `logs FilterLogEvents` (`logGroupName="/aws/lambda/<fn>"`); quote any `filterPattern` containing `-` |
| Inspect a DynamoDB row | `aws dynamodb get-item --table-name subscriptions --key '{...}'` | `dynamodb` `GetItem` via AWS MCP |

**Region:** **every** call passes `us-east-1` (`--region us-east-1` in CLI, `region_name="us-east-1"` in AWS MCP scripts). Forgetting the region is the #1 "it works for me but not in the script" gap. In Cowork, AWS access is the AWS MCP browser sign-in — nothing on disk; CLI mode uses the student's local `aws` login.

---

## Cowork execution constraints (read before you deploy)

*Verified on AWS MCP (`aws___run_script` / `call_boto3`) on 2026-11-11 with throwaway `mcp-test-*` resources.* Two hosts are involved, and neither can simply hand the other a file:

- **The AWS MCP sandbox** (`aws___run_script`) has AWS access and returns results inline, but it is **not a full Python**: `zipfile`, `hashlib`, `os`, `struct`, `base64` and `exec()` are **blocked**, and it has **no network except `call_boto3`**.
- **The Cowork bash sandbox** has `zip`/`base64`, but **no route to AWS** (a presigned-URL PUT fails at the proxy with `CONNECT tunnel failed, response 403`).

What that means in practice:

1. **🔴 Binary is silently corrupted.** Every blob parameter passed through `call_boto3` (`s3 PutObject` `Body`, `lambda` `Code.ZipFile`, `Invoke` `Payload`) goes through a lossy UTF-8 decode: bytes `0x00–0x7F` survive, **every byte ≥ `0x80` becomes U+FFFD**. The call still **succeeds**. Measured: a 51,425-byte zip was stored as 93,000 bytes with a wrong ETag; a normal zip passed to `CreateFunction` failed with `InvalidParameterValueException: Uploaded file must be a non-empty zip`. → **Only ever send bytes that are all < `0x80`** (ASCII text, ASCII JSON, or the ASCII-safe zip from Method A).
2. **🟢 Text works.** `s3 PutObject` with a `str` body lands intact (ETag == md5); `GetObject` returns text readable in-script.
3. **🟢 Results come back inline.** `lambda Invoke` returns the response `Payload` as a readable string — no output file to `cat`. `LogResult` is included.
4. **🟢 Logs:** `logs FilterLogEvents` works. Gotcha: an unquoted `filterPattern` like `mcp-test` matches nothing (`-test` means "exclude"); quote it: `"\"mcp-test invoked\""`.
5. **🟢 Waiting:** poll inside one script with `await asyncio.sleep(…)` (e.g. `GetFunction` until `State == "Active"`, `DescribeStacks` until `CREATE_COMPLETE`). There is no CLI `wait`, and you don't need one.
6. **🟢 No JMESPath.** There is no `--query`; filter the response in Python (`[s["Name"] for s in resp["SecretList"]]`).
7. **IAM propagation:** `CreateFunction` right after creating a role fails with `The role defined for the function cannot be assumed by Lambda` — retry in-script with `asyncio.sleep(5)` (worked on the 3rd attempt).
8. **Git on the mounted folder fails** (`config.lock: Operation not permitted` — FUSE can't do git's locking). **Clone into a native dir** (the agent's home); treat the working copy as **ephemeral** — GitHub + Vercel are the source of truth.

**→ Deployed shape ≠ repo layout (state this up front).** Every function in this stack deploys as a **single-file `index.handler`** — *not* the `aws/<fn>/handler.py` + a `common/` package the repo sources suggest. Fold shared helpers (CMV, ddb access) **into each `index.py`** (boto3/stdlib only — the runtime already has boto3). The repo's `aws/` tree can lag the deployed code; treat the deployed function as the source of truth for behavior.

**→ The Cowork way to deploy Lambda code:**

**Method A — ASCII-safe zip, straight into `Code.ZipFile` (recommended, any size).** Build an uncompressed one-file zip in pure Python whose **every byte is < `0x80`** (a salt comment is varied until the CRC, size and offset fields are all ASCII-safe), then pass it to `CreateFunction` / `UpdateFunctionCode`. No CloudFormation, no 4096-char cap (verified with a 4,151-char `index.py`; a ~93 KB payload crossed in one call), no S3 bridge. Non-ASCII characters (e.g. Chinese email text) are auto-escaped to `\uXXXX`, so they must sit in **normal string literals or comments** — not in `r"…"` raw strings or `b"…"` bytes literals. Paste this helper into the script (it uses no imports):

```python
# --- ascii_zip helper: no imports (AWS MCP sandbox blocks zipfile/hashlib/struct/base64) ---
_CRC = []
for _n in range(256):
    _c = _n
    for _ in range(8):
        _c = (0xEDB88320 ^ (_c >> 1)) if (_c & 1) else (_c >> 1)
    _CRC.append(_c)

def _crc_update(c, data):
    # running CRC-32 state (start from 0xFFFFFFFF, finish with ^ 0xFFFFFFFF)
    for b in data:
        c = _CRC[(c ^ b) & 0xFF] ^ (c >> 8)
    return c

def _le(n, size):
    return n.to_bytes(size, "little")

def ascii_zip(source, name="index.py"):
    """Return an uncompressed one-file zip whose every byte is < 0x80.
    Non-ASCII characters are escaped (\\uXXXX), so they must sit inside normal
    (non-raw, non-bytes) string literals or comments."""
    src = source.encode("ascii", "backslashreplace").decode("ascii")
    fname = name.encode("ascii")
    body = src.encode("ascii")
    body_crc = _crc_update(0xFFFFFFFF, body)          # CRC the source once
    hdr = 30 + len(fname)                             # local header length

    def safe(n):
        return all(x < 0x80 for x in n.to_bytes(4, "little"))

    # 1) pick a total file size whose size AND central-directory offset bytes are all < 0x80
    size = len(body) + 32                             # room for the salt line
    while not (safe(size) and safe(size + hdr)):
        size += 1
    # 2) pad to exactly that size; vary only a fixed-width salt so just the CRC changes
    for salt in range(100000):
        head = "\n# zip-salt: %06d " % salt
        tail = (head + "s" * (size - len(body) - len(head) - 1) + "\n").encode("ascii")
        data = body + tail
        crc = _crc_update(body_crc, tail) ^ 0xFFFFFFFF
        if not safe(crc):
            continue
        local = (b"PK\x03\x04" + _le(20, 2) + _le(0, 2) + _le(0, 2)      # version, flags, stored
                 + _le(0, 2) + _le(0x21, 2)                               # time, date (1980-01-01)
                 + _le(crc, 4) + _le(size, 4) + _le(size, 4)
                 + _le(len(fname), 2) + _le(0, 2) + fname)
        central = (b"PK\x01\x02" + _le(20, 2) + _le(20, 2) + _le(0, 2) + _le(0, 2)
                   + _le(0, 2) + _le(0x21, 2)
                   + _le(crc, 4) + _le(size, 4) + _le(size, 4)
                   + _le(len(fname), 2) + _le(0, 2) + _le(0, 2)          # name, extra, comment
                   + _le(0, 2) + _le(0, 2) + _le(0, 4)                   # disk, int attr, ext attr
                   + _le(0, 4) + fname)                                  # local header offset
        cd_offset = len(local) + size
        end = (b"PK\x05\x06" + _le(0, 2) + _le(0, 2) + _le(1, 2) + _le(1, 2)
               + _le(len(central), 4) + _le(cd_offset, 4) + _le(0, 2))
        blob = local + data + central + end
        if all(x < 0x80 for x in blob):
            return blob
    raise ValueError("no ASCII-safe salt found")
# --- end helper ---
```

Then, in the same `aws___run_script` call:

```python
SOURCE = """<the full index.py>"""
zip_bytes = ascii_zip(SOURCE)
ROLE = "arn:aws:iam::<ACCOUNT_ID>:role/flight-lambda-role"

for attempt in range(6):                      # IAM-propagation retry
    try:
        await call_boto3(service_name="lambda", operation_name="CreateFunction", region_name="us-east-1",
                         params={"FunctionName": "flight-parser", "Runtime": "python3.12",
                                 "Handler": "index.handler", "Role": ROLE, "Timeout": 30,
                                 "Environment": {"Variables": {"CONFIG_BUCKET": "flight-config-<ACCOUNT_ID>"}},
                                 "Code": {"ZipFile": zip_bytes}})
        break
    except Exception as e:
        if "cannot be assumed" not in str(e):
            raise
        await asyncio.sleep(5)

for _ in range(30):                           # wait until Active
    fn = await call_boto3(service_name="lambda", operation_name="GetFunction", region_name="us-east-1",
                          params={"FunctionName": "flight-parser"})
    if fn["Configuration"]["State"] == "Active":
        break
    await asyncio.sleep(2)
result = {"state": fn["Configuration"]["State"]}
result
```

- **Redeploy** = `UpdateFunctionCode` with `{"FunctionName": …, "ZipFile": ascii_zip(SOURCE)}`, then poll `GetFunction` until `LastUpdateStatus == "Successful"`.
- **Verify by smoke test:** `lambda Invoke` with an ASCII JSON payload (`json.dumps(…)` escapes non-ASCII by default) and read the returned `Payload`.
- A function whose create **failed** on a bad zip is stuck `State=Failed` — `UpdateFunctionCode` is blocked; **delete and recreate** it.

**Method B — inline CloudFormation `Code.ZipFile` (still works, ≤4096 chars).** `cloudformation CreateStack` with the code inside `TemplateBody` (a text parameter, so the byte corruption doesn't apply). Limits: single file, ≤4096 chars, handler `index.handler`, and careful quote-escaping. Poll `DescribeStacks` in-script until `CREATE_COMPLETE`. Existing course steps that use it (M1.1's small Lambdas, `flight-resend-test`) still work as written; Method A is simpler for anything new.

**Method C — the `flight-seed` base64→S3 bridge (only for real binary).** Needed only when you must land **non-ASCII bytes** in S3 — e.g. a zip with compiled dependencies built in the bash sandbox. The bridge's `Invoke` payload is ASCII JSON, so it survives `call_boto3`:

1. Deploy `flight-seed` once (Method A or B):
   ```python
   import base64, boto3
   def handler(e, c):
       boto3.client("s3").put_object(
           Bucket=e["bucket"], Key=e["key"],
           Body=base64.b64decode(e["b64"]),
           ContentType=e.get("ct", "application/octet-stream"))
       return {"ok": True, "key": e["key"]}
   ```
   Its role needs **`s3:PutObject`** on the target bucket.
2. In the bash sandbox: build the zip, `base64 -w0` it, and note `md5 -q` of the zip.
3. `lambda Invoke` `flight-seed` with `Payload = json.dumps({"bucket": …, "key": "lambda/x.zip", "b64": "<BASE64>", "ct": "application/zip"})`.
4. **HARD RULE: `s3 HeadObject` and require ETag == the local md5 before `CreateFunction`/`UpdateFunctionCode` with `Code.S3Bucket/S3Key`.** The base64 text is copied by the model from the bash output into the script, and long copies have corrupted silently before (same-length one-character substitutions that only the ETag check caught). For a zip over ~1.5 KB, split the base64 into ~600-char pieces aligned to 4-char boundaries, seed each to its own key, check each part's ETag, then join them with a `flight-assemble` Lambda (read the parts in order, `put_object` the concatenation) and check the final ETag.

---

## Hard rules

### Rule 1 — Pin `us-east-1` on every call (`--region` in CLI, `region_name` in AWS MCP)

> **The rule:** No bare `aws ...` without a region. Always `--region us-east-1` (AWS MCP: `region_name="us-east-1"`). All ARNs hardcode `us-east-1` and the account ID.

**Why:** A call without an explicit region either errors (`You must specify a region`) or, worse, silently hits a *different* default region where none of your resources exist — and you get `ResourceNotFoundException` for a table that demonstrably exists (in us-east-1). The same drift bites ARNs: an EventBridge rule ARN or SQS ARN with the wrong region/account silently never matches. Pin both, everywhere.

**How to apply:** In `scripts/env.sh`: `REGION=us-east-1; ACCOUNT=<your account id>` and reference `--region "$REGION"` in every script (resolve `ACCOUNT` once via `aws sts get-caller-identity --query Account --output text`). When a call returns "not found" for something you just created, **check the region first** before assuming it wasn't created.

---

### Rule 2 — Secrets Manager is the single source of truth for EVERY key — so a fresh Cowork session never re-asks

> **The rule:** **All** API keys/tokens live under **`flight/*` in Secrets Manager** — collected **once**, reused forever. The only credential that must persist *locally* is the **`[default]` AWS profile** (it's how the AWS MCP authenticates); everything else is one `get-secret-value` away. So a new Cowork session re-derives every key from AWS instead of asking you to paste them again. **No keys in code, in committed env files, or anywhere the front-end can be scraped for a *write* secret.**

**The canonical `flight/*` set:**

| Secret | Shape | Introduced | Consumed by |
|---|---|---|---|
| `flight/travelpayouts` | `{"token":"…"}` | M1.1 | **Lambda runtime** (parser) |
| `flight/resend` | `{"api_key":"…","from":"…"}` | M1.3 | **Lambda runtime** (fare-notification) |
| `flight/ecpay` | `{"merchant_id":"…","hash_key":"…","hash_iv":"…","env":"stage|prod","amount":"…"}` | M2 | **Lambda runtime** (checkout + callbacks + cancel) |
| `flight/telegram` | `{"bot_token":"…"}` | M4 | **Lambda runtime** (chat) |
| `flight/anthropic` | `{"api_key":"sk-ant-…"}` | M4 | **Lambda runtime** (chat) |
| `flight/github` | `{"pat":"github_pat_…"}` or bare string | M0 (Step 6) | **session bootstrap** — the Cowork git tool, to push (M1.1 prereq just discovers it) |
| `flight/supabase` | `{"url":"…","publishable_key":"…"}` | M0 | **session recall** — the front-end build env (publishable key is **public by design**) |

**Two kinds of secret, treated the same way for storage but not for sensitivity:**
- **Runtime-read** (travelpayouts/resend/ecpay/telegram/anthropic) — a Lambda does `get_secret_value` at runtime; these are real secrets that must never reach the browser. (For `flight/ecpay`: the `merchant_id` is not secret but the `hash_key`/`hash_iv` are — keep the whole object server-side.)
- **Convenience-cache** (github/supabase) — stored so a new session recalls them without you re-finding them. The **GitHub PAT is a real write-credential** (treat it like a password; scope it to Contents:RW on the one repo). The **Supabase `publishable_key` is public by design** (it ships to the browser in `VITE_SUPABASE_PUBLISHABLE_KEY`) — caching it is for convenience, not secrecy. **Never** cache the Supabase **service-role** key.

**Why:** Every other home for a *write* key has a leak story — committed `.env` is indexed by GitHub's secret scanner instantly; a write key in client JS is visible in every visitor's network tab. Secrets Manager is KMS-encrypted, IAM-scoped, and `GetSecretValue` is CloudTrail-logged. And **DynamoDB/SQS/S3 need NO secret at all** — the Lambda's IAM role authorizes them.

**How to apply — check-then-collect (the SOP every prereq follows):** before asking the student for a key, check whether it already exists and only collect if missing:
```bash
# does it already exist? (a new session almost always: yes)
aws secretsmanager describe-secret --secret-id flight/resend --region us-east-1 --query "Name"
#   → returns "flight/resend"  ⇒ SKIP collection, it's already stored
#   → ResourceNotFoundException ⇒ collect the key, then:
aws secretsmanager create-secret --name flight/resend --secret-string '{"api_key":"re_…","from":"…"}' --region us-east-1
```
- To **update** an existing secret, `put-secret-value` (replaces the whole value — include every field).
- Scope the role's `secretsmanager:GetSecretValue` to `arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:flight/*` — **never** `Resource: "*"`.
- **Chat-retention caveat:** a key briefly appears in the transcript on its way to `create-secret`. Because it's now stored **once** (not re-pasted every session), there's far less exposure — but still rotate at course end. For real production, type values in the console.
- M3 go-live check greps the deployed front-end for `AKIA…` / `service_role` / any *write* secret → must be absent (the Supabase `publishable_key` is allowed there — it's public).

---

### Rule 3 — DynamoDB numbers are `Decimal`, not `float` — convert on the way in AND out

> **The rule:** When writing `target_price` / `price` to DynamoDB, pass a `Decimal`, not a Python `float`. When reading them back for arithmetic or JSON, convert `Decimal` → `int`/`float`/`str` explicitly.

**Why:** boto3's DynamoDB resource **rejects `float`** with `TypeError: Float types are not supported. Use Decimal types instead` — so a handler that does `{"target_price": 12000.0}` crashes on the very first `put_item`. Coming back the other way, a `Decimal` is **not JSON-serializable**, so `json.dumps(item)` throws `TypeError: Object of type Decimal is not JSON serializable` when the Lambda tries to return the row or log it. Both are first-hour M1.1 failures.

**How to apply:**
- Write: `from decimal import Decimal; item["target_price"] = Decimal(str(target_price))` (via `str` to avoid binary-float artifacts like `12000.00000001`).
- Read/return: convert before `json.dumps` — `int(item["target_price"])` for whole TWD, or a small `default=` encoder that maps `Decimal→int/float`.
- Keep this in `aws/common/ddb.py` so every handler shares one correct conversion.

---

### Rule 4 — The ECPay callbacks must verify CheckMacValue on the decoded FORM body — and keep empty-string fields (M2)

> **The rule:** In `flight-ecpay-return` / `flight-ecpay-period`, the body is **`application/x-www-form-urlencoded`, not JSON**. API Gateway HTTP API v2 may deliver it **base64-encoded** (`event["isBase64Encoded"] == True`) — decode to bytes, then `urllib.parse.parse_qs`. Recompute the CheckMacValue over the returned fields and compare. **Keep empty-string fields** (`CustomField3=`, `CustomField4=`) in the hash — drop only `CheckMacValue` itself.

**Why:** ECPay signs the exact field set it sent, **including empty CustomFields**. If you filter out `v == ""` before hashing (the single most common ECPay bug), you hash a different string and **every real callback fails verification** — the symptom looks like "ECPay isn't calling me" when you're actually rejecting a valid call. (Likewise, `json.loads`-ing a form body just yields garbage.) These are the highest-risk files in M2; wrong handling here means payments "succeed" at ECPay but never activate the subscription. See [[ecpay-best-practice]] Rule 2 for the full CMV algorithm.

**How to apply:**
```python
import base64, urllib.parse, hashlib
raw = event["body"]
if event.get("isBase64Encoded"):
    raw = base64.b64decode(raw).decode("utf-8")
params = {k: v[0] for k, v in urllib.parse.parse_qs(raw, keep_blank_values=True).items()}  # keep_blank!
# recompute CMV over params (KEEP "" values; drop only CheckMacValue) → compare → then RtnCode=="1"
```
There's **no `stripe listen` equivalent** — ECPay needs a public URL. Test via the stage 後台「模擬付款」 button or a real test-card run (see [[ecpay-best-practice]] Rules 7–8). A CMV mismatch is almost always the empty-field bug or a trailing-newline in a signed URL, not the keys.

---

### Rule 5 — SQS visibility timeout ≥ the consumer Lambda's timeout, and the consumer must be idempotent

> **The rule:** Each queue's `VisibilityTimeout` must be **≥** the timeout of the Lambda that consumes it (fare-queue → `fare_notification`, status-queue → `status_notification`). And the consumers must tolerate a message being delivered more than once.

**Why:** If the visibility timeout is shorter than the Lambda runtime, SQS makes the message visible again **while the Lambda is still processing it**, a second invocation picks it up, and the user gets a **duplicate email**. SQS is at-least-once by design, so even with correct timeouts a retry can re-deliver. The defense is the `notification_history` dedup (24h floor + re-alert thresholds) — which is exactly why dedup lives in the consumer, not the parser.

**How to apply:**
- The fare queue ships at the **default 30s**, equal to the Lambda's 30s timeout — that's **not** "≥", it's "==", and a slow send gets redelivered mid-flight. Set a concrete higher value (≈6×): `aws sqs set-queue-attributes --queue-url <url> --attributes VisibilityTimeout=180 --region us-east-1`.
- `fare_notification` checks `notification_history` **before** sending and writes a history row **after** — so a re-delivered message finds the recent row and skips.
- **The consumer role needs all three SQS actions** — `sqs:ReceiveMessage`, `sqs:DeleteMessage`, **and `sqs:GetQueueAttributes`** on the queue. The event-source mapping **fails closed and silently** (never polls, no error in the function log) if any is missing — distinct from the producer's `SendMessage`/`GetQueueUrl`.
- **Creating the event-source mapping immediately drains whatever is already on the queue.** Before you create it, **`aws sqs purge-queue --queue-url <url>`** to clear stale test messages, then seed one clean test subscriber — otherwise old/undeliverable matches burst through at once (and, on the demo sender, become a wave of `403`s that can trip Resend's rate limit). For permanent-failure protection without a full DLQ, set a redrive policy with a small `maxReceiveCount`.

---

### Rule 6 — Don't bundle boto3; DO bundle the stdlib helpers. This stack needs NO dependency layer.

> **The rule:** The Lambda runtime already includes **boto3** — never add it to the zip or layer. Everything else this course needs is **stdlib**: `travelpayouts.py` + `email_render.py` (copied into the function zip, not layered), and the ECPay CheckMacValue (`hashlib`) + the cancel POST (`urllib`). So there is **no `flight-deps` layer at all** — M2 does not add one.

**Why:** Bundling boto3 bloats the zip and can shadow the runtime's version with a subtly different one → confusing `botocore` errors. The old plan shipped a `stripe`+`requests` layer for the Stripe webhook; **ECPay removes that need** — CMV is `hashlib.sha256`, the form is built as plain strings, the cancel call is `urllib.request`. Staying layer-free means no `--platform manylinux` cross-build headaches and a smaller, faster cold start. `travelpayouts.py` and `email_render.py` are stdlib-only by design, so a plain `cp` into the function dir is all that's needed.

**How to apply (CLI mode):**
- **No `03_build_layer.sh` step** — skip it; there's no layer to publish. (If a leftover script references `flight-deps`, delete it.)
- `04_deploy_lambdas.sh`: `cp flightproxy/travelpayouts.py aws/parser/` and `cp flightproxy/email_render.py aws/fare_notification/` before zipping each function. The ECPay Lambdas (`save_subscription`, `ecpay_return`, `ecpay_period`, `cancel_subscription`) are stdlib + boto3 — nothing to copy or layer.
- If you ever add a C-extension dep later, build it with `--platform manylinux2014_x86_64` (or Docker), not on the Mac directly.

**In Cowork** the build-sandbox can't hand a zip to the MCP (see *Cowork execution constraints* above), so:
- **Every function folds into one `index.py`** (boto3/stdlib only, in the runtime) and deploys with **Method A** (ASCII-safe zip → `Code.ZipFile`) — any size, **no layer**. M1.2's `parser`/`wrapper` inline `fetch_cheapest` + the routes read; M1.3's notification Lambda inlines its HTML/text renderer.
- Inline CFN (Method B) still works for the existing ≤4096-char steps; the `flight-seed` bridge (Method C) is only for genuine binary bytes.
- **No dependency layer anywhere** (Rule 6) — M2's ECPay Lambdas are stdlib + boto3 (CMV via `hashlib`, cancel via `urllib`), so there's no `flight-deps` zip to seed.

---

### Rule 7 — Lambdas are NOT in a VPC — keep it that way

> **The rule:** Create every Lambda with **no VPC config**. They reach the public internet (Travelpayouts, ECPay, Resend) and AWS service endpoints directly.

**Why:** Putting a Lambda in a VPC removes its default internet route — outbound calls to `api.resend.com` / `payment.ecpay.com.tw` / Travelpayouts hang and time out unless you also add a NAT gateway (extra cost + setup) or VPC endpoints for every service. For this course there's no reason to be in a VPC; staying out keeps outbound HTTPS working with zero config. (DynamoDB/SQS/S3 are reached over their public endpoints via the SDK, authorized by IAM — no VPC needed.)

**How to apply:** Don't pass `--vpc-config` to `create-function`. If a student copied a VPC config from elsewhere and Resend calls start timing out, the VPC is the first suspect.

---

### Rule 8 — Connect via the AWS MCP sign-in (no access keys); one shared `flight-lambda-role`

> **The rule:** Cowork reaches AWS only through the **AWS MCP** connector, signed in through the browser ([[m0-landing-and-signin]] Step 5.2) — **no IAM user + access key, no `~/.aws/credentials`, no `AKIA…` key pasted anywhere.** All Lambdas assume one **`flight-lambda-role`** scoped to exactly this project's resources.

**Why:** An access key is a long-lived credential — once it's in a file, a chat, or a screenshot, anyone who sees it has that access until someone revokes it. The OAuth sign-in leaves no key to leak; you cut access by removing the connector. For the Lambdas, one shared role is fine at course scale; its inline policy is scoped to the two table ARNs, the two queue ARNs, the `flight/*` secrets, the S3 routes prefix, and `lambda:InvokeFunction` on `flight-parser` — **not** `Resource: "*"`.

**How to apply:**
- If AWS tools disappear or calls fail with a sign-in / auth error → the session expired; reconnect the AWS MCP connector and sign in again. Don't fall back to an access key.
- A student who set up the old way (IAM user + access key for the old AWS API MCP) → once AWS MCP works, deactivate and delete that key. If an `AKIA…` key is ever pasted into chat / a commit / a screenshot → delete it immediately.
- Keep the role's policy in `scripts/iam-policy.json` (version-controlled), so it's reproducible.
- For a course, scoping to specific resource ARNs (not full admin on the role) is the teaching-grade floor; production would split per-Lambda least-privilege.

---

## How to debug a serverless failure (there's no server to log into)

Everything surfaces in **CloudWatch Logs**, one group per function:

```bash
# CLI mode:
aws logs tail /aws/lambda/flight-parser --since 15m --follow --region us-east-1
aws logs tail /aws/lambda/flight-fare-notification --since 15m --region us-east-1
# Cowork: AWS MCP `logs FilterLogEvents` (same idea as this CLI line; no `logs tail`):
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
3. **ECPay callback `CheckMacValue Error` / row never activates** → Rule 4 (decode the form body + `isBase64Encoded`, KEEP empty fields), not the keys.
4. **Resend/ECPay calls time out from inside a Lambda** → Rule 7 (the function is in a VPC; take it out).
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

- [[m1-flight-price-checker]] — the whole M1 build: DynamoDB + `save_subscription`/API GW (Part 1.1), `parser_wrapper`/`parser` + EventBridge + S3 routes (Part 1.2), `fare_notification` + SQS + `notification_history` dedup (Part 1.3).
- [[m2-ecpay-subscription]] — the recurring checkout + the two callbacks + the cancel Lambda (Rule 4 is the callback body/CMV handling).
- [[ecpay-best-practice]] — the application side of the same callbacks (CMV algorithm, empty-field bug, `1|OK`, SimulatePaid).
- [[supabase-best-practice]] — why no AWS key lives in the front-end (Supabase is the only thing the browser talks to, auth-only).
