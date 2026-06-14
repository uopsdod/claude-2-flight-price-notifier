---
name: m3-domain-checklist
description: Flight Price Notifier Milestone 3 GO-LIVE checklist — the AI walks every pre-launch item one-by-one (custom domain serves HTTPS, emails from your domain land in inbox AND reach a non-owner recipient, the ECPay checkout + callbacks work on the production address, CORS locked to your domain, secrets correct, no test data) so nothing is missed before opening for business. Use when the student says "驗收 M3", "上線檢查", "go-live checklist", or after `m3-domain` Step 5.
---

# M3 — Go-Live Checklist（上線檢查清單，一條一條確認，不漏掉）

## What this skill does

This is the **go-live gate**. Before the product opens for business, the AI actively verifies every launch-critical item — domain, email deliverability, payments, security, and data hygiene — and reports a clear ✅/⚠️/❌ per item. This is the "上線檢查清單 Skill" the course promises: AI 幫你一條一條確認過，不漏掉。

Run after `m3-domain` Step 5, or any time before launch.

## Execution mode

CLI uses `curl`/`aws`/`vercel`; Cowork uses dashboards/MCP. `aws` commands `--region us-east-1`.

## How to run

Ask the student for: their custom domain, the API base URL, and a test inbox. (Subscription data is read from DynamoDB.) Then run each section and report.

### Section A — Domain & HTTPS
- **A1** Apex serves the app over HTTPS:
  ```bash
  curl -sS -o /dev/null -w "%{http_code}\n" https://yourdomain.com          # 200
  ```
- **A2** `www` also resolves (and redirects to the canonical, or vice-versa):
  ```bash
  curl -sS -o /dev/null -w "%{http_code} %{url_effective}\n" -L https://www.yourdomain.com
  ```
- **A3** Valid TLS cert (no warning): `curl -sSI https://yourdomain.com | head -1` → `HTTP/2 200`.

### Section B — Email deliverability
- **B1** Resend domain shows **Verified** (SPF + DKIM). 
- **B2** Secret `from` is your domain:
  ```bash
  aws secretsmanager get-secret-value --secret-id flight/resend --region us-east-1 \
    --query SecretString --output text | grep -o 'alerts@[^"]*'
  ```
- **B3** **Deliverability test:** trigger a price-check email → it arrives **from `alerts@yourdomain.com`**, in the **inbox** (not spam). This is the one most likely to be ⚠️.
- **B4** **Non-owner delivery (the M2 sandbox-lift):** send a test alert to an address that is **NOT** your Resend-account email (a friend's, a second inbox). It must arrive — proving domain verification lifted the sandbox-only-delivers-to-owner limit. If it 403s `validation_error`, the domain isn't actually Verified yet (B1).

### Section C — Payments on the real domain
- **C1** The ECPay checkout works from the live domain (submit the real form on `https://yourdomain.com` → reaches the ECPay cashier).
- **C2** The **callback URLs** the checkout form hands ECPay (`ReturnURL`/`PeriodReturnURL`) resolve on the production address (your custom domain or the API GW), and a recent first-period payment shows CMV-verified + `1|OK` in `flight-ecpay-return` logs.
- **C3** If switched to production: `flight/ecpay` has the **real** `merchant_id`/`hash_key`/`hash_iv` and `env:"prod"` (cashier resolves to `payment.ecpay.com.tw`), and 信用卡定期定額 is confirmed enabled on the merchant. If staying on the stage merchant for now: documented as such.

### Section D — Security & config
- **D1** CORS is locked to the real domain (not `*`):
  ```bash
  aws apigatewayv2 get-api --api-id <ApiId> --region us-east-1 --query 'CorsConfiguration.AllowOrigins'
  ```
  Should list `https://yourdomain.com`, not `*`.
- **D2** No AWS credentials in the front-end bundle — the browser only hits API Gateway; only the Lambda (IAM role) touches DynamoDB. (Grep the deployed site / repo for `AKIA`, `aws_secret`, `service_role` → all must be absent. The Supabase **publishable** key is OK; the service-role key and any AWS key are NOT.)
- **D3** Secrets are the right ones for the chosen mode — `flight/ecpay` consistent (`env` matches the cashier host; `merchant_id`/`hash_key`/`hash_iv` all stage **or** all prod, never mixed).

### Section E — Data hygiene
- **E1** No test rows in production tables:
  ```bash
  aws dynamodb scan --table-name subscriptions \
    --filter-expression 'contains(email, :t)' --expression-attribute-values '{":t":{"S":"test"}}' \
    --region us-east-1 --query 'Count'
  ```
  Should be empty (clean out `checklist@test.com`, `e2e@test.com`, etc.).
- **E2** The 3 starter routes still fetch real prices (`flight_price_history` has fresh rows).

### Section F — Final smoke test (a real user journey)
- **F1** On `https://yourdomain.com`: sign up → subscribe a route with a target above the live fare → pay (ECPay; stage card if not yet prod) → the browser returns via the `flight-ecpay-result` redirect (a clean success page, **not a 405**) → the row flips `active` → price-check runs → **an alert email from `@yourdomain.com` arrives at a real (non-owner) inbox**. End-to-end, on the real domain.

## Reporting

| Item | Status | Notes |
|---|---|---|
| A1 apex HTTPS 200 | ✅/❌ | |
| A2 www resolves | ✅/❌ | |
| A3 valid TLS | ✅/❌ | |
| B1 Resend verified | ✅/❌ | |
| B2 from = your domain | ✅/❌ | |
| B3 inbox, from domain | ✅/⚠️ | likely ⚠️ first |
| B4 reaches a non-owner inbox | ✅/❌ | sandbox-lift proof |
| C1 ECPay checkout on domain | ✅/❌ | |
| C2 callbacks resolve + `1\|OK` | ✅/❌ | ReturnURL/PeriodReturnURL |
| C3 stage/prod mode consistent | ✅/❌ | |
| D1 CORS locked | ✅/❌ | |
| D2 no AWS/service-role key in FE | ✅/❌ | critical |
| D3 secrets correct | ✅/❌ | |
| E1 no test data | ✅/⚠️ | |
| E2 fresh prices | ✅/❌ | |
| F1 full journey on domain | ✅/❌ | the launch gate |

**Verdict:**
- All ✅ → 「🎉 上線檢查全過，可以正式開張！產品掛在你自己的網域與品牌上了。」（若想再加亮點：『啟動 M4』自架一台真的 OpenClaw 當 24 小時 AI 機票客服。）
- Any ❌/⚠️ → list each with its fix (B3 spam → finish DKIM/SPF; B4 403 → domain not actually Verified; C2 callback fails → check CMV/`1|OK`; D1 → tighten CORS; D2 → remove key from front-end; E1 → delete test rows) and tell the student to fix then re-run `上線檢查`.
