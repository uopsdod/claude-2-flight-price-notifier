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

### Section D — Gating works (the point of M2)
- **D0** The parser now filters on status (Step 4 was applied) — invoking the parser for a route with a `pending_payment` row whose target is met does NOT enqueue it:
  ```bash
  aws lambda invoke --function-name flight-parser \
    --payload '{"origin":"TPE","destination":"TYO","route":"TPE-TYO"}' /tmp/p.json \
    --region us-east-1
  aws logs tail /aws/lambda/flight-parser --since 3m --region us-east-1 | grep -iE "active|skip|enqueue"
  ```
- **D1** The now-`active` row (target above live fare) **is** enqueued + emailed when the parser runs → fare email arrives.
- **D2** A `pending_payment` (unpaid) row is NOT enqueued/emailed. Confirms payment gates alerts.

### Section E — Cancellation (an API call you make)
- **E1** The cancel Lambda exists and `POST /cancel` calls `CreditCardPeriodAction` and flips the row to `expired`:
  ```bash
  curl -s -X POST "<api>/cancel" -H "content-type: application/json" -d '{"email":"pay@test.com","route":"TPE-TYO"}'
  aws dynamodb get-item --table-name subscriptions \
    --key '{"email":{"S":"pay@test.com"},"route":{"S":"TPE-TYO"}}' \
    --region us-east-1 --query 'Item.subscription_status'
  ```
  Expect `expired`. A **cancel** email also arrives (same status consumer, `{event_type:"cancel"}`). In the 後台 → 信用卡定期定額訂單查詢, the series shows terminated.
- **E2** The now-`expired` row is no longer enqueued/emailed on the next parser run.

## Reporting

| Check | Status | Notes |
|---|---|---|
| A1 flight/ecpay secret | ✅/❌ | |
| A2 checkout form (CMV + Period*) | ✅/❌ | |
| B1 both callback Lambdas | ✅/❌ | return + period |
| B2 CMV verified + SimulatePaid guarded | ✅/❌ | the fiddly one |
| B3 payment → active | ✅/❌ | the key one |
| B4 renewal → PeriodReturnURL (daily test) | ✅/❌/⚠️ | ⚠️ if next-day check pending |
| C0 status queue + 1 consumer | ✅/❌ | |
| C1 welcome email sent | ✅/❌ | event_type routing |
| D0 parser filters on active (Step 4) | ✅/❌ | the gate itself |
| D1 active → emailed | ✅/❌ | |
| D2 pending_payment → not emailed | ✅/❌ | gating proof |
| E1 cancel → expired (+ cancel email) | ✅/❌ | API call, not event |
| E2 expired → not emailed | ✅/❌ | |

**Verdict:**
- All ✅ → 「M2 驗收通過 ✅ 產品會賺錢了，只有付費者收得到通知。READY for M3。跟我說『啟動 M3』來掛自己的網域、正式開張。」
- Any ❌ → name failures + recovery:
  - CMV reject / callback "never arrives" but 後台 shows paid → you're **dropping empty-string fields** before hashing; keep `CustomField3=`/`CustomField4=` ([[ecpay-best-practice]] Rule 2).
  - not flipping → check `CustomField1/2` (email+route) + `UpdateItem` + IAM DynamoDB perms; only the callbacks write `active`.
  - renewals don't update → you only built `ReturnURL`; add the `PeriodReturnURL` handler ([[ecpay-best-practice]] Rule 1/9).
  - 模擬付款 grants free access → guard `SimulatePaid` (Rule 7).
  - gating wrong → confirm the **parser's** Scan filter now includes `subscription_status = active` (Step 4) — payment without the filter still emails everyone.
  - cancel does nothing → cancel is `CreditCardPeriodAction Action=Cancel` that **you** call, not an event you wait for (Rule 9).
  
  then re-run `驗收 M2`.
