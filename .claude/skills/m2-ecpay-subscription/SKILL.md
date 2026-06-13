---
name: m2-ecpay-subscription
description: Flight Price Notifier Milestone 2 — set up an ECPay (綠界) 信用卡定期定額 monthly subscription so only paying users get alerts. An ECPay AIO recurring-payment checkout + two callback Lambdas (ReturnURL for the first charge, PeriodReturnURL for renewals) flip subscriptions pending_payment → active → expired in DynamoDB (the callbacks, verified by CheckMacValue, are the source of truth for paid status). Cancelling calls ECPay's CreditCardPeriodAction. Use when the student says "啟動 M2", "start M2", "接金流", "接綠界", "接 ECPay", "做訂閱付款", or "讓只有付費者收得到通知".
---

# M2 — ECPay 定期定額（接金流，只有付費者收得到通知）

## What this skill does

Turns the working **free** notifier (M1) into a **paid** service using **ECPay 綠界** — Taiwan's payment gateway, charging in **TWD**. **This is where the paywall is born** — M1 had no `subscription_status` and emailed anyone; M2 introduces the field, the callbacks that set it, and the parser filter that enforces it:

1. An ECPay **信用卡定期定額** (credit-card recurring) checkout — built as an **AIO auto-submit form**, not an SDK call.
2. `save_subscription` (from M1.1) now **writes `subscription_status = pending_payment`** AND builds the ECPay recurring-checkout form (signed with a **CheckMacValue**), returning its auto-submit HTML so the browser POSTs the user to ECPay's cashier to pay.
3. **Two callback Lambdas** behind API Gateway that **verify the CheckMacValue** (the SOURCE OF TRUTH for paid status) and flip the row's `subscription_status`:
   - **`flight-ecpay-return`** (`POST /ecpay-return`) — receives the **first** authorization result (paid at checkout) → `active`.
   - **`flight-ecpay-period`** (`POST /ecpay-period`) — receives **every subsequent monthly** authorization result → keeps `active`, or `expired` if ECPay reports the recurring run has ended.
   - both **enqueue a `{event_type:"welcome", …}` message to the status SQS queue** (the single `status_notification` consumer emails it — not inline).
4. A **`flight-cancel-subscription`** Lambda (`POST /cancel`) that calls ECPay's **`CreditCardPeriodAction` `Action=Cancel`** to stop future charges, flips the row to `expired`, and enqueues a `{event_type:"cancel", …}` message to the **same** status queue.

