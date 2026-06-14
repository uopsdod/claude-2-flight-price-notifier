---
name: m3-domain
description: Flight Price Notifier Milestone 3 — bind your own custom domain to BOTH the Vercel front-end AND the Resend email sender (one domain, two DNS setups). This skill does the SETUP only; all verification (and the optional ECPay production switch) happen elsewhere. Use when the student says "啟動 M3", "start M3", "綁網域", "上線", "go live", or "正式開張".
---

# M3 — Custom Domain（把網站和寄信都掛上你自己的網域）

## What this skill does

Takes the working paid product and gives it **your own brand**. You buy **one domain** and set it up in **two** places (two separate DNS setups at the same registrar):

1. **The website** — `yourdomain.com` → your Vercel front-end (`A`/`CNAME` records). Visitors load `https://yourdomain.com` instead of `*.vercel.app`.
2. **The email sender** — `alerts@yourdomain.com` as the Resend `From:` (SPF + DKIM records). Emails come from your domain (inbox, not spam) — **and this lifts the M2 Resend-sandbox limit**: once the domain is verified, Resend delivers to **anyone**, not just your own account email.

> **Scope:** this skill performs the **setup actions only**. **Verification is not done here** — run **[[m3-domain-checklist]]** to confirm everything works (HTTPS, deliverability, non-owner delivery, etc.). And the **optional ECPay production switch** (real MerchantID) is its own skill: **[[ecpay-go-live]]**.

> **The domain covers the website + email; it does NOT have to cover the ECPay callbacks.** ECPay's `ReturnURL`/`PeriodReturnURL`/`OrderResultURL` can stay on the raw **API Gateway** URL (`*.execute-api…`) — ECPay only needs a public HTTPS endpoint on port 80/443, and users never see those URLs. Mapping a custom domain onto API Gateway (ACM cert + API mapping) is **extra, optional** work; don't think you must.

Why this matters: 有了自己的網域，才是真正屬於你的產品 — 才能打廣告、做 SEO、累積品牌資產。

End state of this skill: the Vercel domain + the Resend sending domain are **set up** (records added, secret flipped). You then **verify** with the checklist.

## When to load this skill

- "啟動 M3" / "start M3" / "綁網域" / "上線" / "go live" / "正式開張"

