#!/bin/bash
# M4 step 4c: run as the ubuntu user (sudo -u ubuntu -H bash configure.sh <provider> <model>).
# Writes ~/.openclaw/openclaw.json: model, Telegram channel open to everyone, tools locked down.
set -euo pipefail
PROVIDER=${1:?provider openai|anthropic}
MODEL=${2:?model id, e.g. gpt-5.4-mini}
set -a; . ~/.openclaw/.env; set +a

if [ "$PROVIDER" = openai ]; then AUTH=openai-api-key; else AUTH=apiKey; fi
openclaw onboard --non-interactive --accept-risk --skip-health \
  --mode local --auth-choice "$AUTH" --secret-input-mode ref \
  --gateway-bind loopback --skip-daemon --skip-bootstrap --skip-skills

openclaw config set agents.defaults.model "{\"primary\":\"$PROVIDER/$MODEL\"}" --strict-json
openclaw config set agents.defaults.userTimezone "Asia/Taipei"
# A customer-service bot needs none of the bundled skills (trello, spotify, …); keep its prompt on topic.
openclaw config set agents.defaults.skills '[]' --strict-json
# Short lookups don't need model reasoning; on gpt-5.4-mini this cut a Telegram reply from ~35 s to ~10 s.
openclaw config set agents.defaults.thinkingDefault off
# Use OpenClaw's own runtime so the tool policy below is enforced on every turn
# (the Codex harness may otherwise claim OpenAI routes with its native tool surface).
openclaw config set "models.providers.$PROVIDER.agentRuntime" '{"id":"openclaw"}' --strict-json --merge

# Public customer-service bot: anyone may DM it, groups are off.
openclaw config set channels.telegram \
  '{"enabled":true,"dmPolicy":"open","allowFrom":["*"],"groupPolicy":"disabled"}' --strict-json --merge
openclaw config set channels.telegram.botToken --ref-provider default --ref-source env --ref-id TELEGRAM_BOT_TOKEN

# Least privilege: an open bot can be talked to by anyone, so it gets read-only web_fetch and nothing else.
openclaw config set tools \
  '{"profile":"minimal","alsoAllow":["web_fetch"],"deny":["group:runtime","group:fs","group:ui","group:automation","group:nodes","group:media","group:sessions","web_search","x_search"]}' \
  --strict-json --merge

openclaw config validate
openclaw config get tools