> **One notification consumer, routed by `event_type`.** Subscribe and unsubscribe emails both flow through the **same** `flight-status-notification` Lambda — every producer stamps an `event_type` (`"welcome"`/`"cancel"`) on the SQS message and the one consumer branches on it to render the right email. (Don't build two notification Lambdas.)
5. **The `flight-parser` (M1.2) gains an `active`-only filter** — its subscription scan now adds `AND subscription_status = active`. *This* is what makes only paying users get alerts.

End state: a test payment flips a row `pending_payment → active` (and it starts getting alerts); cancelling flips it to `expired` (alerts stop). A `pending_payment` (unpaid) row is never emailed.

> **Why ECPay, not Stripe?** This course targets a Taiwan audience charging in **TWD**. ECPay (綠界) is the standard local gateway and the one the instructor runs in production. The *shape* of M2 is identical to a Stripe paywall — payment flips a status field, a verified callback is the source of truth, the parser gates on `active` — but ECPay's mechanics differ in four ways you must learn (see "Things to watch out for"): **two callbacks instead of one webhook**, **CheckMacValue instead of a signature header**, **cancel is an API call you make, not an event you receive**, and **no SDK/layer needed** (CMV is stdlib `hashlib`).

## When to load this skill

- "啟動 M2" / "start M2" / "接金流" / "接綠界" / "接 ECPay" / "做訂閱付款"

Requires M1 done (`m1-flight-price-checker-checklist` green — the free notifier works). Adds one account: **ECPay 綠界** (start with the shared stage test merchant).

## Execution mode

`aws` CLI + plain `curl`/`python3` here (ECPay has **no CLI** like Stripe's). Cowork: AWS MCP / the ECPay 廠商後台 (`vendor.ecpay.com.tw`) dashboard. `aws` commands `--region us-east-1`.

## Required external accounts (new)

| # | Service | Used for |
|---|---|---|
| 8 | ECPay 綠界 (`ecpay.com.tw`) | 信用卡定期定額 checkout + callbacks |

> For the whole course you can run on ECPay's **shared stage test merchant** — `MerchantID=3002607`, `HashKey=pwFHCqoQZGmho4w6`, `HashIV=EkRm7iFT261dpevs` (public, safe in code as defaults). Applying for a **real** MerchantID (and confirming 定期定額 is enabled on it) is M3 / [[ecpay-go-live]].

## Architecture

```
訂閱表單 ─POST /subscribe─▶ save_subscription Lambda
                              · PutItem subscriptions（M2 起：status=pending_payment）
                              · 組 ECPay 定期定額 AIO 參數：
                                  ChoosePayment=Credit, TotalAmount=PeriodAmount=<月費TWD>,
                                  PeriodType=M, Frequency=1, ExecTimes=999,
                                  ReturnURL=<api>/ecpay-return, PeriodReturnURL=<api>/ecpay-period,
                                  MerchantTradeNo=<unique>, CustomField1=email, CustomField2=route
                              · 算 CheckMacValue（SHA256，stdlib hashlib — 不需 SDK / 不需 layer）
                              · 回 auto-submit HTML form ↩ 前端自動 POST 去 ECPay 收銀台
付款（第一期，當下立即授權）
   ├─ ReturnURL（S2S）──▶ flight-ecpay-return Lambda（paid 狀態的唯一真相來源）
   │                        · 驗 CheckMacValue + MerchantID + RtnCode==1
   │                        · active → UpdateItem DynamoDB subscriptions
   │                        · SendMessage {event_type:"welcome",…} → [SQS status-queue]
   │                        · 回純文字 1|OK
   └─ OrderResultURL（瀏覽器跳轉）──▶ /<site>/account?purchase=success
之後（第 2 期起，每月自動扣款）
   └─ PeriodReturnURL ──▶ flight-ecpay-period Lambda
                           · 驗 CMV；續扣成功維持 active；ECPay 回報結束 → expired · 回 1|OK
退訂
   └─ /account「取消訂閱」─POST /cancel─▶ flight-cancel-subscription Lambda
                           · POST ECPay CreditCardPeriodAction, Action=Cancel（帶原 MerchantTradeNo）
                           · expired → UpdateItem subscriptions
                           · SendMessage {event_type:"cancel",…} → [SQS status-queue]
                                              │
[SQS status-queue] ──▶ flight-status-notification Lambda（一支，依 event_type 分流）──▶ Resend
                          · "welcome" → 歡迎信   · "cancel" → 取消確認信
flight-parser（M1.2）的 scan 加上 AND subscription_status = active ← 付費門檻在這裡生效
```

## Conversational flow

### Step 1 — Store the ECPay merchant credentials

ECPay has no `products`/`prices` objects to create (unlike Stripe) — the **price is just the `TotalAmount` you put in the checkout form**. So Step 1 is only storing the merchant credentials + your monthly amount. Store the secret (check-then-collect — skip if a previous session already created it). For the whole course you may use the public **stage test merchant**; paste to the agent:

ask """
>
My ECPay monthly amount in TWD (fill this in, integer, e.g. 150): <REPLACE>
>
Store the ECPay credentials in AWS Secrets Manager as `flight/ecpay`. Use the public **stage** test merchant (safe to commit) unless I gave you a real one. Region us-east-1. Check first, then create if missing:
>
```bash
aws secretsmanager describe-secret --secret-id flight/ecpay --region us-east-1 --query "Name"
```
>
- If that returns `flight/ecpay`, it already exists — skip.
>
- If ResourceNotFoundException → `aws secretsmanager create-secret --name flight/ecpay --secret-string '{"merchant_id":"3002607","hash_key":"pwFHCqoQZGmho4w6","hash_iv":"EkRm7iFT261dpevs","env":"stage","amount":"<the TWD amount above>"}' --region us-east-1`
>
"""

**Verify before moving on:** `aws secretsmanager get-secret-value --secret-id flight/ecpay --region us-east-1 --query SecretString --output text` shows `merchant_id`, `hash_key`, `hash_iv`, `env:"stage"`, and your TWD `amount`.

### Step 2 — save_subscription: add the status field + build the recurring-checkout form

Update `aws/save_subscription/handler.py` (it had **no** status in M1). It needs a small **CheckMacValue helper** — **stdlib only** (`hashlib`, `urllib.parse`), so **no `stripe`/`requests` layer and no SDK** (a big simplification vs Stripe). See [[ecpay-best-practice]] Rule 2 for the exact CMV algorithm + the 7-character `ecpayUrlEncode` table.

1. On `PutItem`, **now write `subscription_status = "pending_payment"`** (the field is born here) plus a freshly generated unique **`MerchantTradeNo`** (≤20 chars; store it on the row — you need it later to cancel).
2. Build the ECPay AIO **定期定額** params and sign them:
   - `MerchantID` (from `flight/ecpay`), `MerchantTradeNo`, `MerchantTradeDate` (`yyyy/MM/dd HH:mm:ss`), `PaymentType=aio`, `ChoosePayment=Credit`, `EncryptType=1`
   - `TotalAmount=<amount>` **and** `PeriodAmount=<amount>` — **they must be equal** (ECPay rule)
   - `PeriodType=M`, `Frequency=1`, `ExecTimes=999` (monthly; 999 ≈ "indefinite" — ECPay has no true ∞, see watch-out 6)
   - `ItemName`, `TradeDesc` (avoid WAF keywords like `curl`/`python` — see [[ecpay-best-practice]])
   - `ReturnURL=<api>/ecpay-return`, `PeriodReturnURL=<api>/ecpay-period`, `OrderResultURL=<site>/account?purchase=success`
   - `CustomField1=email`, `CustomField2=route` — the join key the callbacks read to find the row
   - compute `CheckMacValue` over all of the above
3. Return an **auto-submit HTML form** (`<form action="https://payment-stage.ecpay.com.tw/Cashier/AioCheckOut/V5" method="post">` with one hidden input per field + a tiny `<script>document.forms[0].submit()</script>`). The browser POSTs it to ECPay. (Unlike Stripe you return *HTML*, not a JSON `checkout_url`.)
4. **Idempotency:** if the row already exists and is `active`, do NOT knock it back to `pending_payment` (preserve a paid user's status). Redeploy.

**Verify before moving on:** `POST /subscribe` writes a `pending_payment` row (with a `merchant_trade_no`) AND returns HTML whose `action` is the ECPay cashier and that contains a `CheckMacValue` hidden field.

### Step 3 — Build the two callback Lambdas (the highest-risk files)

ECPay posts the **first** charge result to `ReturnURL` and **every subsequent** monthly charge to `PeriodReturnURL` — so you build **two** handlers. Both share the same verify-then-flip logic; factor it into one helper (mirrors how My Site's `processEcpayCallback` is shared by two routes).

**`aws/ecpay_return/handler.py`** (`POST /ecpay-return` — first period, source of truth for activation):
1. Read `flight/ecpay` from Secrets Manager.
2. Parse the **form-urlencoded** body (ECPay callbacks are `application/x-www-form-urlencoded`, **not** JSON; handle `isBase64Encoded`).
3. **Verify the CheckMacValue** over the returned fields — **keep empty-string fields in the hash** (ECPay sends `CustomField3=&CustomField4=` and signs them; dropping them gives a wrong hash — this is the single most common ECPay bug, see [[ecpay-best-practice]] Rule 2). Also verify `MerchantID` matches yours.
4. If `RtnCode == "1"` (string!) **and** not a bare `SimulatePaid=1` test (see watch-out 7): `UpdateItem` the `subscriptions` row keyed by `{email, route}` (from `CustomField1/2`) → `subscription_status=active`, store `ecpay_gwsr` + `merchant_trade_no` for idempotency.
5. **Idempotency:** if you've already processed this `gwsr`/`MerchantTradeNo`, skip the write but still ack.
6. **Enqueue `{event_type:"welcome", email, route}` to the status SQS queue** (don't email inline — the single `flight-status-notification` consumer branches on `event_type`).
7. **Reply with the plain-text string `1|OK`, HTTP 200** (any other body → ECPay resends 4×). On a permanent failure (CMV invalid / merchant mismatch) reply `0|<reason>`.

**`aws/ecpay_period/handler.py`** (`POST /ecpay-period` — 2nd charge onward): same verify; on success keep `active` (optionally bump a `last_charged_at`); if ECPay's payload indicates the recurring series has ended, set `expired`. Reply `1|OK`.

Create the **status queue + its consumer** (mirrors the fare-queue pattern from M1.3) and the two routes:
```bash
aws sqs create-queue --queue-name flight-status-queue --region us-east-1
# flight-status-notification Lambda ← event-source mapping from flight-status-queue.
#   ONE consumer for both subscribe + unsubscribe: it reads message["event_type"]
#   ("welcome"|"cancel") and renders/sends the matching email via Resend. Don't build two.
# extend flight-lambda-role: sqs SendMessage (return/period/cancel Lambdas) + Receive/Delete (consumer) on flight-status-queue

# integrations + routes 'POST /ecpay-return' and 'POST /ecpay-period' on the existing flight-api
for fn in flight-ecpay-return flight-ecpay-period; do
  route=${fn#flight-}   # ecpay-return / ecpay-period
  aws lambda add-permission --function-name $fn \
    --statement-id apigw-$route --action lambda:InvokeFunction \
    --principal apigateway.amazonaws.com \
    --source-arn "arn:aws:execute-api:us-east-1:<ACCOUNT_ID>:<ApiId>/*/*/$route" \
    --region us-east-1
done
```

**Verify before moving on:** there's **no `stripe listen` equivalent** — ECPay needs a publicly reachable URL. Two ways to test the callback fires (see [[ecpay-best-practice]]):
- **「模擬付款」** in the ECPay 廠商後台 (stage) → ECPay POSTs `RtnCode=1`/`SimulatePaid=1` to your `ReturnURL`. Fastest way to prove the Lambda is reached. *(Confirm watch-out 7 so it doesn't activate.)*
- A **real test-card** run through the live form (Step 5). Watch `aws logs tail /aws/lambda/flight-ecpay-return --since 5m --region us-east-1` for CMV-verified + `UpdateItem`.

### Step 4 — Turn ON the paywall: add the `active` filter to the parser

This is the step that actually gates alerts. Edit `aws/parser/handler.py` (from M1.2): change the subscription `Scan`'s `FilterExpression` from `route = :r` to **`route = :r AND subscription_status = :active`** (`:active = "active"`). Redeploy the parser.

Now: `pending_payment` and `expired` rows are skipped; only paid (`active`) subscribers are enqueued to the fare queue and emailed. (Old M1 rows that have no `subscription_status` at all also stop matching — re-subscribe + pay to make them `active`, which is the intended paid behavior.)

**Verify before moving on:** invoke the parser with a `pending_payment` row whose target is met → it is NOT enqueued (the guard works). Flip that row to `active` and re-invoke → it IS enqueued.

### Step 5 — Test a real recurring payment end-to-end

ECPay callbacks need a **public** URL, so test against the **deployed** API (there's no local-forwarding tool). Run the full flow: submit the form (writes a `pending_payment` row + returns the auto-submit HTML) → the browser lands on ECPay's cashier → pay with the **stage test card** `4311-9522-2222-2222`, expiry `12/30`, CVV `222`, OTP `1234` → land back on `/account?purchase=success` → confirm the row flips to `active` (the first-period `ReturnURL` callback did it).

**Verify before moving on:**
```bash
aws dynamodb get-item --table-name subscriptions \
  --key '{"email":{"S":"<payer>"},"route":{"S":"TPE-TYO"}}' \
  --region us-east-1
```
Shows `subscription_status=active`, `ecpay_gwsr` + `merchant_trade_no` set. Then invoke the parser → the now-active row is enqueued and emailed (if at/below target). A `pending_payment` payer is NOT.

### Step 6 — Build + test cancellation (an API call, not an event)

Unlike Stripe (where a dashboard cancel *fires* `customer.subscription.deleted`), ECPay cancellation is something **you call**. Build `aws/cancel_subscription/handler.py` (`POST /cancel`):
1. Look up the row's stored `merchant_trade_no`.
2. `POST` to `https://payment-stage.ecpay.com.tw/Cashier/CreditCardPeriodAction` with `MerchantID`, `MerchantTradeNo`, `Action=Cancel`, `TimeStamp`, and a `CheckMacValue` over them.
3. `UpdateItem` the row → `subscription_status=expired`; enqueue `{event_type:"cancel", email, route}` to the **same** `flight-status-queue` (the one `flight-status-notification` consumer sends the cancel email).

Wire a 「取消訂閱」 button on `/account` to `POST /cancel`. Then test:
```bash
curl -s -X POST "<api>/cancel" -H "content-type: application/json" \
  -d '{"email":"<payer>","route":"TPE-TYO"}'
```
**Verify:** the row flips to `expired`; the parser no longer enqueues it (alerts stop). In the ECPay 廠商後台 → 信用卡定期定額訂單查詢, the order shows terminated.

## Things to watch out for

1. **CheckMacValue, not a signature header** — every ECPay callback carries a `CheckMacValue`; verify it on **every** call. The #1 ECPay bug: **dropping empty-string fields** before hashing. ECPay sends (and signs) `CustomField3=&CustomField4=`; your verify must keep them. Drop only `CheckMacValue` itself and truly-absent keys. (See [[ecpay-best-practice]] Rule 2.)
2. **Two callbacks, not one webhook** — first charge → `ReturnURL`; 2nd-onward → `PeriodReturnURL`. **Both** must verify CMV and flip status. If you only build `ReturnURL`, renewals silently never update.
3. **Reply `1|OK` plain text** — anything else (JSON, HTML, quotes, even `OK`) makes ECPay resend the callback 4× over ~20–60 min. Use a `text/plain` response. (See [[ecpay-best-practice]] Rule 3.)
4. **`CustomField1/2` are the join key** — put `email` + `route` there in the checkout form so the callbacks know which DynamoDB row (`{email, route}`) to `UpdateItem`. ECPay echoes them back. (Equivalent to Stripe's metadata — see [[ecpay-best-practice]] Rule 5.)
5. **Callbacks = source of truth** — only the `flight-ecpay-return`/`flight-ecpay-period` Lambdas write `active`. `save_subscription` only writes `pending_payment`; the `OrderResultURL` browser-redirect page is UX-only and must never activate. (See [[ecpay-best-practice]] Rule 1.)
6. **No true "indefinite" subscription** — ECPay's `ExecTimes` is a *count* (`M`: max 999). We use `ExecTimes=999` as "effectively long-term," not infinite-like-Stripe. `PeriodAmount` must equal `TotalAmount`. (See [[ecpay-best-practice]] Rule 6.)
7. **Guard `SimulatePaid`** — the stage 後台「模擬付款」 button (great for testing the callback) sends `SimulatePaid=1`. Verify the CMV and reply `1|OK`, but **do not write `active`** for a bare simulate — else anyone hitting simulate gets the product free. (See [[ecpay-best-practice]] Rule 7.)
8. **The gate lives in the parser, not here** — payment alone doesn't stop emails; the **parser's `active` filter (Step 4)** is what enforces it. Skip Step 4 and paying changes the status but everyone still gets emailed (M1 behavior). Both halves are required.
9. **Cancel is *your* API call** — `CreditCardPeriodAction Action=Cancel`. There's no Stripe-style Customer Portal; the self-service 退訂 is the `/cancel` Lambda you build in Step 6.
10. **No SDK, no layer** — CMV is `hashlib.sha256`; the cancel POST is `urllib`. So M2 **doesn't** add the `stripe`+`requests` layer (that line from the old plan is gone). Lambdas stay stdlib + boto3. (See [[aws-best-practice]].)
11. **TWD is a whole-number currency in ECPay** — `TotalAmount=150` means NT$150. (No ×100 cents trap; that was a Stripe-TWD pitfall.) But ECPay silently hides credit-card payment for amounts below the card minimum (~NT$6–11) — don't test with NT$1.
12. **Stage vs prod** — M2 runs entirely on the **stage** merchant + cashier URL (`payment-stage.ecpay.com.tw`). Applying for a real MerchantID + confirming 定期定額 is enabled + switching to `payment.ecpay.com.tw` is **M3** ([[ecpay-go-live]]).

## Expected duration

90–120 minutes (the CheckMacValue + the two-callback split are fiddly the first time).

## Next step

When `m2-ecpay-subscription-checklist` is green: 「M2 完成！只有付費者收得到通知，取消就停。你的產品會賺錢了。跟我說『啟動 M3』，我們把它掛到你自己的網域、正式開張。」Then load `m3-custom-domain-go-live`.

## Reference

- ECPay 信用卡定期定額: https://developers.ecpay.com.tw/?p=2868
- 定期定額付款結果通知 (ReturnURL 第一期 / PeriodReturnURL 第二期起): https://developers.ecpay.com.tw/?p=5631
- 信用卡定期定額訂單作業 (CreditCardPeriodAction，取消): https://developers.ecpay.com.tw/?p=2900
- CheckMacValue 機制: https://developers.ecpay.com.tw/?p=2902
- [[ecpay-best-practice]] — the callback hard rules (CMV, empty-string fields, `1|OK`, two callbacks, SimulatePaid) for THIS course's Lambda model.
- [[aws-best-practice]] — where `flight/ecpay` lives; the form-body/`isBase64Encoded` rule from the AWS side; why no layer is needed.
- [[ecpay-go-live]] — applying for a real MerchantID + switching to prod in M3.
