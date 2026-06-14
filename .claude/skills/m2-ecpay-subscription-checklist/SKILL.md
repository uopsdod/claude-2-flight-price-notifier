---
name: m2-ecpay-subscription-checklist
description: Flight Price Notifier Milestone 2 verification — confirms the ECPay recurring checkout works, the callbacks verify CheckMacValue and flip subscriptions active/expired in DynamoDB, cancel calls CreditCardPeriodAction, and only paying users get alerts. Use when the student says "驗收 M2", "check M2", or after `m2-ecpay-subscription` Step 6.
---

# M2 — ECPay Checklist

## What this skill does

Confirms the paywall really works end-to-end: recurring checkout → callback (CMV-verified) → `active`; cancel → `expired`; and the active-only gating actually controls who gets emailed. Emits `READY for M3`. Run after `m2-ecpay-subscription` Step 6.

## Execution mode

CLI uses `aws`/`curl`/`python3`; Cowork uses AWS MCP + the ECPay 廠商後台. `aws` commands `--region us-east-1`. (No `ecpay` CLI — use the dashboard 模擬付款 button + real stage test-card runs.)

## How to run

Run each check and report. Ask for the API base URL and a test inbox. (Subscription rows are read from DynamoDB with `aws dynamodb get-item`.)

### Section A — ECPay checkout form
- **A1** The `flight/ecpay` secret exists with stage `merchant_id` + an `amount`: `aws secretsmanager get-secret-value --secret-id flight/ecpay --region us-east-1 --query SecretString --output text`.
- **A2** `POST /subscribe` returns an **auto-submit HTML form** whose `action` is the ECPay cashier and that contains a `CheckMacValue` hidden field + `PeriodType`/`PeriodAmount`:
  ```bash
  curl -s -X POST "<api>/subscribe" -H "content-type: application/json" \
    -d '{"email":"pay@test.com","origin":"TPE","destination":"TYO","depart_month":"2026-07","target_price":400}' \
    | grep -oE 'AioCheckOut/V5|CheckMacValue|PeriodType'
  ```
  Expect all three tokens. (Also confirm a `pending_payment` row with a `merchant_trade_no` was written.)

### Section B — Callbacks verify CMV + flip to active
- **B1** Both callback Lambdas exist: `for fn in flight-ecpay-return flight-ecpay-period; do aws lambda get-function --function-name $fn --region us-east-1 --query 'Configuration.FunctionName'; done`
- **B2** CheckMacValue verification works (no rejects). Trigger the first-period callback via the stage 後台「模擬付款」 (or a real test-card run) and watch logs:
  ```bash
  aws logs tail /aws/lambda/flight-ecpay-return --since 5m --region us-east-1 | grep -iE "verified|CheckMacValue|active|1\|OK|error"
  ```
  Should show CMV verified + `UpdateItem` + replied `1|OK`, no CheckMacValueInvalid. **And** a bare 模擬付款 (`SimulatePaid=1`) must NOT grant active (the row stays `pending_payment`).
- **B3** **The decisive test:** complete a real **stage test-card** payment (`4311-9522-2222-2222`, `12/30`, CVV `222`, OTP `1234`) via the form → the row flips to `active`:
  ```bash
  aws dynamodb get-item --table-name subscriptions \
    --key '{"email":{"S":"pay@test.com"},"route":{"S":"TPE-TYO"}}' \
    --region us-east-1
  ```
  Expect `subscription_status=active`, `ecpay_gwsr` + `merchant_trade_no` set.
- **B4** *(renewal — `PeriodReturnURL`/`flight-ecpay-period`; optional/time-gated)* To verify the renewal path the faithful way, subscribe once with a **daily** period (`PeriodType=D, Frequency=1, ExecTimes=2`) and pay the first charge **successfully** (a failed first auth never enters the scheduler). **The next day**, confirm the scheduler fired the 2nd charge into your period handler:
  ```bash
  aws logs tail /aws/lambda/flight-ecpay-period --since 24h --region us-east-1 | grep -iE "verified|TotalSuccessTimes|1\|OK|error"
  ```
  Expect CMV-verified, replied `1|OK`, `TotalSuccessTimes=2`, no `SimulatePaid`. *(Fast smoke-only alternative: 模擬付款 on the recurring order → reaches `flight-ecpay-period` with `SimulatePaid=1`; proves reachability + CMV + `1|OK` but not the real bookkeeping — see the M2 skill Step 3.)* Mark ⚠️ "pending next-day check" if you ran the checklist same-day.

### Section C — Status-change email (one consumer, routed by event_type)
- **C0** The status queue + its single consumer exist: `aws sqs get-queue-url --queue-name flight-status-queue --region us-east-1` and `aws lambda get-function --function-name flight-status-notification --region us-east-1 --query 'Configuration.FunctionName'`.
- **C1** After B3, a **welcome** email arrives at the test inbox (the `flight-ecpay-return` callback enqueued `{event_type:"welcome"}` → the one `flight-status-notification` consumer sent it via Resend).

- **B5** *(`OrderResultURL` returns 302, not 405)* The browser-return endpoint redirects instead of erroring. ECPay delivers it as a **POST**:
  ```bash
  curl -s -o /dev/null -w "%{http_code}\n" -X POST "<api>/ecpay-result" -d "RtnCode=1"
  ```
  Expect **`302`** (Location → `/app?purchase=success`), **NOT `405`**. A 405 means `OrderResultURL` points at the static SPA (Rule 11) — the payment still works but the UX is broken.

