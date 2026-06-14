---
name: m3-domain
description: Flight Price Notifier Milestone 3 — bind your own custom domain to BOTH the Vercel front-end AND the Resend email sender (one domain, two DNS setups), and optionally switch ECPay (綠界) from the shared stage test merchant to your real production MerchantID, with an AI-driven go-live checklist so nothing is missed. Use when the student says "啟動 M3", "start M3", "綁網域", "上線", "go live", or "正式開張".
---

# M3 — Custom Domain + Go-Live（綁定自己的網域，讓產品變成真正「自己的」）

## What this skill does

Takes the working paid product and makes it **truly yours, ready to open for business**. You buy **one domain** and use it in **two** places (two separate DNS setups at the same registrar):

1. **The website** — `yourdomain.com` → your Vercel front-end (`A`/`CNAME` records). Visitors load `https://yourdomain.com` instead of `*.vercel.app`.
2. **The email sender** — `alerts@yourdomain.com` as the Resend `From:` (SPF + DKIM records). Emails now come from your domain (inbox, not spam) — **and this is what lifts the M2 Resend-sandbox limit**: once the domain is verified, Resend delivers to **anyone**, not just your own account email.
3. **ECPay production (optional)** — switch from the shared stage test merchant to your own real MerchantID so you can take real money.
4. **A go-live checklist Skill** — AI walks every pre-launch item one-by-one (上線檢查清單，一條一條確認過，不漏掉).

> **The domain covers the website + email; it does NOT have to cover the ECPay callbacks.** ECPay's `ReturnURL`/`PeriodReturnURL`/`OrderResultURL` can stay on the raw **API Gateway** URL (`*.execute-api…`) — ECPay only needs a public HTTPS endpoint on port 80/443, and users never see those URLs. Mapping a custom domain onto API Gateway (ACM cert + API mapping) is **extra, optional** work; don't think you must.

Why this matters: 有了自己的網域，才是真正屬於你的產品 — 才能打廣告、做 SEO、累積品牌資產。

End state: visiting `https://yourdomain.com` shows your product, emails come from `@yourdomain.com` (and reach real users), and (optionally) ECPay is in production mode taking real payments.

## When to load this skill

- "啟動 M3" / "start M3" / "綁網域" / "上線" / "go live" / "正式開張"

Requires M2 done (`m2-ecpay-subscription-checklist` green). Adds one account: a **domain registrar** (Namecheap / Cloudflare / GoDaddy — any).

## Execution mode

DNS + dashboards mostly (Vercel, Resend, registrar, ECPay 廠商後台). `vercel` CLI / MCP for domain attach; `aws` only to update the `flight/resend` + `flight/ecpay` secrets. `aws` commands `--region us-east-1`.

## Required external accounts (new)

| # | Service | Used for |
|---|---|---|
| 9 | Domain registrar (any) | the domain you'll bind (`yourdomain.com`) |

## Conversational flow

### Step 1 — Buy / pick a domain

Tell the student to register a domain at any registrar (Namecheap / Cloudflare / GoDaddy). Cloudflare is cheapest at cost and has the easiest DNS UI.

**Verify before moving on:** the student owns a domain and can access its DNS settings.

### Step 2 — Attach the domain to Vercel

```bash
vercel domains add yourdomain.com        # or via Vercel dashboard → Project → Settings → Domains
```
Vercel shows the DNS records to add at the registrar (an `A`/`CNAME` for apex + `www`). Add them.

**Verify before moving on:**
```bash
curl -sS -o /dev/null -w "%{http_code}\n" https://yourdomain.com
```
Expect `200`, serving your app. (DNS can take minutes to propagate.)

### Step 3 — Verify your Resend sending domain

1. Resend → **Domains → Add Domain** → `yourdomain.com`.
2. Add the **SPF + DKIM** DNS records Resend gives you at the registrar.
3. Wait for Resend to show the domain **Verified**.
4. Update the secret to send from your domain:
```bash
aws secretsmanager put-secret-value --secret-id flight/resend \
  --secret-string '{"api_key":"re_...","from":"alerts@yourdomain.com"}' \
  --region us-east-1
```

**Verify before moving on:** a price-check email now arrives **from `alerts@yourdomain.com`** and lands in the inbox (not spam) — **and crucially, it now reaches a recipient that ISN'T your own Resend-account email** (the M2 sandbox limit is lifted once the domain is verified). Send a test to a second address to prove it.

