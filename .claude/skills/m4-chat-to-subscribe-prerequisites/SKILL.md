---
name: m4-chat-to-subscribe-prerequisites
description: Prerequisites before M4 of the Flight Price Notifier course (self-hosted OpenClaw on EC2 as a 24h Telegram customer-service bot) — the student creates the Telegram bot in @BotFather and pastes its token (and an LLM key if `flight/llm` is missing) to the agent, which stores them in Secrets Manager; then confirm the AWS account can launch a small EC2 instance and that the M1–M3 pieces the bot reuses exist. Use when the student says "M4 環境準備", starts M4, or when `m4-chat-to-subscribe` / `-checklist` detects a missing secret.
---

# M4 Prerequisites — Telegram bot, LLM key, EC2 readiness

## What this skill does

M4 puts a real AI customer-service agent on Telegram. It runs **OpenClaw** (open-source AI agent gateway) on one small **EC2** instance. The bot answers routes, pricing and live fares, and sends anyone who wants to subscribe or cancel to the website.

This skill gets three things ready:

| # | Thing | Who does it | Where it ends up |
|---|---|---|---|
| 1 | Telegram bot token + username | Student gets them in @BotFather and pastes them to the agent | Secret `flight/telegram` (agent creates it) |
| 2 | LLM API key (OpenAI or Anthropic) with billing | Student creates it and pastes it to the agent (skip if `flight/llm` exists) | Secret `flight/llm` (agent creates it) |
| 3 | EC2 readiness + M1–M3 carryover | Agent, read-only checks | Nothing new |

> **Secrets rule:** same as M1/M2. The student pastes the token/key to the agent once; the agent stores it in Secrets Manager right away and never puts it in code, the repo, the front-end, or an EC2 file other than the mode-600 `.env` the gateway reads. Never echo a token or key back to the student. Tell the student, once: 「貼給 AI 的 token 和 key 會留在這次對話紀錄裡，對話不要分享給別人；之後如果外流，到 @BotFather `/revoke` 或供應商後台換一把新的，再請 AI 更新即可。」

## When to load this skill

- 「M4 環境準備」, 「啟動 M4」 before the build, or any time M4 finds `flight/telegram` or `flight/llm` missing.

## Execution mode

CLI uses `aws`; Cowork uses the AWS MCP. All `aws` commands `--region us-east-1`. Nothing here creates billable resources.

## Step 1 — Telegram bot (student gets the token, agent stores it)

**⚠️ Tell the student (imperatively):**
1. 在 Telegram 搜尋 **@BotFather**（確認帳號名稱完全一樣）。
2. 傳 `/newbot`，依序輸入顯示名稱（例如「機票通知客服」）和 username（必須以 `bot` 結尾，例如 `flight_helper_tw_bot`）。
3. BotFather 會回一串 token（長得像 `123456789:AA…`）。把 **token 和 bot 的 username** 一起貼給 AI。

Then the agent stores it (create, or overwrite if it already exists):
```bash
aws secretsmanager create-secret --name flight/telegram --region us-east-1 \
  --secret-string '{"bot_token":"<TOKEN>","username":"<USERNAME without @>"}' \
 || aws secretsmanager put-secret-value --secret-id flight/telegram --region us-east-1 \
  --secret-string '{"bot_token":"<TOKEN>","username":"<USERNAME without @>"}'
```
A token looks like digits, a colon, then about 35 letters/digits/`_`/`-`. If what the student pasted doesn't match, ask them to copy it again from BotFather.

**Verify (agent):** `aws secretsmanager describe-secret --secret-id flight/telegram --region us-east-1 --query Name`. The token itself is proven from the instance in the build (Step 4e `channels status --probe`).

## Step 2 — LLM key in `flight/llm`

Check first — a student who built the web chat widget already has it:
```bash
aws secretsmanager describe-secret --secret-id flight/llm --region us-east-1 --query Name
```
If it exists, skip to Step 3 (the bot reuses the same key and model). If not:

