---
name: m1-flight-price-checker-prerequisites
description: One-time setup before Milestone 1 of the Flight Price Notifier course, done in one shot — clone the M0 GitHub repo (into a native dir) + prove push→Vercel, AWS access via the `[default]` profile (admin IAM user + AWS API MCP), cache the GitHub PAT + Supabase url/anon in Secrets Manager, collect the Travelpayouts token, and set up + verify Resend (the alert email) via a throwaway Lambda. Cowork-first. Use when the student starts M1 for the first time, or when `m1-flight-price-checker` / `-checklist` detects the project, AWS access, the Travelpayouts token, or Resend is missing.
---

# M1 Prerequisites — Project + AWS + Travelpayouts + Resend (one shot)

Everything M1 needs, set up once. By the end you have: the repo cloned with a working push→Vercel loop, AWS wired (`[default]` profile), every key cached in Secrets Manager (so future sessions never re-ask), and Resend proven to send.

## Execution mode: Cowork (default) vs CLI

Run mainly in **Cowork** — you talk to a Cowork agent that has the **git tool** + the **AWS API MCP**. The **`ask """ … """`** blocks below are pasted to the agent **verbatim**. On the local Claude CLI instead, run the equivalent shell commands. Every AWS command uses `--region us-east-1`; the `[default]` profile means **no `--profile`**.

> **Read [[aws-best-practice]] *Cowork execution constraints* once.** Two facts shape everything: (1) the AWS API MCP has creds + network but the common connector is **`aws`-only** (no shell/`zip`/file authoring) → Lambda code deploys via **inline CFN** (small) or the **`flight-seed` S3 bridge** (big); (2) the **sandbox can't reach arbitrary hosts** (e.g. `api.resend.com` is proxy-blocked) → anything that POSTs to a third party runs **from a Lambda**, not the sandbox.

## Full system this sets up for

```
 SUPABASE (auth) ─▶ Product Site [Vercel] ──/subscribe──▶ Subscriptions [DynamoDB]
   EventBridge ─▶ Parser Wrapper ─▶ Parser ─(Travelpayouts)─▶ match ─▶ [SQS]
   [SQS] ─▶ Fare Notification λ ─(dedup: Notification History)─▶ Email [Resend]
 Repo loop:  Landing Page (Lovable) ──▶ Repo (GitHub) ──R──▶ Product Site (Vercel)
```
This prereq gets the **repo loop**, **AWS access**, and the **Travelpayouts + Resend** accounts ready; M1 builds the rest.

---

## Part A — Project: clone the M0 repo + prove push→Vercel

M0 left a **GitHub repo** (Lovable created it) that auto-deploys to Vercel. Get it into your workspace and prove the loop, because every M1 step relies on `git push → Vercel redeploy`.

**1. Clone into a NATIVE dir** (not the FUSE-mounted workspace — git locking fails there):

ask """
>
Use the git tool to clone my project from my GitHub repo (e.g. https://github.com/<you>/flight-price-notifier).
Clone into a **native working directory** (your home dir), NOT the mounted workspace folder — git's locking fails on the FUSE mount (`config.lock: Operation not permitted`).
>
"""

> The working copy is **ephemeral** — GitHub + Vercel are the source of truth; re-clone if the sandbox resets.

**2. Get a GitHub fine-grained PAT** (so the agent can push).
> **Returning?** If you already cached your PAT in `flight/github` (Part C below), skip this — once AWS is up, tell the agent *"read my GitHub PAT from the `flight/github` secret and use it to push."* First time:
- https://github.com/settings/personal-access-tokens → **Generate new token (fine-grained)** → **Only select repositories** → this one repo → **Repository permissions → Contents → Read and write** → generate, copy `github_pat_…` (shown once).
> ⚠️ Write-credential to your repo — treat like a password; Contents:RW on the **one** repo only; revoke at course end.