### Step 4 — (Optional) Switch ECPay to production

Only when ready to take real money. Full walkthrough in **[[ecpay-go-live]]**; the short version:
1. Apply for a **real ECPay merchant** at `vendor.ecpay.com.tw` (信箱/身分/銀行 verification, **3–5 工作日** review) and **confirm 信用卡定期定額 is enabled** on it (the easy-to-miss step).
2. Put your **real** `merchant_id`/`hash_key`/`hash_iv` into the secret and flip `env` to `prod` (this also points the cashier at `payment.ecpay.com.tw`):
```bash
aws secretsmanager put-secret-value --secret-id flight/ecpay \
  --secret-string '{"merchant_id":"<real>","hash_key":"<real>","hash_iv":"<real>","env":"prod","amount":"<TWD>"}' \
  --region us-east-1
```
3. No redeploy — the Lambdas read the secret at runtime; the cashier host + `CreditCardPeriodAction` URL switch off `env`. The `ReturnURL`/`PeriodReturnURL` (your custom domain or API GW) stay the same.

**Verify before moving on:** a real (small) production payment flows end-to-end (row → `active`, then cancel+refund yourself), or stay on the stage merchant for the course and just document the switch. (There are **no** product/price objects to recreate and **no** webhook endpoint to re-register — only the merchant identity + cashier host change.)

### Step 5 — Run the go-live checklist

Load `m3-domain-checklist` and walk every item: domain serves HTTPS, emails from your domain land in inbox **and reach a non-owner recipient**, the ECPay checkout works on the real domain, the callback URLs (`ReturnURL`/`PeriodReturnURL`/`OrderResultURL`) resolve and respond (whether on the custom domain or the API GW), CORS allows your domain, secrets are prod (if switched), and no test data leaks into production.

**Verify before moving on:** the checklist is all green.

## Things to watch out for

1. **DNS propagation** — `200` may take a few minutes after adding records; don't panic if the first curl 404s.
2. **Apex vs www** — add both, and pick one canonical (redirect the other).
3. **Resend domain NOT verified** → emails from a custom `from` get rejected/spam-foldered. Don't change the `from` secret until Resend shows Verified.
4. **CORS still `*`** — tighten the API Gateway CORS `AllowOrigins` to `https://yourdomain.com` for production. (But the ECPay **callback** routes — `/ecpay-return`, `/ecpay-period`, `/ecpay-result` — are hit server-to-server by ECPay, **not** the browser, so CORS doesn't apply to them; don't expect CORS to block or affect callbacks.)
4b. **You do NOT need to domain-map the API Gateway.** ECPay callbacks happily stay on `*.execute-api…` (they're invisible to users). Only map a custom domain onto the API if you specifically want branded callback URLs — it's optional ACM+mapping work, not a go-live requirement.
5. **ECPay prod uses a different HashKey/HashIV** — a real `HashKey`/`HashIV` with a stage `MerchantID` (or vice-versa) → CMV passes but the merchant check fails. Swap the **matching** real keypair, and confirm 定期定額 is enabled on it ([[ecpay-go-live]]).
6. **Mixed stage/prod** — don't leave `env:"stage"` (cashier `payment-stage…`) with real creds; flip `env` to `prod` so the form posts to `payment.ecpay.com.tw`.
7. **Test data in prod** — clean out `checklist@test.com`-style rows before launch.

## Expected duration

60–120 minutes (mostly DNS waiting + Resend domain verification).

## Next step

When `m3-domain-checklist` is green: 「M3 完成！產品掛在你自己的網域、用你自己的品牌寄信，正式開張了 🎉 想加一個亮點功能嗎？跟我說『啟動 M4』，我們自架一台真的 OpenClaw 在 EC2 上，當你服務的 24 小時 AI 機票客服（Telegram 上回答航線/收費、要訂閱退訂就導去網頁）。」Then optionally load `m4-chat-to-subscribe`.

## Reference

- Vercel custom domains: https://vercel.com/docs/projects/domains
- Resend domain verification: https://resend.com/docs/dashboard/domains/introduction
- [[resend-best-practice]] — Rule 2 (don't flip the `from` secret until the domain is **Verified**), and why the demo sender couldn't reach real users.
- [[ecpay-go-live]] — the full stage→production ECPay switch (apply for a real MerchantID, confirm 定期定額 enabled, flip `env`, smoke-test + refund).
- [[ecpay-best-practice]] — the callback hard rules carried over unchanged into production.