Requires M2 done (`m2-ecpay-subscription-checklist` green). Adds one account: a **domain registrar** (Namecheap / Cloudflare / GoDaddy — any). The domain string comes from the student — see `m3-domain-prerequisites` (it's not discoverable from AWS).

## Execution mode

DNS + dashboards mostly (Vercel, Resend, registrar). `vercel` CLI / MCP for domain attach; `aws` only to update the `flight/resend` secret. `aws` commands `--region us-east-1`.

## Required external accounts (new)

| # | Service | Used for |
|---|---|---|
| 9 | Domain registrar (any) | the domain you'll bind (`yourdomain.com`) |

## Conversational flow

### Step 1 — Confirm the host(s) and where DNS lives

From `m3-domain-prerequisites` you already know: the **exact host(s)** to bind (apex `yourdomain.com`, or a dedicated **subdomain** like `fly.yourdomain.com` if the apex is already in use by another project) and **where the DNS is** (a **Route 53** hosted zone you edit via the AWS MCP, or an external registrar). Carry those forward.

> **DNS edits in Route 53:** every record below is an **`UPSERT`** via `aws route53 change-resource-record-sets --hosted-zone-id <id> --change-batch '{…}'` — never a blind create that could clobber an existing record. **Multi-value records (TXT) must include ALL existing values plus the new one** in a single `UPSERT` (Route 53 replaces the whole record set). If the zone is in a different AWS account than the flight project, switch the `[default]` profile to the **domain account** for these steps.

### Step 2 — Attach the host to Vercel

⚠️ **Cowork: adding the domain to the project is a MANUAL dashboard step** — there's no Vercel-domain MCP tool. The student does: **Vercel dashboard → Project → Settings → Domains → Add** `<your host>`. (CLI users can `vercel domains add <host>`.)

Then Vercel **displays the exact DNS records to create** — read them off the dashboard and create them in DNS. The records depend on whether you bind an apex or a subdomain, and **whether the host was ever linked to another Vercel account**:

- **Apex** → an `A` record to Vercel's anycast IP (Vercel shows it). **Subdomain** → a `CNAME`. ⚠️ **Use the EXACT CNAME target Vercel gives you** — for a previously-linked host it's often a **project-specific** target like `…vercel-dns-017.com`, **not** the generic `cname.vercel-dns.com`.
- **If the host was linked elsewhere before**, Vercel also demands a **`_vercel` TXT** ownership record (`vc-domain-verify=…`). ⚠️ **`_vercel` TXT is multi-value** — if it already holds a verify token for another subdomain, you must **append** the new value, not overwrite (in Route 53, `UPSERT` the `_vercel` TXT with **both** values).

After the records propagate, Vercel shows the domain **Valid/active** and issues a TLS cert automatically.

### Step 3 — Set up your Resend sending domain (subdomain if the apex is taken)

⚠️ **You CANNOT verify the same apex in two Resend accounts.** Resend's DKIM selector is `resend._domainkey.<apex>` — if that apex is already verified in **another** Resend account (e.g. a different project of yours), the selector **collides** and verification fails. The fix is a **dedicated sending subdomain**.

1. Resend → **Domains → Add Domain**. Enter **`mail.yourdomain.com`** (a sending subdomain) **if** the apex is shared/already-used elsewhere; otherwise the apex is fine.
2. Add the **exact** records Resend displays. For a sending subdomain `send.<sub>` they're typically:
   - **DKIM** — `TXT` at `resend._domainkey.<sub>` (the long `p=…` key)
   - **MX** — `send.<sub>` → `10 feedback-smtp.<region>.amazonses.com`
   - **SPF** — `TXT` at `send.<sub>` → `v=spf1 include:amazonses.com ~all`
   - (optionally a DMARC `TXT` at `_dmarc.<sub>`)
   Create them in DNS (Route 53 `UPSERT`, or the registrar).
3. Wait for Resend to show the domain/subdomain **Verified**.
4. **Only after Verified**, flip the secret to send from your (sub)domain — using the **project account's** profile if multi-account:
```bash
aws secretsmanager put-secret-value --secret-id flight/resend \
  --secret-string '{"api_key":"re_...","from":"alerts@mail.yourdomain.com"}' \
  --region us-east-1
```
5. **⚠️ Bust the warm-container cache before testing.** The sending Lambda (`flight-fare-notification`) reads `flight/resend` **at container init and caches it** — after `put-secret-value`, a warm container keeps the **old `from`** and you'll get Resend `403 validation_error` (sandbox) even though the secret is already correct. Force a cold start:
```bash
aws lambda update-function-configuration --function-name flight-fare-notification \
  --environment "Variables={CACHE_BUST=$(date +%s)}" --region us-east-1
```
(Any env-var change forces a fresh container that re-reads the secret. Same applies to `flight-status-notification` if it reads `flight/resend`.)

> Don't flip the `from` secret before Resend shows **Verified** — a custom `from` on an unverified domain gets rejected / spam-foldered ([[resend-best-practice]] Rule 2). And remember the cache-bust (step 5) — it's the #1 "I updated the secret but it still 403s" trap.

### Step 4 — Verify

Setup is done. **Run [[m3-domain-checklist]]** (the student can say 「驗收 M3」/「上線檢查」) — it verifies the things **M3 actually changes**: the domain serves HTTPS with a valid cert, Resend is Verified and email sends from your domain **reaching a non-owner inbox** (proving the M2 sandbox limit is lifted), and the secrets are internally consistent. (It deliberately does **not** re-run the payment journey — that's an M2 concern, since M3 doesn't touch the ECPay path — or grep the front-end bundle.)

> **Taking real money? (optional, separate skill)** Switching ECPay from the shared stage merchant to your own **production MerchantID** is **[[ecpay-go-live]]** — apply for a real merchant (3–5 工作日 review), confirm 信用卡定期定額 is enabled, put the real creds in `flight/ecpay` with `env:"prod"`, smoke-test + refund. It's optional; the course works fine staying on the stage merchant.

## Things to watch out for (setup gotchas)

1. **Bind a subdomain when the apex is in use** — if `yourdomain.com`/`www` already serve another project, don't clobber them; bind `fly.yourdomain.com` (site) + `mail.yourdomain.com` (email). For a fresh apex, add both apex + `www` and pick one canonical.
2. **Never overwrite multi-value records** — `_vercel` TXT and SPF/DKIM TXT can already hold other values; in Route 53 `UPSERT` the record set with **all** values (existing + new), or you'll break the other project's verification (Step 2/3).
3. **Don't flip the Resend `from` secret before the domain is Verified** — rejected / spam until SPF+DKIM are live (Step 3).
4. **Cache-bust after changing `flight/resend`** — the Lambda caches the secret in warm containers; force a cold start or you'll see a stale-`from` `403` even though the secret is right (Step 3.5). This is the #1 confusing trap.
5. **Multi-account** — if the Route 53 zone and the flight project are in **different AWS accounts**, switch the `[default]` profile between DNS steps (domain account) and secret/Lambda steps (project account). For a single-account student, ignore.
6. **CORS stays `*` in this course (intentional)** — M3 does **not** lock CORS to the domain; `AllowOrigins: ["*"]` already allows the new domain, so nothing breaks and there's no CORS step. (Per-origin locking is a later hardening choice, not part of M3.) Note the ECPay **callback** routes are hit server-to-server, so CORS never applies to them anyway.
7. **You do NOT need to domain-map the API Gateway** — ECPay callbacks happily stay on `*.execute-api…` (invisible to users). Branded callback URLs are optional ACM+mapping work, not a requirement.
8. **DNS propagation** — records can take a few minutes; if the first check fails, wait and retry (the checklist handles this).

## Expected duration

30–90 minutes (mostly DNS waiting + Resend domain verification).

## Next step

After setup, run **[[m3-domain-checklist]]**. When it's all green: 「M3 完成！產品掛在你自己的網域、用你自己的品牌寄信，正式開張了 🎉 想加一個亮點功能嗎？跟我說『啟動 M4』，我們自架一台真的 OpenClaw 在 EC2 上，當你服務的 24 小時 AI 機票客服（Telegram 上回答航線/收費、要訂閱退訂就導去網頁）。」Then optionally load `m4-chat-to-subscribe`.

## Reference

- Vercel custom domains: https://vercel.com/docs/projects/domains
- Resend domain verification: https://resend.com/docs/dashboard/domains/introduction
- [[m3-domain-prerequisites]] — getting the domain string from the student (it's not discoverable from AWS) + the Route 53 cross-check.
- [[m3-domain-checklist]] — **all verification lives here.**
- [[resend-best-practice]] — Rule 2 (don't flip the `from` secret until Verified), and why the demo sender couldn't reach real users.
- [[ecpay-go-live]] — the optional stage→production ECPay switch.
