---
name: m1-1-subscribe-to-a-plan-prerequisites
description: One-time setup before M1.1 of the Flight Price Notifier course — clone the M0 GitHub repo (into a native dir), AWS access (the `[default]` profile via an admin IAM user), and a Travelpayouts token (token only — the notifier never needs the affiliate marker). Cowork-first; notes the inline-CFN deploy method. Use when the student starts M1.1 for the first time, or when `m1-1-subscribe-to-a-plan` / `-checklist` detects the project, AWS access, or the Travelpayouts token is missing.
---

# M1.1 Prerequisites — AWS + Travelpayouts

## Execution mode: Cowork (default) vs CLI

This course is run mainly in **Cowork** (no local shell — you talk to a Cowork agent that has the git tool, the AWS MCP, and a workspace). The **`ask """ ... """`** blocks below are prompts you **paste to the Cowork agent verbatim**. If you're on the local Claude CLI instead, run the equivalent shell commands directly. Every AWS command uses `--region us-east-1`.

## What this skill does

Sets up the three things M1.1 needs on top of M0's tooling:
1. **The project in your workspace** — clone the GitHub repo Lovable created in M0, and confirm the push → Vercel auto-deploy loop works end-to-end.
2. **AWS access** under the `[default]` profile (an admin IAM user you create; name can differ — confirm with `aws sts get-caller-identity`).
3. A **Travelpayouts API token** (used to fetch fares — set up now, used heavily in M1.2).

Run once. M1.2/M1.3 reuse the same AWS access + the same repo.