**3. Round-trip test** (paste your token in place of the X's):

ask """
>
Change the site title to "Flight Price Notifier V3", push to the GitHub repo, then track the Vercel deployment and confirm the live site shows the new title.
>
Here is my GitHub Personal Access Token: XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
>
"""

**Verify:** the live Vercel site shows **"Flight Price Notifier V3"** (revert it after). That proves clone + token-push + GitHub→Vercel auto-deploy. (You'll cache this PAT in Part C so you never paste it again.)

---

## Part B — AWS access (AWS API MCP + the `[default]` profile)

Set up once for the whole course.

**B1 — Add the AWS API MCP connector (Cowork):** **Customize → Connectors → search "AWS API MCP" → Install.** (It runs every course `aws` call, reading your local `~/.aws/credentials`.)

**B2 — Create an admin IAM user + write its key to `[default]`:**
1. Sign in to the AWS Console as the **root** user of your course account.
2. **IAM → Users → Create user** (suggested `admin-for-cowork`) → attach **`AdministratorAccess`** → create.
3. That user → **Security credentials → Create access key → "CLI"** → copy the **Access key ID + Secret** (shown once).
4. **Open a Claude Code CLI session** and paste this (writes the `[default]` profile, preserving other profiles, and tests it):

   ask """
   >
   I have new AWS credentials I want to configure. Please write them to my AWS credentials file. Here are the values:
   >
   Access key ID: <YOUR_ACCESS_KEY_ID>
   >
   Secret access key: <YOUR_SECRET_ACCESS_KEY>
   >
   First detect Mac/Linux vs Windows for the correct path (~/.aws/credentials or %USERPROFILE%\.aws\credentials),
   then write the [default] profile with the new values — preserving any other existing profiles.
   >
   Once done, test the connection using aws sts get-caller-identity.
   >
   """

**Verify:** `aws sts get-caller-identity` returns an Account ID + an `Arn` ending in your admin user's name. That `sts` call is the source of truth that `[default]` is wired (always `--region us-east-1`, no `--profile`).
> ⚠️ **Root is used once** (to make the admin user); never use root keys after. Revoke the key at course end.

---

## Part C — Cache the GitHub PAT + Supabase keys in Secrets Manager

Now that AWS is up, cache the convenience keys so **no future session re-asks**. (See [[aws-best-practice]] Rule 2 — Secrets Manager is the single source of truth for every key.)

**C1 — GitHub PAT → `flight/github`** (fill the token in **once** at the top):

ask """
>
My GitHub Personal Access Token (fill this in): <REPLACE_WITH_YOUR_TOKEN>
>
Store that token in AWS Secrets Manager as the `flight/github` secret (shape: `{"pat":"<the token above>"}`) so future sessions can reuse it. Region us-east-1. Check first, then create or update:
>
```bash
aws secretsmanager describe-secret --secret-id flight/github --region us-east-1 --query "Name"
```
>
- ResourceNotFoundException → `aws secretsmanager create-secret --name flight/github --secret-string '{"pat":"<the token above>"}' --region us-east-1`
>
- already returned `flight/github` → `aws secretsmanager put-secret-value --secret-id flight/github --secret-string '{"pat":"<the token above>"}' --region us-east-1`
>
"""

**C2 — Supabase url + anon key → `flight/supabase`** (convenience cache — the anon key is public-by-design; no Lambda reads it; Supabase stays auth-only for data):

ask """
>
My Supabase URL (fill this in): https://<REPLACE>.supabase.co
>
My Supabase publishable/anon key (fill this in): <REPLACE_WITH_YOUR_ANON_KEY>
>
Cache those in AWS Secrets Manager as `flight/supabase` (shape: `{"url":"<the URL above>","anon_key":"<the key above>"}`). Region us-east-1. Check first, then create or update:
>
```bash
aws secretsmanager describe-secret --secret-id flight/supabase --region us-east-1 --query "Name"
```
>
- ResourceNotFoundException → `aws secretsmanager create-secret --name flight/supabase --secret-string '{"url":"<the URL above>","anon_key":"<the key above>"}' --region us-east-1`
>
- already returned `flight/supabase` → `aws secretsmanager put-secret-value --secret-id flight/supabase --secret-string '{"url":"<the URL above>","anon_key":"<the key above>"}' --region us-east-1`
>
"""

---

## Part D — Travelpayouts token → `flight/travelpayouts`

The fetch API authenticates on the **token** alone (no `marker`).
1. Sign up free at https://www.travelpayouts.com/ and connect the **Aviasales** program.
2. Dashboard → **Profile → API token** → copy the **token** (https://app.travelpayouts.com/profile/api-token).
> **No marker needed.** The marker (affiliate ID) only matters if you later want booking-link commission — an optional, skippable aside in M1's "monetize the booking link." Don't collect it now.

**Verify the token + store it.** The token works as a `?token=` query param, so the agent's web-fetch can check it (a GET — unlike Resend's POST, this isn't proxy-blocked):

ask """
>
My Travelpayouts API token (fill this in): <REPLACE_WITH_YOUR_TOKEN>
>
1. Verify it: fetch `https://api.travelpayouts.com/v1/prices/cheap?origin=TPE&destination=TYO&depart_date=2026-07&currency=usd&token=<the token above>` and tell me whether the JSON has `"success":true`. (It works for both currencies — `twd` too — no new secret.)
>
2. If it works, store it in AWS Secrets Manager as `flight/travelpayouts` (shape: `{"token":"<the token above>"}`). Region us-east-1. Check first:
>
```bash
aws secretsmanager describe-secret --secret-id flight/travelpayouts --region us-east-1 --query "Name"
```
>
ResourceNotFoundException → `aws secretsmanager create-secret --name flight/travelpayouts --secret-string '{"token":"<the token above>"}' --region us-east-1`
>
"""

**Expect** `"success":true` and `flight/travelpayouts` stored. (A `401`/`"success":false` = wrong token or Aviasales not connected.)

---

## Part E — Resend (the alert email) → `flight/resend` + verify from a Lambda

1. Sign up free at https://resend.com/.
2. **API Keys → Create API Key** → a **Sending-access** key is enough (the course never writes contacts/audiences) → copy `re_…`.
3. The demo sends from **`onboarding@resend.dev`** (no domain setup; verifying your own domain is M3).

> ⚠️ **The demo sender only delivers to your OWN Resend-account email** (the address you signed up to Resend with — often **NOT** your app login email). A send to any other address is accepted in the log but **never arrives**. So `test_to` below — and the M1 test subscriber's `email` — must be your **Resend-account** email. See [[resend-best-practice]] Rule 1.

**E1 — Store the secret** (`flight/resend`) — fill the two values in once at the top:

ask """
>
My Resend API key (fill this in): re_<REPLACE_WITH_YOUR_KEY>
>
My Resend-account email (fill this in — the email I signed up to Resend with): <REPLACE_WITH_YOUR_RESEND_ACCOUNT_EMAIL>
>
Store as `flight/resend` (shape: `{"api_key":"<the key above>","from":"onboarding@resend.dev","test_to":"<the email above>"}`). Region us-east-1. Check first:
>
```bash
aws secretsmanager describe-secret --secret-id flight/resend --region us-east-1 --query "Name"
```
>
ResourceNotFoundException → `aws secretsmanager create-secret --name flight/resend --secret-string '{"api_key":"<the key above>","from":"onboarding@resend.dev","test_to":"<the email above>"}' --region us-east-1`
>
"""

**E2 — Verify by sending from a throwaway Lambda** (the Cowork sandbox can't POST to `api.resend.com` — proxy-blocked; a Lambda has internet). One prompt deploys + invokes + reads the logs:

ask """
>
Create a one-off `flight-resend-test` Lambda via inline CloudFormation in us-east-1 (replace <ACCOUNT_ID>). Handler `index.handler`, Runtime python3.12, Role `arn:aws:iam::<ACCOUNT_ID>:role/flight-lambda-role`, Timeout 15. JSON-escape this code into the template's `Code.ZipFile`:
>
```python
import json, urllib.request, boto3
def handler(e, c):
    s = json.loads(boto3.client("secretsmanager").get_secret_value(SecretId="flight/resend")["SecretString"])
    body = {"from": s["from"], "to": s["test_to"], "subject": "resend test", "html": "<p>it works</p>", "text": "it works"}
    req = urllib.request.Request("https://api.resend.com/emails", data=json.dumps(body).encode(),
        headers={"Authorization": "Bearer " + s["api_key"], "Content-Type": "application/json",
                 "User-Agent": "Mozilla/5.0 (compatible; flight-notifier/1.0)"}, method="POST")  # UA: Resend is behind Cloudflare
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            print("RESEND_OK", r.status, r.read().decode())
    except urllib.error.HTTPError as ex:
        print("RESEND_ERR", ex.code, ex.read().decode())
    return {"done": True}
```
>
Then poll `aws cloudformation describe-stacks --stack-name flight-resend-test --query "Stacks[0].StackStatus" --region us-east-1` until CREATE_COMPLETE. Once ready, invoke it and show me its logs:
>
```bash
aws lambda invoke --function-name flight-resend-test --payload '{}' out.json --region us-east-1
aws logs filter-log-events --log-group-name /aws/lambda/flight-resend-test --query "events[].message" --region us-east-1
```
>
"""

> ⚠️ **This needs the `flight-lambda-role`** — which M1 Step 3 creates. If you're doing the prereq strictly before any building, either create that role now (see `m1-flight-price-checker` Step 3) or run E2 right after M1 Step 3. The role grants the test Lambda `secretsmanager:GetSecretValue` on `flight/*`.

**Expect** a log line `RESEND_OK 200 {"id":"..."}` **and** the email in your Resend-account inbox (check spam). `RESEND_ERR 401` = wrong key; `403`/`422` = a `from` you can't send from (stay on `onboarding@resend.dev` until M3); `403` body `error code: 1010` = Cloudflare blocked the UA (the handler sets one — only bites if you dropped it). Tear down when it passes: `aws cloudformation delete-stack --stack-name flight-resend-test --region us-east-1`.

---

## Verify (all must pass)

- **Project:** repo cloned; the "V3" round-trip showed on the live Vercel site (then reverted).
- **AWS:** `aws sts get-caller-identity --query Account --output text --region us-east-1` returns your account ID.
- **Secrets present:** `aws secretsmanager list-secrets --region us-east-1 --query "SecretList[].Name"` lists **`flight/travelpayouts`**, **`flight/resend`**, **`flight/github`**, **`flight/supabase`** (list-all-and-scan — backtick JMESPath filters break in the MCP).
- **Travelpayouts:** the token check returned `"success":true`.
- **Resend:** `RESEND_OK 200` + the test email arrived in your Resend-account inbox.
- **Build tools (CLI mode only):** `python3 --version && which zip` (in Cowork the sandbox has them; the `aws`-only connector itself doesn't build zips — the `flight-seed` bridge moves them to S3).

## Next step

Return to `m1-flight-price-checker` Step 1 and build all three parts.
