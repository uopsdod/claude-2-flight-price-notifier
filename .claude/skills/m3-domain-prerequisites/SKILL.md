---
name: m3-domain-prerequisites
description: Prerequisites before M3 of the Flight Price Notifier course — a domain (or subdomain) you control, whose DNS may live in Route 53 (manageable via the AWS MCP) OR an external registrar; plus confirmation the M2 paid product works on the Vercel URL before binding. Covers the multi-account (domain vs project in different AWS accounts) and shared-domain (bind a subdomain) cases. Use when the student starts M3, or when `m3-domain` / `-checklist` detects the domain or M2 carryover is missing.
---

# M3 Prerequisites — Domain + M2 carryover

## What this skill does

M3 adds one thing: a **domain (or subdomain) you control**. Its DNS may live in **Route 53** (manage it directly via the AWS MCP — the smoothest path) or an **external registrar** (Namecheap/Cloudflare/GoDaddy). Everything else carries over from M2 (the live-on-Vercel paid product). This skill identifies the domain + where its DNS lives, and confirms the M2 carryover.

## Architecture

![Flight Fare / Notification architecture (M3) — the full M2 system the domain (these prerequisites identify) gets bound onto in two places. The Product Site is relabeled [domain].com (Vercel host) instead of *.vercel.app — that relabel IS the M3 change. The Product Site POSTs to the ECPay Lambda Handlers (flight-ecpay-return / flight-ecpay-period / flight-cancel-subscription), which write subscription_status onto Subscriptions [DynamoDB]; a "subscription check" gate on that table makes the Parser scan only active rows. On payment events the handlers enqueue to the Notification-side SQS, where the Subscription Status Notification Lambda emails welcome/cancel via Resend — bound to alerts@[domain].com in M3. The notifier flow: EventBridge → Parser Wrapper → Parser (×N) reads Flight Routes [S3] + the travelpayouts API, scans Subscriptions, enqueues matches to the Flight Fare Notification SQS → Flight Fare Notification Lambda dedups against Notification History [DynamoDB] and emails via Resend. The two places M3 binds the domain — the Product Site box and the Resend email sender — are the only edges that change. Inset: the subscribe → ECPay → callback (W = write) loop. Legend: orange = manual input, teal = main component, pink = user data.](assets/flight_notification_structure2.jpg)

## When to load this skill

- "M3 環境準備" / any time M3 detects the domain or the M2 product is missing.

## Step 1 — Identify the domain and WHERE its DNS lives (check Route 53 FIRST, then ask)

M3 uses **one** domain (or subdomain) in two places: the **Vercel site** AND the **Resend email sender** (`alerts@<host>`). Before anything else, find out **where its DNS is managed**, because that decides whether you (the agent) edit DNS directly or hand records to the student.

**Check Route 53 first** (via the AWS MCP) — the domain may well be an AWS-hosted zone you can manage end-to-end:
```bash
aws route53 list-hosted-zones --query "HostedZones[].{name:Name,id:Id,private:Config.PrivateZone}"
# match a zone whose Name == "<their-domain>." (note the trailing dot)
```

| Outcome | What it means → what to do |
|---|---|
| A **public** zone matches the domain | ✅ DNS is in Route 53 — **you can add every Vercel/Resend record yourself** via `aws route53 change-resource-record-sets` (`UPSERT`). No registrar panel, no guessing. Note the `HostedZoneId`. |
| **No** matching zone | The domain is at an external registrar / Cloudflare / Vercel DNS. **Ask the student** for the domain and have them (or you, if they grant access) add records there. |
| A **private** zone matches | Internal-VPC zone — ignore it for go-live; treat as "no public zone." |
| A zone matches but the student says they don't own it | Possible typo, or someone else's zone in a shared account — **pause and confirm** before binding anything. |

> **Don't assume the domain is un-lookable.** (An earlier version of this skill claimed "AWS has no record of it, you must ask." That's only true when DNS is *external* — when the domain is a Route 53 hosted zone, it's fully discoverable and editable through the MCP, which is the smoother path. Check first.)

### ⚠️ Multi-account: the Route 53 zone may be in a DIFFERENT AWS account than the flight resources

The AWS MCP uses a single `[default]` profile. In a real setup the **domain (Route 53)** and the **flight project (Lambdas/secrets/API Gateway)** can live in **different AWS accounts** — so you'll **switch the `[default]` profile** between *DNS steps* (domain account) and *secret/Lambda steps* (project account). Identify both up front:
- Which account/profile holds the **Route 53 zone** → used for all DNS record changes.
- Which account/profile holds **`flight/*` secrets + the Lambdas + `flight-api`** → used for the `put-secret-value`, cold-start, etc.
- For a **student** this is usually **one** account — flag the two-account case as the advanced variant. (See [[aws-best-practice]].)

### ⚠️ Shared / in-use domain: bind a SUBDOMAIN, never clobber the apex

If the apex (`yourdomain.com`) and `www` are **already serving another project**, do **not** overwrite their records. Bind a **dedicated subdomain** for the flight site instead — e.g. `fly.yourdomain.com` for the site and `mail.yourdomain.com` (or `fly-notify.yourdomain.com`) for the Resend sender. Every DNS write is an **`UPSERT`/append**, never a blind overwrite — multi-value records (like `_vercel` TXT) must be appended to, not replaced (see [[m3-domain]] Step 2). Decide the exact host(s) here so the later steps use them consistently.

**Verify:** you know (a) the exact host(s) you'll bind (apex or a subdomain), and (b) where their DNS lives (Route 53 account/profile, or an external registrar the student can edit).

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

## Step 3 — Access to everything you'll touch

Confirm access to: **DNS** (the Route 53 account/profile **or** the external registrar), **Vercel** (adding a domain to the project is a **manual dashboard step** — there's no Vercel-domain MCP tool in Cowork), **Resend** (domain verification), and — only if switching ECPay to prod — the **ECPay 廠商後台** (`vendor.ecpay.com.tw`).

## Verify (all must pass)

- The exact host(s) to bind are decided (apex, or a dedicated subdomain if the apex is in use) ✅
- You know where the DNS lives and can edit it — Route 53 (via MCP) **or** an external registrar ✅
- If domain and project are in **different AWS accounts**, you've identified which profile to use for DNS vs. for secrets/Lambdas ✅
- Vercel URL returns 200 with the paid product ✅
- `flight-ecpay-return` + `flight-ecpay-period` + all `flight/*` secrets exist (in the project account) ✅

## Next step

Return to `m3-domain` Step 1.
