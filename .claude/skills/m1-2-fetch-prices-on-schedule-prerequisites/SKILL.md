---
name: m1-2-fetch-prices-on-schedule-prerequisites
description: Prerequisites before M1.2 of the Flight Price Notifier course — confirms M1.1's AWS role + secrets + the DynamoDB tables exist and the Travelpayouts token is valid before building the scheduled parser_wrapper/parser pipeline (S3 routes + fare SQS). Use when the student starts M1.2, or when `m1-2-fetch-prices-on-schedule` / `-checklist` detects a missing dependency.
---

# M1.2 Prerequisites — confirm M1.1 carryover

## What this skill does

M1.2 adds **no new accounts** — it reuses M1.1's AWS access (`[default]` profile), the `flight-lambda-role`, the `flight/travelpayouts` secret, and the DynamoDB `subscriptions` + `notification_history` tables. M1.2 *creates* the S3 routes config + the fare SQS queue and *extends* the role with S3/SQS/InvokeFunction perms — this skill just confirms the M1.1 carryover is in place and the Travelpayouts token still works.

## Flow structure (where M1.2 sits)

M1.2 builds the **EventBridge → Parser Wrapper → Parser** pipeline (teal) that reads **Flight Routes [S3]** (orange, admin-edited), fetches fares from **Travelpayouts** (grey), and scans the **Subscriptions [DynamoDB]** table M1.1 filled (pink) — enqueueing matches for M1.3. This prereq confirms the M1.1 carryover (role, secret, tables) that pipeline depends on.

```
 ┌──── Flight Fare Checker ──────────────────────────────────────────────────┐
 │                   ┌────────────────────────┐    1. subscriber             │
 │                   │  Subscriptions         │    2. target price           │
 │                   │  [DynamoDB] (M1.1)     │◀───(Scan per route)──┐        │
 │                   └────────────────────────┘                     │        │
 │   ┌──────────┐     ┌────────────────┐         ┌──────────────────┴──┐     │
 │   │  Event   │────▶│  Parser        │────────▶│  Parser  (×N routes) │     │
 │   │  Bridge  │ 30m │  Wrapper  λ    │ invoke  │          λ  λ  λ      │     │
 │   └──────────┘     └───────┬────────┘  /route └─────────┬───────────┘     │
 │              admin ✈ ──▶   ▼ (read routes)              ▲ fetch cheapest   │
 │                   ┌────────────────┐         ┌──────────┴───────────┐     │
 │                   │ Flight Routes  │         │ 3rd-party Parser API │     │
 │                   │ [S3]           │         │ [travelpayouts] 🐞   │     │
 │                   └────────────────┘         └──────────────────────┘     │
 │   each match → SQS flight-fare-queue ─▶ M1.3 (dedup + email)              │
 └────────────────────────────────────────────────────────────────────────────┘

 Legend:  ▮ orange = manual input (admin)   ▮ teal = main component (λ)
          ▮ pink = user data (DynamoDB)     ▮ grey = 3rd-party / shared Lambda
```

## When to load this skill

- "M1.2 環境準備" / any time M1.2 detects a missing role/secret/token.

## Execution mode: Cowork (default) vs CLI

This runs mainly in **Cowork** — paste the checks to the agent with the **AWS API MCP** (it runs each `aws` call). On the local CLI, run them directly. Every `aws` command uses `--region us-east-1` and the `[default]` profile (**no `--profile`**). Note: through the MCP, `--query` must **not** use JMESPath backtick literals (they fail to parse) — the queries below avoid them.

## Connector-capability probe (do this first — the deploy path branches on it)

M1.2 is the first milestone that ships a Lambda **zip**, and *how you get that zip into S3* depends on what your Cowork AWS connector can do. Find out now, not mid-build:

ask """
>
Two quick questions about your environment so I pick the right deploy path:
>
1. Can you author a file and run shell tools like `zip` in a working directory you control, or can you ONLY run `aws ...` commands?
>
2. Try `aws logs tail --help` — does it work, or is `tail` rejected as an unknown operation?
>
"""

- **`aws`-only connector (the common case — `logs tail` rejected, no file authoring):** you'll use the **`flight-seed` base64→S3 bridge** (main skill Step 3). The **bash sandbox builds the zip** (needs `zip`), the bridge moves it to S3.
- **Connector with a writable shell workdir (rare):** you *may* `zip` + `aws s3 cp` directly — but the bridge works in both, so when unsure, use it.

This one check is the difference between a smooth Step 3 and discovering the wall mid-deploy. (See [[aws-best-practice]] *Cowork execution constraints* → Method 2.)

## Verify (all must pass — fix via the noted M1.1 step if any fail)

Paste to the Cowork agent (or run each `aws` line yourself in CLI mode):

ask """
>
Run these M1.1-carryover checks in us-east-1 and show me each result:
>
1. AWS access: `aws sts get-caller-identity --query Account --output text --region us-east-1`
>
2. Lambda role exists: `aws iam get-role --role-name flight-lambda-role --query "Role.RoleName" --region us-east-1`
>
3. Secrets exist: `aws secretsmanager list-secrets --region us-east-1 --query "SecretList[].Name"` — expect `flight/travelpayouts` in the list (no `flight/supabase`).
>
4. Both DynamoDB tables ACTIVE: `aws dynamodb describe-table --table-name subscriptions --region us-east-1 --query "Table.TableStatus"` and the same for `notification_history`.
>
"""

> Note the queries use `"Role.RoleName"` / `"SecretList[].Name"` with **no backticks** — the backtick form (`SecretList[?starts_with(Name,\`flight/\`)]`) errors through the MCP. Just eyeball the full name list.

**Travelpayouts token still works** — the fetch API accepts the token as a `?token=` query param, so it's checkable without a shell. Paste to the agent (swap in your token):

ask """
>
Fetch this URL and tell me whether the JSON has "success":true (Travelpayouts token check):
>
https://api.travelpayouts.com/v1/prices/cheap?origin=TPE&destination=TYO&depart_date=2026-07&currency=usd&token=<YOUR_TOKEN>
>
"""

> *(CLI: `curl -s "https://api.travelpayouts.com/v1/prices/cheap?origin=TPE&destination=TYO&depart_date=2026-07&currency=usd&token=<token>" | head -c 200` → expect `"success":true`.)*

**Build tools** — M1.2 ships a Lambda zip, and **Cowork builds it in the bash sandbox** (the `aws`-only connector can't `zip`), then moves it to S3 via the `flight-seed` bridge. So you **do** need `zip` available in the sandbox: `python3 --version && which zip`. (Only a connector that exposes its own writable shell workdir could skip the sandbox — see the capability probe above.)

- If (1) fails → redo `m1-1-subscribe-to-a-plan-prerequisites` Step 1.
- If (2)/(3)/(4) fail → redo M1.1 Steps 1–3.
- If the token check fails → regenerate it (Travelpayouts → Profile → API token) and update the secret: `aws secretsmanager put-secret-value --secret-id flight/travelpayouts --secret-string '{"token":"<NEW_TOKEN>"}' --region us-east-1`.

## Next step

Return to `m1-2-fetch-prices-on-schedule` Step 1.
