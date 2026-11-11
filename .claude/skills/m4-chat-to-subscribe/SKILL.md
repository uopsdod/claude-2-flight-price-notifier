---
name: m4-chat-to-subscribe
description: Flight Price Notifier Milestone 4 — self-host OpenClaw on one EC2 instance as a 24-hour AI customer-service bot on Telegram. It answers routes, pricing and live fares (from GET /prices) and sends anyone who wants to subscribe or cancel to the website. Built entirely through the AWS API (IAM role, security group with no inbound ports, EC2, SSM Run Command); keys live in Secrets Manager and are pulled by the instance. This skill does the SETUP; verification is m4-chat-to-subscribe-checklist. Use when the student says "啟動 M4", "start M4", "做 Telegram 客服", "自架 OpenClaw".
---

# M4 — 24h AI customer service on Telegram (OpenClaw on EC2)

## What this skill builds

```
Telegram user ──DM──▶ Telegram Bot API ◀──long polling── EC2 t3.small (no inbound ports)
                                                         └─ systemd: openclaw-gateway
                                                              ├─ persona: AGENTS.md / SOUL.md
                                                              ├─ model: flight/llm (OpenAI or Anthropic)
                                                              └─ one tool: web_fetch ──▶ GET {API_BASE}/prices
Subscribe / cancel / pay ──▶ "please go to {SITE_URL}"  (ECPay flow from M2, unchanged)
```

- **OpenClaw** is an open-source gateway that connects chat apps (Telegram, WhatsApp, Discord…) to an LLM, with a persona, skills and tools. We run it as a public customer-service agent.
- The gateway **pulls** messages from Telegram (long polling), so the instance needs **no open inbound port**. The agent manages it through **SSM Run Command**, so there is no SSH key either.
- The bot is **public** (`dmPolicy: "open"`): any Telegram user can talk to it. That is why its tools are cut down to one read-only `web_fetch`. It cannot run commands, read or write files, browse, or change its own config.
- The bot cannot see who the user is on the website, so it never handles subscriptions or payments itself. It links to the site.

End state: the student DMs the bot from their own (never-paired) Telegram account and gets a correct, Chinese, plain-text answer with a live fare.

## Prerequisites

[[m4-chat-to-subscribe-prerequisites]] done: `flight/telegram` and `flight/llm` exist, EC2 quota OK, and you have noted `API_BASE`, `SITE_URL`, the routes, the monthly price, and whether `GET /prices` exists.

## Execution mode

Everything goes through the AWS API: `aws` in CLI mode, the AWS MCP in Cowork. All commands `--region us-east-1`. Files go onto the instance inside SSM `AWS-RunShellScript` commands (base64 in the command, decoded on the instance), so the student never opens a terminal on the server.

Assets in this skill (`assets/`):

| File | Goes to | Purpose |
|---|---|---|
| `ec2/bootstrap.sh` | run once as root | Node 24, `openclaw`, AWS CLI, 2 GB swap |
| `ec2/flight-openclaw-secrets` | `/usr/local/bin/` | copies the keys from Secrets Manager into `~ubuntu/.openclaw/.env` (mode 600) before each start |
| `ec2/openclaw-gateway.service` | `/etc/systemd/system/` | starts the gateway on boot as `ubuntu`, restarts on failure |
| `ec2/configure.sh` | run as `ubuntu` | non-interactive onboarding, model, Telegram channel, tool lockdown |
| `workspace/AGENTS.md`, `workspace/SOUL.md` | `~ubuntu/.openclaw/workspace/` | the customer-service persona and rules (fill the `{{…}}` placeholders) |
| `flight-latest-prices/index.py` | Lambda (only if `GET /prices` is missing) | live cheapest TWD fare per route, 10-minute cache |

## Step 1 — Make sure `GET /prices` exists

If the prerequisites found a `GET /prices` route, skip this step. Otherwise create the Lambda from `assets/flight-latest-prices/index.py` the same way earlier milestones deployed Lambdas (zip → S3 `flight-config-<ACCOUNT_ID>/lambda/m4/flight-latest-prices.zip` → check ETag == local md5 → create from S3):