> **Heads-up before you build (Cowork):** the AWS API MCP *has* AWS creds + network, but a built **zip can't cross from the bash/build host into the MCP's workdir** (`fileb://…` only reads the MCP's own dir). So **Lambda code is deployed as inline CloudFormation `Code.ZipFile`** (single file, ≤4096 chars, handler `index.handler`) — the code travels *inside* the API call, no file transfer. The `aws lambda create-function --zip-file fileb://…` flow is **CLI-mode only**. Read [[aws-best-practice]] *Cowork execution constraints* once before M1.1 Step 4 — it's the difference between a smooth run and an hour of "outside allowed working directory" errors.

## Flow structure (where M1.1 sits)

M1.1 builds the **Product Site → Subscriptions [DynamoDB]** path. This prereq gets the **repo loop** (bottom strip) and AWS access ready so you can build it.

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
   │   (Parser / EventBridge / S3 side of this box = M1.2)          │
   └────────────────────────────────────────────────────────────────┘

   Legend:  ▮ orange = manual input   ▮ teal = main component   ▮ pink = user data
   Repo loop:   Landing Page (Lovable) ──▶ Repo (GitHub) ──R──▶ Product Site (Vercel)
```

## When to load this skill

- "M1.1 環境準備" / "setup AWS for the flight course"
- Any time M1.1 detects AWS or Travelpayouts is missing.

## Set up project

M0 left you with a **GitHub repo** (Lovable created it) that auto-deploys to Vercel. From M1.1 on you'll be adding an AWS backend to that same project, so first get the code into your Cowork workspace and prove the **push → auto-deploy** loop works.

**1. Clone the M0 repo.** Paste this to the Cowork agent (swap in your own repo URL — the one Lovable created in M0):

ask """
>
Use the git tool to clone my project from my GitHub repo (e.g. https://github.com/<you>/flight-price-notifier).
Clone into a **native working directory** (your home dir), NOT the mounted workspace folder — git's locking fails on the FUSE mount (`config.lock: Operation not permitted`).
>
"""

> The working copy is **ephemeral** — **GitHub + Vercel are the source of truth.** If the sandbox resets, just re-clone. (See [[aws-best-practice]] *Cowork execution constraints* #5.)

**2. Get a GitHub Personal Access Token** so the agent can push back.

> **Returning to the course?** If you already stored your PAT in `flight/github` on a previous run, you **don't need a new one** — once AWS is up (Step 1 below) the agent can recall it: paste *"Read my GitHub PAT from the `flight/github` secret and use it to push."* Skip to step 3. First time through, create one:

- Go to https://github.com/settings/personal-access-tokens → **Generate new token (fine-grained)**.
- **Repository access → Only select repositories** → pick this one repo.
- **Permissions → Repository permissions → Contents → enable `Read and write`**.
- Generate and copy the token (`github_pat_...`). It's shown once.

> ⚠️ The token grants write access to this repo. Treat it like a password: don't commit it, don't paste it into a public place. It only needs **Contents: Read/Write** on **this one repo** — nothing else. Revoke it when the course is done.

**3. Run the round-trip test.** Paste this to the Cowork agent (paste your real token in place of the X's):

ask """
>
Now, let's do a test. Change the site title to "Flight Price Notifier V3". Then push to the GitHub repo.
>
Once done, track the Vercel deployment for me. Then check the final Vercel-deployed site to confirm the title changed.
>
Here is my GitHub Personal Access Token: XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX
>
"""

**Verify:** the live Vercel site shows the title **"Flight Price Notifier V3"** after the agent pushes and the deploy finishes. That proves: the repo is cloned, the token can push, and GitHub → Vercel auto-deploy is wired. (Change the title back to "Flight Price Notifier" when you're done testing.)

> **Store it once, never paste it again.** As soon as AWS is set up (Step 1), save the PAT to Secrets Manager so every future session recalls it instead of asking you to re-paste — see Step 1c.

> **Why this matters:** every later milestone edits this repo (the subscribe form in M1.1, etc.) and relies on `git push → Vercel redeploy`. If that loop is broken, nothing you build after will reach the live site — so prove it here, once.

## Step 1 — AWS access (AWS API MCP + the `[default]` profile)

This is the AWS setup for the whole course. Two parts: **install the connector**, then **write credentials** (via a one-time Claude Code CLI session — the Cowork AWS API MCP then reads them).

### 1a — Add the AWS API MCP connector (Cowork)

> **Customize → Connectors → search "AWS API MCP" → Install.**

This is the tool Cowork uses to run every `aws` call in the course (it reads your local `~/.aws/credentials`).

### 1b — Create an admin IAM user + write its key to the `[default]` profile

1. **Sign in to the AWS Console as the *root* user** of your course AWS account (e.g. email `uops...@gmail.com`).
2. **IAM → Users → Create user** (suggested name **`admin-for-cowork`** — any name is fine) → attach the **`AdministratorAccess`** policy → create.
3. That user → **Security credentials → Create access key → "Command Line Interface (CLI)"** → copy the **Access key ID + Secret access key** (shown **once**).
4. **Open a Claude Code CLI session** (指令版) and paste this — it writes the `[default]` profile to `~/.aws/credentials` (preserving any other profiles) and tests the connection:

   ask """
   >
   I have new AWS credentials I want to configure. Please write them to my AWS credentials file. Here are the values:
   >
   Access key ID: <YOUR_ACCESS_KEY_ID>
   >
   Secret access key: <YOUR_SECRET_ACCESS_KEY>
   >
   First, detect whether I'm on Mac/Linux or Windows to determine the correct credentials file path
   (~/.aws/credentials on Mac/Linux, %USERPROFILE%\.aws\credentials on Windows),
   then write the [default] profile with the new values — preserving any other existing profiles in the file.
   >
   Once done, test the connection using aws sts get-caller-identity.
   >
   """

**Verify:** `aws sts get-caller-identity` returns an Account ID and an `Arn` ending in **your admin user's name** (whatever you named it). That `sts` call — not a hardcoded name — is the source of truth that the `[default]` profile is wired. After this, the Cowork AWS API MCP can run every course `aws` command (always with `--region us-east-1` — no `--profile` needed, it's `[default]`).

> ⚠️ **Root is used only once** — to create the admin IAM user. After that, never use root keys. The access key is shown **once**; if you lose it, delete it and make a new one. **Revoke that key when the course ends.** The `[default]` profile has no region, which is why every course command pins `--region us-east-1`.

### 1c — Store the GitHub PAT in Secrets Manager (so you never re-paste it)

Now that AWS is up, save the PAT from "Set up project" step 2 — once stored, every future Cowork session recalls it instead of asking you again. Paste to the agent (fill your token in **once** at the top):

ask """
>
My GitHub Personal Access Token (fill this in): <REPLACE_WITH_YOUR_TOKEN>
>
Store that token in AWS Secrets Manager as the `flight/github` secret (shape: `{"pat":"<the token above>"}`) so future Cowork sessions can reuse it. Region us-east-1. Check whether it exists first, then create or update:
>
```bash
aws secretsmanager describe-secret --secret-id flight/github --region us-east-1 --query "Name"
```
>
- If that errors with ResourceNotFoundException → `aws secretsmanager create-secret --name flight/github --secret-string '{"pat":"<the token above>"}' --region us-east-1`
>
- If it already returned `flight/github` → `aws secretsmanager put-secret-value --secret-id flight/github --secret-string '{"pat":"<the token above>"}' --region us-east-1`
>
Then confirm it stored (show me only the name, not the value):
>
```bash
aws secretsmanager describe-secret --secret-id flight/github --region us-east-1 --query "Name"
```
>
"""

> From now on, when a milestone needs to push, tell the agent *"use my GitHub PAT from the `flight/github` secret"* — no re-pasting. (It's a write-credential, so it lives in Secrets Manager like every other key — see [[aws-best-practice]] Rule 2.)

### 1d — Cache your Supabase url + anon key in `flight/supabase`

Save the two Supabase values from M0 (`VITE_SUPABASE_URL` + the publishable/anon key) so a future session recalls them. The anon key is **public by design**, so this is a convenience cache, not a runtime secret (no Lambda reads it — Supabase stays auth-only for data). Paste to the agent (fill the two values in **once** at the top):

ask """
>
My Supabase URL (fill this in): https://<REPLACE>.supabase.co
>
My Supabase publishable/anon key (fill this in): <REPLACE_WITH_YOUR_ANON_KEY>
>
Cache those two values in AWS Secrets Manager as the `flight/supabase` secret (shape: `{"url":"<the URL above>","anon_key":"<the key above>"}`) so future sessions can recall them. Region us-east-1. Check first, then create or update:
>
```bash
aws secretsmanager describe-secret --secret-id flight/supabase --region us-east-1 --query "Name"
```
>
- If ResourceNotFoundException → `aws secretsmanager create-secret --name flight/supabase --secret-string '{"url":"<the URL above>","anon_key":"<the key above>"}' --region us-east-1`
>
- If it already returned `flight/supabase` → `aws secretsmanager put-secret-value --secret-id flight/supabase --secret-string '{"url":"<the URL above>","anon_key":"<the key above>"}' --region us-east-1`
>
"""

## Step 2 — Travelpayouts token

The whole course needs only the **token** — the fetch API authenticates on it alone.

1. Sign up free at https://www.travelpayouts.com/ and connect the **Aviasales** program.
2. Dashboard → **Profile → API token** → copy the **token**. (https://app.travelpayouts.com/profile/api-token)
3. (You'll store it as `{"token":…}` in the `flight/travelpayouts` secret during M1.1 Step 2.)

> **No marker needed.** Travelpayouts also gives you a **marker** (affiliate ID, e.g. `736582`), but the notifier never requires it — fetching fares and deciding whom to email both authenticate on the token alone. The marker only matters if you later want the booking link in the alert email to earn you commission; that's an *optional* add-on covered as a skippable aside in M1.3 (`m1-3-email-on-target` → "Optional: monetize the booking link"). Don't collect it now.

**Verify the token works** — the API accepts the token as a `token=` query param, so it's checkable without a shell:

- **Cowork** (no CLI) — paste this to the agent (swap in your token):

  ask """
  >
  Fetch this URL and tell me whether the JSON has "success":true (it's a Travelpayouts token check):
  >
  https://api.travelpayouts.com/v1/prices/cheap?origin=TPE&destination=TYO&depart_date=2026-07&currency=usd&token=<YOUR_TOKEN>
  >
  """

  (Or just paste that URL into a browser — if you see `"success":true`, the token is good.)

- **CLI:**
  ```bash
  curl -s "https://api.travelpayouts.com/v1/prices/cheap?origin=TPE&destination=TYO&depart_date=2026-07&currency=usd&token=<YOUR_TOKEN>" | head -c 200
  ```

**Expect** JSON containing `"success":true`. (A `401` / `"success":false` means the token is wrong or the Aviasales program isn't connected yet.)

## Step 3 — Lambda packaging deps

The Lambdas use a shared layer (`stripe` + `requests`, both pure-Python). The zip is built wherever your agent/terminal runs, so `python3` + `pip` + `zip` need to be available there.

- **Cowork** — the **Cowork agent's workspace** builds the zip (it already has python/pip/zip), so there's nothing for you to install. You can confirm with the agent:

  ask """
  >
  In the workspace, run: python3 --version && pip3 --version && which zip — and show me the output.
  >
  """

- **CLI:**
  ```bash
  python3 --version && pip3 --version && which zip
  ```

(`travelpayouts.py` and `email_render.py` are stdlib-only, so they need no deps — they're copied straight into the zip.)

## Verify (all must pass)

- **Project:** the M0 repo is cloned in the workspace, and the "V3" round-trip showed up on the live Vercel site (then reverted).
- **AWS:** `sts get-caller-identity` returns your account ID (via the AWS MCP in Cowork, or `aws ...` in CLI).
- **Travelpayouts:** the Step 2 token check returns JSON `"success":true`.
- **Build tools:** `python3` + `pip` + `zip` are available in your build environment.

## Next step

Return to `m1-1-subscribe-to-a-plan` Step 1.
