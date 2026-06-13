---
name: m2-ecpay-subscription-prerequisites
description: Prerequisites before M2 of the Flight Price Notifier course — an ECPay (綠界) merchant (the public stage test merchant is fine for the whole course), the `flight/ecpay` secret, and confirmation that M1.3's notifier works. Use when the student starts M2, or when `m2-ecpay-subscription` / `-checklist` detects ECPay isn't set up.
---

# M2 Prerequisites — ECPay 綠界

## What this skill does

M2 adds one account: **ECPay 綠界**. Unlike Stripe there's **no CLI to install and no live/test "mode" toggle** — you just need merchant credentials (MerchantID / HashKey / HashIV) in the `flight/ecpay` secret. For the whole course you can use ECPay's **public stage test merchant**; applying for a real one is M3 ([[ecpay-go-live]]). This skill stores the secret + confirms the M1.3 notifier carryover.

## When to load this skill

- "M2 環境準備" / any time M2 detects ECPay (`flight/ecpay`) is missing.

## Execution mode

CLI uses `aws` + `curl`/`python3`; Cowork uses AWS MCP + the ECPay 廠商後台 (`vendor.ecpay.com.tw`). `aws` commands `--region us-east-1`. (There is **no `ecpay` CLI** — ECPay is a hosted gateway with a dashboard only.)

## Step 1 — ECPay credentials (stage test merchant is fine)

You don't need a real merchant account to build and test M2. Use ECPay's **public shared stage test merchant** (these are published by ECPay and safe to commit as defaults):

| Field | Stage value |
|---|---|
| `MerchantID` | `3002607` |
| `HashKey` | `pwFHCqoQZGmho4w6` |
| `HashIV` | `EkRm7iFT261dpevs` |

(Optionally register at `vendor.ecpay.com.tw` now to see the 廠商後台 — useful for the 模擬付款 button — but a real, verified MerchantID is **not** required until go-live.)

**Stage test card** (for the whole course): card `4311-9522-2222-2222`, expiry `12/30`, CVV `222`, OTP `1234`. No real money moves.

## Step 2 — Store the `flight/ecpay` secret

```bash
aws secretsmanager describe-secret --secret-id flight/ecpay --region us-east-1 --query "Name" 2>/dev/null \
  || aws secretsmanager create-secret --name flight/ecpay \
       --secret-string '{"merchant_id":"3002607","hash_key":"pwFHCqoQZGmho4w6","hash_iv":"EkRm7iFT261dpevs","env":"stage","amount":"150"}' \
       --region us-east-1
```
Set `amount` to your intended TWD monthly price (integer; e.g. `150` = NT$150). Keep it a realistic amount — ECPay hides credit-card payment below the card minimum (~NT$6–11), so don't use NT$1.

**Verify:**
```bash
aws secretsmanager get-secret-value --secret-id flight/ecpay --region us-east-1 --query SecretString --output text
```
Shows `merchant_id`, `hash_key`, `hash_iv`, `env:"stage"`, and your `amount`.

## Step 3 — Confirm M1.3 carryover

```bash
# the notifier pipeline exists and sends email (M1.2 parser + M1.3 fare-notification + Resend)
aws lambda get-function --function-name flight-parser --region us-east-1 --query 'Configuration.FunctionName'
aws lambda get-function --function-name flight-fare-notification --region us-east-1 --query 'Configuration.FunctionName'
aws secretsmanager describe-secret --secret-id flight/resend --region us-east-1 --query 'Name'
# save_subscription Lambda exists (M1.1) — M2 upgrades it to write pending_payment + build the ECPay recurring form
aws lambda get-function --function-name flight-save-subscription --region us-east-1 --query 'Configuration.FunctionName'
```
If any are missing, finish the corresponding earlier milestone first.

## Verify (all must pass)

- `flight/ecpay` secret exists with stage `merchant_id` + your `amount` ✅
- `flight-parser` + `flight-fare-notification` + `flight/resend` exist (M1.2/M1.3 done) ✅
- `flight-save-subscription` exists (M1.1 done) ✅

## Next step

Return to `m2-ecpay-subscription` Step 1.

## Reference

- [[ecpay-best-practice]] — the CMV + callback rules you'll apply throughout M2.
- ECPay stage test info / 測試帳號: https://developers.ecpay.com.tw/?p=2856