| provider | Get a key at | Suggested model | Note |
|---|---|---|---|
| `openai` | platform.openai.com → API keys | `gpt-5.4-mini` | Add prepaid credit under Billing first, or every call fails with `429 insufficient_quota`. |
| `anthropic` | console.anthropic.com → API Keys | `claude-haiku-5-5` | Add credit under Billing first. |

**⚠️ Tell the student (imperatively):** 到供應商後台先儲值，再建立一把 API key（名稱 `flight-openclaw`），把 key、供應商（openai 或 anthropic）和一個客服信箱一起貼給 AI。客服信箱是 bot 答不了時請使用者寫信的地址。

Then the agent stores it:
```bash
aws secretsmanager create-secret --name flight/llm --region us-east-1 \
  --secret-string '{"provider":"openai","api_key":"<KEY>","model":"gpt-5.4-mini","support_email":"<EMAIL>"}'
```
(Anthropic: `"provider":"anthropic"`, `"model":"claude-haiku-5-5"`.)

**Verify (agent):** `describe-secret` as above. The key itself is proven from the instance (build Step 5).

## Step 3 — EC2 readiness (agent, read-only)

```bash
# a default VPC with public subnets (the instance needs outbound internet; no NAT gateway needed)
aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query "Vpcs[].VpcId" --region us-east-1
aws ec2 describe-subnets --filters Name=default-for-az,Values=true --query "Subnets[].[SubnetId,AvailabilityZone,MapPublicIpOnLaunch]" --region us-east-1
# t3.small is offered in this region
aws ec2 describe-instance-type-offerings --filters Name=instance-type,Values=t3.small --query "InstanceTypeOfferings[].Location" --region us-east-1
# On-Demand Standard vCPU quota (t3.small needs 2)
aws service-quotas get-service-quota --service-code ec2 --quota-code L-1216C47A --query "Quota.Value" --region us-east-1
```
- No default VPC → `aws ec2 create-default-vpc --region us-east-1` (only if the student agrees; it is free).
- vCPU quota below 2 (rare, but some new accounts are capped low) → only then does the student request an increase in Service Quotas (EC2 → "Running On-Demand Standard (A, C, D, H, I, M, R, T, Z) instances", value 8). New accounts are sometimes capped low; approval can take hours.

## Step 4 — M1–M3 carryover (agent, read-only)

The bot reuses what earlier milestones built:

```bash
aws apigatewayv2 get-apis --region us-east-1 --query "Items[].[Name,ApiId,ApiEndpoint]"
aws apigatewayv2 get-routes --api-id <ApiId> --region us-east-1 --query "Items[].RouteKey"
aws s3 cp s3://flight-config-<ACCOUNT_ID>/flight-routes.json - --region us-east-1
aws secretsmanager describe-secret --secret-id flight/travelpayouts --region us-east-1 --query Name
```
Note down:
- **`API_BASE`** = the flight API's `ApiEndpoint`.
- Whether **`GET /prices`** already exists. If not, the build's Step 1 adds it (a small Lambda that reads Travelpayouts live).
- **`SITE_URL`** = the M3 custom domain (e.g. `https://fly.yourdomain.com`), or the Vercel URL if M3 isn't done.
- The routes in `flight-routes.json` and the monthly price shown on the site's plan cards.

## Cost (tell the student before the build)

| Item | Approx. cost (us-east-1) |
|---|---|
| EC2 t3.small, always on | about US$15 / month |
| EBS gp3 20 GB | about US$1.6 / month |
| Public IPv4 address | about US$3.6 / month |
| LLM usage | a few US$ / month at low traffic |
| Telegram, OpenClaw | free |

Stopping the instance stops the compute charge (the disk and IP still bill). Deleting everything is in the build skill's "Tear down" section.

## Done when

- `flight/telegram` exists (token + username) ✅
- `flight/llm` exists ✅
- Default VPC + quota OK for one t3.small ✅
- `API_BASE`, `SITE_URL`, routes, monthly price noted; you know whether `GET /prices` exists ✅

Then load **[[m4-chat-to-subscribe]]**.
