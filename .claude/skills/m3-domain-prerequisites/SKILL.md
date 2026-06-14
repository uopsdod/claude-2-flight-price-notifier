---
name: m3-domain-prerequisites
description: Prerequisites before M3 of the Flight Price Notifier course — a domain registrar account/domain (the SAME domain is used for both the Vercel site and the Resend email sender), plus confirmation the M2 paid product works on the Vercel URL before binding a custom domain. Use when the student starts M3, or when `m3-domain` / `-checklist` detects the domain or M2 carryover is missing.
---

# M3 Prerequisites — Domain + M2 carryover

## What this skill does

M3 adds one thing: a **domain you own** at any registrar. Everything else carries over from M2 (the live-on-Vercel paid product). This skill confirms both.

## When to load this skill

- "M3 環境準備" / any time M3 detects the domain or the M2 product is missing.

## Step 1 — A domain (and ASK the student which one — it's not auto-discoverable)

Register a domain at Namecheap / Cloudflare / GoDaddy (any). Cloudflare is cheapest-at-cost with the simplest DNS UI. You need access to its **DNS records** panel. This **one** domain is used twice in M3: for the **Vercel site** AND as the **Resend email sender** (`alerts@<domain>`).

> **The agent must ASK the student for the domain — you cannot look it up.** The domain lives at the registrar + Vercel + Resend, **none of which are AWS**. Your AWS account has **no record of it** (the browser talks to Vercel/API-Gateway; AWS only ever sees the API Gateway hostname). The single place it *might* appear is the `flight/resend` secret's `from` field — but that's still `onboarding@resend.dev` until Step 3 of the main skill sets it. So: **collect the domain string from the student in chat** ("What domain will you use? Or say you haven't bought one yet.") and use that value in every later step. If they haven't bought one, they do Step 1 first.

**Verify:** the student tells you their domain (or buys one), owns it, and can add DNS records.

## Step 2 — Confirm M2 carryover (the product works on the Vercel URL)

```bash
# the live Vercel site responds
curl -sS -o /dev/null -w "%{http_code}\n" https://<your>.vercel.app          # 200
# ECPay callback Lambdas exist (M2)
for fn in flight-ecpay-return flight-ecpay-period; do aws lambda get-function --function-name $fn --region us-east-1 --query 'Configuration.FunctionName'; done
# resend + ecpay secrets exist (list all names + scan — backtick JMESPath filters error through the AWS API MCP)
aws secretsmanager list-secrets --region us-east-1 --query "SecretList[].Name"   # flight/travelpayouts, /resend, /ecpay, + the cache /github, /supabase
```
If the paid flow isn't working on the Vercel URL yet, finish M2 first — M3 only changes the *address*, not the logic.

## Step 3 — Access to all the dashboards you'll touch

Make sure the student can log into: the **registrar** (DNS), **Vercel** (domains), **Resend** (domain verification), and **ECPay 廠商後台** (`vendor.ecpay.com.tw` for real-merchant activation, if switching). 

## Verify (all must pass)

- Domain owned, DNS editable ✅
- Vercel URL returns 200 with the paid product ✅
- `flight-ecpay-return` + `flight-ecpay-period` + all `flight/*` secrets exist ✅

## Next step

Return to `m3-domain` Step 1.