```bash
aws lambda create-function --function-name flight-latest-prices --runtime python3.12 --handler index.handler \
  --role arn:aws:iam::<ACCOUNT_ID>:role/flight-lambda-role --timeout 30 \
  --environment 'Variables={CONFIG_BUCKET=flight-config-<ACCOUNT_ID>}' \
  --code S3Bucket=flight-config-<ACCOUNT_ID>,S3Key=lambda/m4/flight-latest-prices.zip --region us-east-1
aws apigatewayv2 create-integration --api-id <ApiId> --integration-type AWS_PROXY --payload-format-version 2.0 \
  --integration-uri arn:aws:lambda:us-east-1:<ACCOUNT_ID>:function:flight-latest-prices --region us-east-1
aws apigatewayv2 create-route --api-id <ApiId> --route-key "GET /prices" --target integrations/<IntegrationId> --region us-east-1
aws lambda add-permission --function-name flight-latest-prices --statement-id apigw-prices --action lambda:InvokeFunction \
  --principal apigateway.amazonaws.com --source-arn "arn:aws:execute-api:us-east-1:<ACCOUNT_ID>:<ApiId>/*/*/prices" --region us-east-1
```
`flight-lambda-role` already reads `flight/travelpayouts` and the config bucket from M1.

**Verify:** `curl -s "<API_BASE>/prices?t=$(date +%s)"` returns `{"items":[{"route":"TPE-TYO","price":…,"currency":"TWD",…},…]}` with one item per route. (Add the `?t=` cache-buster; some sandboxes' proxies cache GETs.)

## Step 2 — IAM role for the instance

The instance needs two things: to be managed by SSM, and to read **only** its two secrets.

```bash
aws iam create-role --role-name flight-openclaw-role --assume-role-policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}'
aws iam attach-role-policy --role-name flight-openclaw-role --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam put-role-policy --role-name flight-openclaw-role --policy-name flight-openclaw-secrets --policy-document \
  '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"secretsmanager:GetSecretValue","Resource":["arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:flight/llm-*","arn:aws:secretsmanager:us-east-1:<ACCOUNT_ID>:secret:flight/telegram-*"]}]}'
aws iam create-instance-profile --instance-profile-name flight-openclaw-profile
aws iam add-role-to-instance-profile --instance-profile-name flight-openclaw-profile --role-name flight-openclaw-role
```
Wait about 10 seconds before Step 3; a brand-new instance profile is not usable immediately (`Invalid IAM Instance Profile name`).

## Step 3 — Security group and instance

```bash
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query "Vpcs[0].VpcId" --output text --region us-east-1)
SG=$(aws ec2 create-security-group --group-name flight-openclaw-sg --description "OpenClaw bot: no inbound" \
      --vpc-id $VPC --query GroupId --output text --region us-east-1)
# no authorize-security-group-ingress on purpose: the bot polls Telegram, nothing connects in
AMI=$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
      --query Parameter.Value --output text --region us-east-1)
aws ec2 run-instances --image-id $AMI --instance-type t3.small --security-group-ids $SG \
  --iam-instance-profile Name=flight-openclaw-profile --associate-public-ip-address \
  --metadata-options HttpTokens=required,HttpEndpoint=enabled \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":20,"VolumeType":"gp3","DeleteOnTermination":true}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=flight-openclaw},{Key=project,Value=flight-price-notifier}]' \
  --region us-east-1 --query "Instances[0].InstanceId"
```
- `t3.micro` (1 GB) is not enough for OpenClaw; use `t3.small` or bigger. ARM `t4g.small` also works and is cheaper: use the `arm64` AMI path instead of `amd64`.
- If `run-instances` says the default subnet has no public IP, pass `--subnet-id` of a subnet with `MapPublicIpOnLaunch=true`.

**Verify:** wait until SSM sees the instance (1–3 minutes after `running`):
```bash
aws ssm describe-instance-information --filters Key=InstanceIds,Values=<InstanceId> \
  --query "InstanceInformationList[].PingStatus" --region us-east-1      # ["Online"]
```

## Step 4 — Install OpenClaw (SSM Run Command)

Every step below is one `send-command`. Read the result with `get-command-invocation` (`Status`, `StandardOutputContent`, `StandardErrorContent`). Long installs: poll every 15–30 seconds; don't start the next step until this one is `Success`.

```bash
aws ssm send-command --instance-ids <InstanceId> --document-name AWS-RunShellScript \
  --parameters 'commands=["<line 1>","<line 2>"],executionTimeout=["1200"]' --region us-east-1 --query Command.CommandId
aws ssm get-command-invocation --command-id <CommandId> --instance-id <InstanceId> --region us-east-1 \
  --query "{s:Status,out:StandardOutputContent,err:StandardErrorContent}"
```
To ship a file: base64 it locally and decode it on the instance, e.g. `"echo <BASE64> | base64 -d > /tmp/bootstrap.sh"`. Check the decoded file with `sha256sum` against your local copy.

**4a — Bootstrap (root):** ship `assets/ec2/bootstrap.sh`, run `bash /tmp/bootstrap.sh`. Takes 3–5 minutes. Last line looks like `node v24.x | OpenClaw 2026.x.x | aws-cli/2.x`. The npm output must **not** say `install-scripts … not yet covered by allowScripts` for `openclaw`; if it does, the bootstrap is an old copy — re-run `npm install -g --allow-scripts=@google/genai,esbuild,koffi,protobufjs,openclaw openclaw@latest`.

**4b — Secrets helper and service:** ship `assets/ec2/flight-openclaw-secrets` to `/usr/local/bin/` (`chmod 755`) and `assets/ec2/openclaw-gateway.service` to `/etc/systemd/system/`. Then:
```bash
/usr/local/bin/flight-openclaw-secrets && stat -c '%U %a' /home/ubuntu/.openclaw/.env   # ubuntu 600
systemctl daemon-reload
```
Never `cat` the `.env` file; check its owner and mode only.

**4c — Configure (as `ubuntu`):** ship `assets/ec2/configure.sh`, then run it with the provider and model from `flight/llm` (read them with `get-secret-value --query SecretString` piped through a JSON parser that prints only `provider` and `model`, never the key):
```bash
sudo -u ubuntu -H bash /tmp/configure.sh openai gpt-5.4-mini
```
It runs non-interactive onboarding, sets the model, turns on the Telegram channel for everyone (`dmPolicy: "open"`, `allowFrom: ["*"]`, groups off), points the bot token at the `TELEGRAM_BOT_TOKEN` env var, pins OpenClaw's own runtime, and locks tools to `minimal` + `web_fetch`. The last output is the `tools` block; it must show `"profile": "minimal"` and `"alsoAllow": ["web_fetch"]`.

**4d — Persona:** fill the placeholders in `assets/workspace/AGENTS.md`:

| Placeholder | Value |
|---|---|
| `{{SITE_NAME}}` | the site's name (e.g. 機票價格通知) |
| `{{ROUTES}}` | from `flight-routes.json`, e.g. 台北-東京（TPE-TYO）、台北-首爾（TPE-SEL） |
| `{{MONTHLY_PRICE_TWD}}` | the monthly price on the plan cards (e.g. 300) |
| `{{API_BASE}}` | the flight API endpoint (no trailing slash) |
| `{{SITE_URL}}` | the custom domain from M3, or the Vercel URL |
| `{{SUPPORT_EMAIL}}` | `support_email` from `flight/llm` (or the student's contact email) |

Big files go most reliably through S3: upload the filled file (or a JSON list of SSM commands) with a presigned PUT, and have the SSM command or your script read it back. Ship it and `SOUL.md` to `/home/ubuntu/.openclaw/workspace/` (`install -d -o ubuntu -g ubuntu` the folder first; `chown ubuntu:ubuntu` the files). `grep -c '{{' AGENTS.md` must print `0`.

**4e — Start:**
```bash
systemctl enable --now openclaw-gateway
sleep 60; systemctl is-active openclaw-gateway                 # active (first start takes ~40 s)
sudo -u ubuntu -H openclaw channels status --probe             # telegram: running / connected
```
If it isn't active: `journalctl -u openclaw-gateway -n 80 --no-pager` (see Pitfalls).

## Step 5 — Smoke test from the server

A gateway-backed agent turn, same brain the Telegram users get:
```bash
sudo -u ubuntu -H openclaw agent --agent main --message "台北到曼谷最近最便宜多少錢？"
```
Expect a short Chinese answer with a TWD price that matches `GET /prices` for that route, the airline, dates, and a Taipei check time. A call takes about 15 seconds on t3.small with `thinkingDefault: off` (the CLI starts a fresh process each time; Telegram replies take about 10 seconds).

## Step 6 — The real thing: Telegram

**⚠️ Tell the student (imperatively):**
1. 在 Telegram 搜尋你的 bot（`@<username>`），按「開始」，問「你們有哪些航線？」「台北到東京現在多少錢？」「我要訂閱」。
2. 回報結果給 AI。

（不需要找別人測試：你的帳號從沒被核准或配對過，對 bot 來說就是陌生人。你能收到回覆，就證明任何人都能用。）

Optional polish in @BotFather: `/setdescription`（例：24 小時機票價格客服，查航線與即時票價）, `/setabouttext`, `/setuserpic`. Optional on the site: a "Telegram 客服" link to `https://t.me/<username>` in the footer.

## Operating it

| Task | How |
|---|---|
| Rotate the LLM key or bot token | Student gets a new one (@BotFather `/revoke` or the provider console) and gives it to the agent → `put-secret-value` → `systemctl restart openclaw-gateway` via SSM (ExecStartPre re-reads it). |
| Change the persona | Edit `AGENTS.md` on the instance, then restart. |
| Update OpenClaw | `npm install -g openclaw@latest && systemctl restart openclaw-gateway`, then re-run Step 5. |
| Logs | `journalctl -u openclaw-gateway -n 200 --no-pager` |
| Pause to save money | `aws ec2 stop-instances` (disk and IP still bill). `start-instances` brings the bot back on its own. |

### Tear down

`terminate-instances` → wait `terminated` → `delete-security-group flight-openclaw-sg` → `remove-role-from-instance-profile`, `delete-instance-profile`, `delete-role-policy`, `detach-role-policy`, `delete-role` → optionally `delete-secret flight/telegram` and revoke the bot in @BotFather (`/revoke`).

## Pitfalls

1. **Keys only in Secrets Manager.** The student pastes the token/key to the agent once (prerequisites); the agent stores it in Secrets Manager and never writes it into code, the repo, logs or chat replies. The instance pulls it at start. Never `cat` the `.env` file.
2. **Open bot = tight tools.** `dmPolicy: "open"` lets any Telegram user command the agent. Keep `tools.profile: "minimal"` + `alsoAllow: ["web_fetch"]` and the deny list. Never add `exec`, `group:fs`, `browser` or `gateway` to this agent.
3. **Pin the OpenClaw runtime for OpenAI.** Without `models.providers.openai.agentRuntime.id = "openclaw"`, OpenAI routes may run on the Codex harness, which keeps its own tool surface. `configure.sh` sets it.
4. **t3.micro crashes.** OpenClaw needs about 2 GB; use t3.small plus the 2 GB swap from bootstrap.
5. **`openclaw: command not found` under sudo** → it lives in `/usr/bin/openclaw` (global npm with NodeSource). If the installer put it elsewhere, fix `ExecStart` in the unit.
6. **npm skipped install scripts** → npm 11+ only runs dependency install scripts that are allowed; without `--allow-scripts=…openclaw` the bundled plugins aren't set up. `bootstrap.sh` passes the flag.
7. **Node too old** → `openclaw` needs Node ≥ 24.22. Bootstrap installs NodeSource 24; `node -v` must print v24.
8. **Onboarding stops for a plugin capability review** → read the plugin it names, then `sudo -u ubuntu -H openclaw plugins install <name> --accept-capabilities` and re-run `configure.sh`.
9. **Telegram `409 Conflict`** → the same token is polled somewhere else (another OpenClaw, a webhook). Stop the other one, or `deleteWebhook` for that bot.
10. **Bot answers with old prices or none** → check `GET /prices` directly; the bot only knows what that returns.
11. **SSM shows nothing** → the instance profile was missing at launch or the instance has no public IP/outbound route. Attach the profile (`associate-iam-instance-profile`) and reboot.
12. **Bot offers extra "help" when refusing** (e.g. "I can show you how to view the file locally") → the base model's assistant habits leaking. The `AGENTS.md` fixed-reply section fixes it; keep that section when you edit the persona, and start a new session to test (a persona change applies to new sessions).

## Expected duration

40–70 minutes, mostly bootstrap installs and the student's Telegram tests.

## Next step

Run **[[m4-chat-to-subscribe-checklist]]** (「驗收 M4」).

## Reference

- OpenClaw install and VPS guide: https://docs.openclaw.ai/install , https://docs.openclaw.ai/install/digitalocean
- Non-interactive onboarding: https://docs.openclaw.ai/start/wizard-cli-automation
- Telegram setup and access control: https://docs.openclaw.ai/channels/telegram/setup , https://docs.openclaw.ai/channels/telegram/access-control
- Tool policy (profiles, groups, allow/deny): https://docs.openclaw.ai/gateway/config-tools/tool-policy
- Agent runtime pinning: https://docs.openclaw.ai/gateway/config-agents/runtime-and-cli-backends
- Written against OpenClaw 2026.10.7 (npm `openclaw`).