### Section D — Gating works, grace-aware (the point of M2)
- **D0** The parser gate (Step 4) is **grace-aware**, not plain `active` — invoking the parser for a route with a `pending_payment` row whose target is met does NOT enqueue it:
  ```bash
  aws lambda invoke --function-name flight-parser \
    --payload '{"origin":"TPE","destination":"TYO","route":"TPE-TYO"}' /tmp/p.json \
    --region us-east-1
  aws logs tail /aws/lambda/flight-parser --since 3m --region us-east-1 | grep -iE "active|cancelled|skip|enqueue|expired"
  ```
- **D1** The now-`active` row (target above live fare) **is** enqueued + emailed when the parser runs → fare email arrives.
- **D2** A `pending_payment` (unpaid) row is NOT enqueued/emailed. Confirms payment gates alerts.
- **D3** A `cancelled` row with a **future** `current_period_end` **IS** still enqueued (grace). A `cancelled` row with a **past** `current_period_end` is NOT, and the parser flips it to `expired` on that run.

### Section E — Cancellation (an API call you make; grace, not instant expiry)
- **E1** The cancel Lambda exists; `POST /cancel` calls `CreditCardPeriodAction` and flips the row to **`cancelled`** (NOT `expired`), preserving `current_period_end`:
  ```bash
  curl -s -X POST "<api>/cancel" -H "content-type: application/json" -d '{"email":"pay@test.com","route":"TPE-TYO"}'
  aws dynamodb get-item --table-name subscriptions \
    --key '{"email":{"S":"pay@test.com"},"route":{"S":"TPE-TYO"}}' \
    --region us-east-1 --query 'Item.{status:subscription_status,end:current_period_end}'
  ```
  Expect `status=cancelled` with `current_period_end` set. A **cancel** email also arrives (same status consumer, `{event_type:"cancel"}`). In the 後台 → 信用卡定期定額訂單查詢, the series shows terminated (no more renewals). *(Stage cancel of a never-paid synthetic order returns `90100150 不存在的訂單編號` — expected; the Lambda should log it and still cancel locally, not treat it as a failure.)*
- **E2** A `cancelled`-in-grace subscriber can **update their target price** in place (JSON response from `/subscribe`, no re-payment, status stays `cancelled`).
- **E3** Lifecycle end-to-end: `pending_payment → active → cancelled (grace, still alerted) → expired` (after `current_period_end` passes, via the parser). The expired row is no longer enqueued/emailed.

## Reporting

| Check | Status | Notes |
|---|---|---|
| A1 flight/ecpay secret | ✅/❌ | |
| A2 checkout form (CMV + Period*) | ✅/❌ | |
| B1 both callback Lambdas | ✅/❌ | return + period |
| B2 CMV verified + SimulatePaid guarded | ✅/❌ | the fiddly one |
| B3 payment → active (+ current_period_end) | ✅/❌ | the key one |
| B4 renewal → PeriodReturnURL (daily test) | ✅/❌/⚠️ | ⚠️ if next-day check pending |
| B5 OrderResultURL → 302 not 405 | ✅/❌ | the 405-after-paying bug |
| C0 status queue + 1 consumer | ✅/❌ | |
| C1 welcome email sent | ✅/❌ | event_type routing |
| D0 parser gate grace-aware (Step 4) | ✅/❌ | the gate itself |
| D1 active → emailed | ✅/❌ | |
| D2 pending_payment → not emailed | ✅/❌ | gating proof |
| D3 cancelled-in-grace emailed; grace-expired flipped | ✅/❌ | grace period |
| E1 cancel → cancelled (NOT expired) + email | ✅/❌ | API call, grace not instant |
| E2 cancelled-in-grace can update target | ✅/❌ | in-place, no re-pay |
| E3 lifecycle → expired after period passes | ✅/❌ | parser lazily expires |

**Verdict:**
- All ✅ → 「M2 驗收通過 ✅ 產品會賺錢了，只有付費者收得到通知。READY for M3。跟我說『啟動 M3』來掛自己的網域、正式開張。」
- Any ❌ → name failures + recovery:
  - CMV reject / callback "never arrives" but 後台 shows paid → you're **dropping empty-string fields** before hashing; keep `CustomField3=`/`CustomField4=` ([[ecpay-best-practice]] Rule 2). For a `~` in any value, you may be using the buggy `ecpayUrlEncode` — validate against `ecpay/test-vectors/checkmacvalue.json` (Rule 2).
  - not flipping → check `CustomField1/2` (email+route) + `UpdateItem` + IAM DynamoDB perms; idempotency on **`MerchantTradeNo` not `gwsr`** (`gwsr` is empty on recurring — Rule 4).
  - **405 right after paying** → `OrderResultURL` points at the static SPA; add the `flight-ecpay-result` 302 Lambda (Rule 11). Payment still succeeded.
  - renewals don't update → you only built `ReturnURL`; add the `PeriodReturnURL` handler ([[ecpay-best-practice]] Rule 1/9).
  - **cancel expires instantly instead of granting grace** → cancel must set `cancelled` + keep `current_period_end`, and the parser serves `cancelled`-in-grace + lazily expires (Rules 9, 12). Don't set `expired` in the cancel Lambda.
  - 模擬付款 grants free access → guard `SimulatePaid` (Rule 7).
  - cancel does nothing → cancel is `CreditCardPeriodAction Action=Cancel` that **you** call, not an event you wait for (Rule 9). `90100150` on a never-paid order is expected.
  - emails not arriving → Resend sandbox only reaches your own account email (verify a domain at M3).
  
  then re-run `驗收 M2`.
