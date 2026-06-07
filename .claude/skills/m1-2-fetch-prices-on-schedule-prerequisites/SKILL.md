---
name: m1-2-fetch-prices-on-schedule-prerequisites
description: Prerequisites before M1.2 of the Flight Price Notifier course — confirms M1.1's AWS role + secrets + the DynamoDB tables exist and the Travelpayouts token is valid before building the scheduled parser_wrapper/parser pipeline (S3 routes + fare SQS). Use when the student starts M1.2, or when `m1-2-fetch-prices-on-schedule` / `-checklist` detects a missing dependency.
---

# M1.2 Prerequisites — confirm M1.1 carryover

## What this skill does

M1.2 adds **no new accounts** — it reuses M1.1's AWS access (`[default]` profile), the `flight-lambda-role`, the `flight/travelpayouts` secret, and the DynamoDB `subscriptions` + `notification_history` tables. M1.2 *creates* the S3 routes config + the fare SQS queue and *extends* the role with S3/SQS/InvokeFunction perms — this skill just confirms the M1.1 carryover is in place and the Travelpayouts token still works.

## When to load this skill

- "M1.2 環境準備" / any time M1.2 detects a missing role/secret/token.

## Execution mode: Cowork (default) vs CLI

This runs mainly in **Cowork** — paste the checks to the agent with the **AWS API MCP** (it runs each `aws` call). On the local CLI, run them directly. Every `aws` command uses `--region us-east-1` and the `[default]` profile (**no `--profile`**). Note: through the MCP, `--query` must **not** use JMESPath backtick literals (they fail to parse) — the queries below avoid them.

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

**Build tools** (CLI mode only — in Cowork the MCP builds the zip in its own workdir, so you don't need local `zip`): `python3 --version && which zip`.

- If (1) fails → redo `m1-1-subscribe-to-a-plan-prerequisites` Step 1.
- If (2)/(3)/(4) fail → redo M1.1 Steps 1–3.
- If the token check fails → regenerate it (Travelpayouts → Profile → API token) and update the secret: `aws secretsmanager put-secret-value --secret-id flight/travelpayouts --secret-string '{"token":"<NEW_TOKEN>"}' --region us-east-1`.

## Next step

Return to `m1-2-fetch-prices-on-schedule` Step 1.
