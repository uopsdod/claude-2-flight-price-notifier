---
name: m1-1-subscribe-to-a-plan-prerequisites
description: One-time setup before M1.1 of the Flight Price Notifier course — clone the M0 GitHub repo (into a native dir), AWS access (the AWS MCP connector, browser sign-in), and a Travelpayouts token (token only — the affiliate marker is deferred to M1.3 where it's used). Cowork-first; notes the inline-CFN deploy method. Use when the student starts M1.1 for the first time, or when `m1-1-subscribe-to-a-plan` / `-checklist` detects the project, AWS access, or the Travelpayouts token is missing.
---

# M1.1 Prerequisites — AWS + Travelpayouts

## Execution mode: Cowork (default) vs CLI

This course is run mainly in **Cowork** (no local shell — you talk to a Cowork agent that has the git tool, the AWS MCP, and a workspace). The **`ask """ ... """`** blocks below are prompts you **paste to the Cowork agent verbatim**. If you're on the local Claude CLI instead, run the equivalent shell commands directly. Every AWS command uses `--region us-east-1`.

## What this skill does

Sets up the three things M1.1 needs on top of M0's tooling:
1. **The project in your workspace** — clone the GitHub repo Lovable created in M0, and confirm the push → Vercel auto-deploy loop works end-to-end.
2. **AWS access** through the **AWS MCP** connector (browser sign-in; confirm with `sts GetCallerIdentity`).
3. A **Travelpayouts API token** (used to fetch fares — set up now, used heavily in M1.2).

Run once. M1.2/M1.3 reuse the same AWS access + the same repo.

> **Heads-up before you build (Cowork):** the AWS MCP *has* AWS access, but a zip built in the bash sandbox **can't reach it**, and AWS MCP **silently corrupts every byte ≥ `0x80`** in blob parameters. So **Lambda code is deployed as inline CloudFormation `Code.ZipFile`** (single file, ≤4096 chars, handler `index.handler`) or as an **ASCII-safe zip** (Method A in [[aws-best-practice]]) — the code travels *inside* the API call, no file transfer. The `aws lambda create-function --zip-file fileb://…` flow is **CLI-mode only**. Read [[aws-best-practice]] *Cowork execution constraints* once before M1.1 Step 4 — it's the difference between a smooth run and an hour of silently corrupted zips.

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

**2. Get a GitHub Personal Access Token** so the agent can push back:
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

> **Why this matters:** every later milestone edits this repo (the subscribe form in M1.1, etc.) and relies on `git push → Vercel redeploy`. If that loop is broken, nothing you build after will reach the live site — so prove it here, once.

## Step 1 — AWS access (AWS MCP connector, browser sign-in)

This is the AWS setup for the whole course. AWS MCP signs you in through your browser (OAuth): **no IAM user, no access key, no `~/.aws/credentials`, no Claude Code CLI session.**

### 1a — Connect the AWS MCP connector (Cowork)

1. Make sure you can sign in to the course AWS account as the **root user** (the email + password you signed up with).
2. Cowork → **Customize → Connectors**. If **AWS API MCP** is installed, **disable** it (the old access-key connector — don't run both).
3. **Add → AWS MCP**, server URL: `https://aws-mcp.us-east-1.api.aws/mcp?oauth=initialize`
4. **Continue → Add → Connect → Continue** → wait for **Connecting…**
5. **Sign into new session** → a browser window opens → sign in as the **root user**.
6. When Cowork shows **Needs approval** → **Always allow**.

### 1b — Verify

Ask the agent: *"How many IAM users do I have now on my AWS account?"* — a number (0 is normal on a fresh account) means the connector works. The agent can also run `sts GetCallerIdentity` (`region_name="us-east-1"`) and show the Account ID. If Claude says the AWS tool isn't available or the sign-in expired, redo steps 4–6. Every course AWS call pins `us-east-1`.

> At course end there's no key to revoke — remove the AWS MCP connector in Customize → Connectors. If you created an IAM user + access key for the old AWS API MCP, deactivate and delete that key once AWS MCP works.

ste this to the agent (swap in your token):

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
