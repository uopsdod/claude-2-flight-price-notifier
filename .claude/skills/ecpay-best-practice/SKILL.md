---
name: ecpay-best-practice
description: Hard rules and operational SOP for integrating ECPay (綠界) 信用卡定期定額 (credit-card recurring) checkout + callbacks in the Flight Price Notifier course (M2 — monthly subscription paywall). The callbacks are AWS Lambdas; the "ledger" is the subscription_status field on a DynamoDB row. Use whenever a student is building the recurring-checkout form in save_subscription, the ReturnURL/PeriodReturnURL callback Lambdas, the cancel Lambda, debugging "payment succeeded but the user still isn't active", or hitting CheckMacValue / idempotency / 1|OK / empty-field issues. Sourced from real ECPay callback incidents.
---

# ECPay Best Practice (Flight Price Notifier — M2 subscription paywall)

Battle-tested rules for integrating ECPay **信用卡定期定額 (credit-card recurring) Checkout + callbacks** into M2, where payment is what flips a subscription from `pending_payment` to `active` so the user actually receives price-drop emails. Students hit these in the *first hour* of M2, usually before they've internalized that **the callback — not the browser redirect — is the real payment flow**, and that **ECPay sends TWO callbacks (ReturnURL + PeriodReturnURL), not one webhook.**

When guiding a student through any ECPay-touching code, **apply these rules proactively** — stop them before they break one.

> **Model note (Stripe → ECPay):** an earlier version of this course used Stripe (one webhook, a `stripe-signature` header, a delete-event for cancel, a `stripe`+`requests` Lambda layer). This course is **ECPay 綠界**, charging in **TWD**, on **AWS Lambda**, flipping a **`subscription_status` field on a DynamoDB row**. The *principles* are identical — a verified callback is the source of truth, idempotency, identify-by-stable-key-not-payer-email, gate on `active` — but four mechanics differ and are the heart of these rules: **(1) two callbacks not one webhook**, **(2) CheckMacValue not a signature header**, **(3) cancel is an API call you make, not an event you receive**, **(4) no SDK/layer** (CMV is stdlib `hashlib`). The CMV algorithm + the empty-field bug are ported from the instructor's production My Site ECPay integration.

This is the application-layer sibling of [[aws-best-practice]] (the Lambda/IAM/secrets side of the same callbacks) and [[supabase-best-practice]] (auth-only — ECPay never touches Supabase here; the join key is `email`).

---

## Execution mode: Cowork vs CLI

ECPay is a hosted gateway with **no CLI** (unlike Stripe's). The calling code (the Lambdas) runs identically in both modes; the deltas are around testing the callback and credential management.

| Operation | CLI mode | Cowork mode |
|---|---|---|
| Trigger a test callback to your ReturnURL | ECPay 廠商後台 (stage) →「模擬付款」 on a pending order (Rule 7); or a real stage test-card run | same — the dashboard 模擬付款 button, or a real test-card run |
| Inspect a recurring order / its charges | 廠商後台 → 信用卡定期定額訂單查詢 (`p=2892`) | same dashboard |
| Cancel a recurring series | call `CreditCardPeriodAction Action=Cancel` (your `/cancel` Lambda), or 後台 manual stop | same — your `/cancel` Lambda, or the dashboard |
| Store ECPay credentials | into the **`flight/ecpay`** Secrets Manager secret | same — `aws secretsmanager put-secret-value` |
| Verify CheckMacValue locally | a tiny `python3` `hashlib` script (Rule 2) | same script |

**ECPay credentials live in `flight/ecpay` (Secrets Manager), never in code or the front-end.** There is **no `stripe listen` equivalent** — ECPay can only POST to a *publicly reachable* URL, so you test against the deployed API Gateway (Rule 8), not localhost.

---

## Hard rules

### Rule 1 — The callbacks are the source of truth for `active` — never flip status from the OrderResultURL page

> **The rule:** The `flight-ecpay-return` (ReturnURL) and `flight-ecpay-period` (PeriodReturnURL) Lambdas are the **only** things that set `subscription_status = active` (or `expired`) on a `subscriptions` row. The `OrderResultURL` browser-redirect page (`/account?purchase=success`) is UX-only — it can say "thanks, you're subscribed" but must never call any API that activates the subscription.

**Why:** Three failure modes the callback handles and the redirect can't:
1. **User closes the browser after paying.** ECPay still POSTs the `ReturnURL` (server-to-server); the callback still activates them. If activation lived on the success page, they'd be charged but never `active`, so they'd never get emails. (This is exactly the My Site dual-callback finding — sometimes the S2S `ReturnURL` wins, sometimes the browser does; only the S2S one is guaranteed.)
2. **Network blip on the redirect.** Same shape — charge succeeded, redirect failed, never activated.
3. **Client-side activation is forgeable.** Anyone could hit a "mark me active" endpoint and get the paid product for free. Trusting the redirect = free subscriptions.

**How to apply:**
- The `OrderResultURL` page shows a static "subscription confirmed" message (optionally `GET`s the row to display status, read-only).
- The only `UpdateItem` that writes `active`/`expired` lives in the callback Lambdas (and the `/cancel` Lambda for `expired`).
- The callbacks authenticate via their IAM role + the **CheckMacValue** on the payload (ECPay is not a logged-in user) — no Supabase credential.

---

### Rule 2 — Verify the CheckMacValue on EVERY callback — and KEEP empty-string fields in the hash

> **The rule:** Every ECPay callback carries a `CheckMacValue`. Recompute it over the returned fields and compare before trusting anything. When building the string to hash, **drop only `CheckMacValue` itself and truly-absent keys — keep fields whose value is the empty string** (e.g. `CustomField3=`, `CustomField4=`). ECPay includes those empty fields when it computes the MAC; if you filter them out you hash a different string and **every real callback fails verification**.

**Why:** This is the single most common ECPay bug, and it's *silent* — `CheckMacValue` fails, the Lambda 400s or skips, and the symptom looks like "ECPay isn't sending the callback" when really you're rejecting a valid one. (In My Site this exact bug — filtering `v === ''` — made *every* real callback fail; the fix was to keep empty strings and drop only `CheckMacValue` + truly-undefined keys.)

**The CMV algorithm (SHA256, AIO — ported from the instructor's production code):**
```
1. Drop CheckMacValue; KEEP empty-string fields, drop only truly-absent keys.
2. Sort the remaining keys case-insensitively (A–Z).
3. Join: HashKey={hashKey}&{k1}={v1}&{k2}={v2}&...&HashIV={hashIV}
4. ecpayUrlEncode the whole string: URL-encode, lowercase, then apply
   the .NET ↔ PHP fixups:  %20→+   then restore  - _ . ! * ( )  and  ~ → %7e
5. sha256 hex of that string.
6. UPPERCASE the hex.  → that's the CheckMacValue.
```
```python
import hashlib, urllib.parse
def _ecpay_urlencode(s: str) -> str:
    s = urllib.parse.quote_plus(s).lower()
    for a, b in (("%2d","-"),("%5f","_"),("%2e","."),("%21","!"),
                 ("%2a","*"),("%28","("),("%29",")"),("%7e","%7e")):
        s = s.replace(a, b)
    return s
def gen_cmv(params: dict, hash_key: str, hash_iv: str) -> str:
    items = {k: v for k, v in params.items() if k != "CheckMacValue"}  # KEEP "" values
    body = "&".join(f"{k}={items[k]}" for k in sorted(items, key=str.lower))
    raw = f"HashKey={hash_key}&{body}&HashIV={hash_iv}"
    return hashlib.sha256(_ecpay_urlencode(raw).encode()).hexdigest().upper()
def verify_cmv(params, hash_key, hash_iv) -> bool:
    return params.get("CheckMacValue","").upper() == gen_cmv(params, hash_key, hash_iv)
```
**How to apply:** verify in **both** callback Lambdas (factor into one shared helper). If verification fails, log the recomputed-vs-received MAC and return `0|CheckMacValueInvalid` (HTTP 400) — but first re-check you didn't drop empty fields. (See [[aws-best-practice]] for the same incident from the AWS/body-handling side.)

---

### Rule 3 — Reply with the plain-text string `1|OK` (HTTP 200) — anything else makes ECPay resend 4×

> **The rule:** A successfully-processed callback must respond with the exact body `1|OK`, content-type `text/plain`, HTTP 200. On a permanent failure reply `0|<reason>`. Never return JSON, HTML, quotes, or even a bare `OK`.

**Why:** ECPay's contract is byte-literal: it looks for `1|OK`. Any other body (including `"1|OK"` with quotes, or an API-Gateway-default JSON wrapper) is read as "not acknowledged," so ECPay **resends the callback up to 4 more times, every ~5–15 minutes**. The first delivery says `RtnMsg=交易成功`; resends say `RtnMsg=paid` (English) — a useful tell that your first handling failed. With idempotency (Rule 4) the resends are harmless no-ops, but a handler that *never* returns `1|OK` will get retried forever and then abandoned.

**How to apply:**
```python
def _text(body, status=200):
    return {"statusCode": status, "headers": {"Content-Type": "text/plain; charset=utf-8"}, "body": body}
# success / already-processed:  return _text("1|OK")
# permanent failure:            return _text("0|CheckMacValueInvalid", 400)
```
Do the `UpdateItem` + SQS `SendMessage`, then return `1|OK`. Keep it fast — ECPay (like Stripe) doesn't want you doing slow work before acking.

---

### Rule 4 — Make the callbacks idempotent — ECPay WILL resend; activating twice must be a no-op

> **The rule:** `UpdateItem`-ing a row to `active` must be safe to run more than once, AND the once-only side-effect (the welcome email) must be guarded. Use the ECPay `gwsr` (authorization number) and/or `MerchantTradeNo` as the idempotency key. Always return `1|OK` for an event you've already processed.

**Why:** ECPay resends each callback up to 4× (Rule 3), **and** in this course *two* callbacks can both run authorization logic — the S2S `ReturnURL` and (separately) any browser path — so the same charge can hit you more than once. Setting `subscription_status = active` twice is harmless; **sending a welcome email twice is not.** (My Site proved the resend/dual-path overlap is real in stage and that a `UNIQUE` trade-no is what makes it safe.)

**How to apply:**
- The status write is naturally idempotent (`SET subscription_status = :active`). Good.
- Before processing, check whether you've already recorded this `gwsr`/`MerchantTradeNo` on the row (or in a small processed-set). If so, skip the writes but **still return `1|OK`**.
- The **welcome/cancel email** is the once-only action — decouple it: the producer (callback or cancel Lambda) **enqueues** a message stamped with `event_type` (`"welcome"`/`"cancel"`) to the **status SQS queue**, and the **single** `flight-status-notification` consumer branches on `event_type` and guards on whether it's already greeted this subscription. Don't email inline, and don't build two notification Lambdas — one consumer, routed by the field.

---

### Rule 5 — Carry `email` + `route` in `CustomField1/2` — set them server-side, and key the write off them

> **The rule:** `save_subscription` builds the checkout form with `CustomField1=<email>`, `CustomField2=<route>` (set from the **authenticated** Supabase session, never from a client-supplied body). ECPay echoes them back on every callback; the callback reads them to know **which row** `(email, route)` to `UpdateItem`. Never identify the subscriber by a payer/billing email from the payload.

**Why:** ECPay's `CustomField1..4` are the equivalent of Stripe metadata — the only reliable link from a payment back to your `(email, route)` DynamoDB key. Keying off the cardholder's email instead breaks when the billing email differs from the login email, and is forgeable. Because *your* server sets the CustomFields when the user is authenticated, they're trustworthy.

**How to apply:**
```
# in the checkout form (save_subscription):
CustomField1 = email          # from Supabase session
CustomField2 = route          # e.g. "TPE-TYO"
# in the callback:
email = params["CustomField1"]; route = params["CustomField2"]
ddb.update_item(Key={"email": email, "route": route}, ... status=active)
```
ECPay always returns CustomFields as strings, and **echoes all four even when unset** (`CustomField3=&CustomField4=`) — which is exactly why Rule 2's keep-empty-fields matters.

---

### Rule 6 — `PeriodAmount` must equal `TotalAmount`; `ExecTimes` is a COUNT, not "infinite"

> **The rule:** For 信用卡定期定額 set `ChoosePayment=Credit`, `PeriodType=M`, `Frequency=1`, and `TotalAmount == PeriodAmount` (ECPay requires the first-charge amount to equal the fixed recurring amount). `ExecTimes` is the **total number of charges** — there is no true "until cancelled." Use a large value (`ExecTimes=999`, the monthly max) for an effectively-long-term subscription.

**Why:** This is the biggest *conceptual* gap from Stripe. A Stripe subscription renews forever until cancelled; ECPay 定期定額 runs a **bounded count** of charges (`D`/`M`: max 999, `Y`: max 99) and then stops on its own. If you set `ExecTimes=12` thinking "monthly," the subscription silently ends after a year. And if `PeriodAmount != TotalAmount`, ECPay rejects the order at checkout.

**How to apply:**
- Monthly, effectively-indefinite: `PeriodType=M, Frequency=1, ExecTimes=999`.
- Teach students this is **not** infinite — at 999 months it ends; for a real long-running product you'd re-enroll before exhaustion (out of scope for the course, but say it).
- Keep `TotalAmount` and `PeriodAmount` in lockstep — both come from the single `amount` in `flight/ecpay`.

---

### Rule 7 — Guard `SimulatePaid` — the stage 模擬付款 button must NOT grant access

> **The rule:** ECPay's stage 廠商後台 (`vendor-stage.ecpay.com.tw`) has a「模擬付款」button that POSTs a fake successful result (`RtnCode=1`) **with `SimulatePaid=1`** to your `ReturnURL`/`PeriodReturnURL`. It's the fastest way to test a callback is reached — but the handler must verify the CMV, reply `1|OK`, and **NOT write `subscription_status=active`** when `SimulatePaid == "1"`. Either skip the activation write or record it to a separate test log.

**Why:** 模擬付款 is invaluable for proving "does ECPay reach my Lambda" without a real card — but if the handler activates on it, **anyone with stage-backoffice access (or a replayed payload) gets the paid product free.** (My Site flagged this as a must-fix-before-prod gap: the handler there activated on `RtnCode==1` without checking `SimulatePaid`.)

> **Where to log in (the part that trips everyone up):** the 模擬付款 button lives in the **stage** backoffice **`vendor-stage.ecpay.com.tw`** — you sign in with ECPay's **published shared test login** (a `stagetest*` account + test password from ECPay's 測試帳號 page), **NOT** with the MerchantID. **`3002607` is a MerchantID, not a login** — typing it into the 賣家帳號 field gives `帳號格式錯誤`. An order you paid via `3002607` shows up under this shared stage backoffice (mixed with other testers' orders), not in any private console — your real evidence is the callback in CloudWatch + the DynamoDB row.

**How to apply:**
```python
if params.get("SimulatePaid") == "1":
    # CMV already verified above; ack but don't grant
    return _text("1|OK")
# real payment → UpdateItem active ...
```
Use 模擬付款 freely in stage to confirm reachability; rely on a **real stage test-card** run to confirm the *activation* path.

---

### Rule 8 — There's no `stripe listen` — ECPay needs a PUBLIC URL; test against the deployed API

> **The rule:** ECPay can only POST callbacks to a publicly reachable `https://` URL on port 80/443. `localhost` / ngrok-with-a-weird-port won't receive `ReturnURL`/`PeriodReturnURL`. Test against the **deployed** API Gateway URL (or your M3 custom domain).

**Why:** Students coming from Stripe expect a local-forwarding tool; ECPay has none. A `ReturnURL` of `http://localhost:3000/...` simply never gets called, and the student waits forever wondering why the row never flips. ECPay also only honors **port 80/443** — an API-Gateway URL is fine; a `:3300` dev port is not.

**How to apply:**
- Deploy first, then test. Use **模擬付款** (Rule 7) for a fast "is my Lambda reached" check, and a **real stage test-card** run for the full path.
- Watch `aws logs tail /aws/lambda/flight-ecpay-return --since 5m --region us-east-1` for CMV-verified + `UpdateItem`.
- If 模擬付款 in the backoffice errors, the usual causes are: ReturnURL not public, a firewall blocking ECPay's source IP, or the handler replying something other than `1|OK`.

---

### Rule 9 — Cancel is an API call you make (`CreditCardPeriodAction`), not an event you receive

> **The rule:** To stop a recurring subscription, your `/cancel` Lambda must `POST` to `…/Cashier/CreditCardPeriodAction` with `MerchantID`, the original `MerchantTradeNo`, `Action=Cancel`, `TimeStamp`, and a `CheckMacValue`. Then `UpdateItem` the row → `expired` and enqueue the cancel email. There is **no ECPay equivalent of `customer.subscription.deleted`** arriving on its own.

**Why:** Stripe sends a delete-event when a subscription is cancelled (in the dashboard or via API), so its webhook can react. ECPay doesn't push an unsolicited "cancelled" callback — **you** initiate the cancel and **you** flip the status. If a student waits for a callback to mark `expired`, it never comes and the user keeps getting (and being charged for) the subscription.

**How to apply:**
- Store `merchant_trade_no` on the `subscriptions` row at subscribe time (you need it to cancel).
- `/cancel` Lambda: build `{MerchantID, MerchantTradeNo, Action: "Cancel", TimeStamp}` + CMV, POST it (stdlib `urllib`), then `UpdateItem expired` + enqueue cancel email.
- There's **no Stripe Customer Portal** — the self-service 退訂 button on `/account` calls *your* `/cancel` route. (A failed recurring charge can also end the series — see Rule 10.)
- **`ReAuth` (re-authorize a failed charge) cannot be tested on the stage merchant** — only `Cancel` is testable on stage. Don't build the course around verifying `ReAuth` end-to-end.

---

### Rule 10 — Set `expired` on ECPay's 6-strikes termination, not the first failed charge — and use the query API as the safety net

> **The rule:** A failed monthly charge does **not** mean "cancel the subscription." ECPay auto-retries: failures **1–3** → retry every 3–5 days (monitor, don't act); **4–5** → longer-interval retry (warn the customer); **6th consecutive failure → ECPay auto-terminates the contract.** Only flip the row to `expired` when ECPay signals the series has actually ended, not on a single `RtnCode != 1` on `PeriodReturnURL`. And because `PeriodReturnURL` notifies **only once per cycle**, when you miss one, **don't guess — query `QueryCreditCardPeriodInfo`** for the real authorization state.

**Why:** Treating the first failed renewal as `expired` cuts off a paying customer whose card merely had a transient decline that ECPay will successfully retry days later. Conversely, never reacting means a genuinely-dead card keeps a row `active` forever. The 6-strikes rule is ECPay's actual lifecycle; mirror it. And the "notify only once" guarantee means a dropped/4xx'd period callback can leave you out of sync — the query API is the authoritative reconciliation.

**How to apply:**
- `flight-ecpay-period` on `RtnCode == "1"` → keep `active` (optionally record `last_charged_at`, `TotalSuccessTimes`). On `RtnCode != "1"` → **log a failed-attempt counter, don't expire yet**; optionally email the customer to update their card around attempt #3.
- Treat the series as ended (→ `expired`) when ECPay's payload/Query indicates termination (the 6th failure auto-cancels), or when *you* called `Cancel` (Rule 9).
- **Reconciliation Lambda / on-demand check:** `POST …/Cashier/QueryCreditCardPeriodInfo` with `{MerchantID, MerchantTradeNo, TimeStamp}` + CMV → returns the order's executed/successful counts and per-charge records. Use it to recover a missed `PeriodReturnURL` and to drive `expired` decisions. (Deep field reference: the official **[[ecpay]]** skill, `guides/01-payment-aio.md` 定期定額 section + `QueryPeridicTrade.php`.)

---

## What ECPay IS / is NOT in M2

| IS (M2) | is NOT (M2) |
|---|---|
| **信用卡定期定額** (monthly recurring), `ChoosePayment=Credit` | One-time AIO payment / 分期 / ATM / CVS |
| Stage test merchant — test card `4311-9522-2222-2222`, OTP `1234` | Real charges — needs a real MerchantID + 定期定額 enabled ([[ecpay-go-live]], M3) |
| An **AIO auto-submit HTML form** (you return HTML) | An SDK call returning a JSON checkout URL (that was Stripe) |
| **Two callbacks** (ReturnURL + PeriodReturnURL), verified by **CheckMacValue** | One webhook with a signature header |
| Cancel via **`CreditCardPeriodAction Action=Cancel`** (you call it) | A self-arriving cancel event / a Customer Portal |
| The callbacks flip a **DynamoDB `subscription_status`** | A credits ledger / Supabase tables |
| **stdlib only** (`hashlib` for CMV, `urllib` for the cancel POST) | A `stripe`+`requests` Lambda layer (not needed) |
| TWD whole-number amounts (`TotalAmount=150` = NT$150) | A cents/×100 amount (that was the Stripe-TWD trap) |

---

## Things to actively watch out for

1. **Filtering empty-string fields before hashing** → kills CheckMacValue verification (Rule 2). When a callback "never arrives" but ECPay's backoffice shows the order paid, suspect this first — you're rejecting a valid callback.
2. **Only building the ReturnURL handler** → the first charge activates, but every monthly renewal (`PeriodReturnURL`) silently does nothing (Rule 1/Rule 9 region). Build both.
3. **Replying anything but `1|OK`** → ECPay resends 4× (Rule 3). A JSON/HTML body or quotes counts as "not acked."
4. **Callback errors live in CloudWatch**, not the browser — `aws logs tail /aws/lambda/flight-ecpay-return --follow …`. ECPay's S2S POST never touches DevTools.
5. **`RtnCode` is a STRING `"1"`** in the form-POST callback, not the integer `1` — `if params["RtnCode"] != "1":` (the AES-JSON invoice/logistics APIs use an integer; this AIO callback does not).
6. **`SimulatePaid=1` must not grant** (Rule 7) — verify CMV, reply `1|OK`, don't activate.
7. **Testing with NT$1** → ECPay silently hides credit-card payment below the card minimum (~NT$6–11); the cashier shows only wallets and the student thinks the card "disappeared." Use a realistic amount (≥ ~NT$30 for stage testing).
8. **`NEXT_PUBLIC`-style trailing newline in a URL env** → a `\n` in `ReturnURL`/`OrderResultURL` gets signed into the CMV and ECPay's recomputed MAC differs → CMV Error. `.strip()` any URL you build from an env var.
9. **Different services have different HashKey/HashIV** — 金流, 電子發票, and 物流 each have their own keypair in the backoffice. M2 only uses 金流; don't mix in an invoice keypair.
10. **Don't do slow work before `1|OK`** — `UpdateItem` + SQS `SendMessage`, then ack; the status-SQS consumer does the actual emailing.
11. **`%26`/`%3C` in callback params need `urldecode` first** — ECPay's doc warns that any field value containing `%26`(`&`) or `%3C`(`<`) must be `urldecode`d before you use/verify it, or the call fails. `urllib.parse.parse_qs(..., keep_blank_values=True)` already decodes percent-escapes for you — just don't double-encode when recomputing the CMV.
12. **Monthly billing-day edge case** (`PeriodType=M`) — ECPay charges on the same day-of-month as the first charge; **if that day doesn't exist in a month (e.g. the 31st), it bills on the last day of that month**. Harmless for us (amount is fixed), but know it before a customer queries "why charged on the 28th." (Our daily-`D` test path sidesteps this entirely.)
13. **First auth must succeed or there's no schedule** — *「若第一次授權失敗,此訂單不會進入排程,需重新建立一筆訂單」*. A failed first charge yields **no** `PeriodReturnURL` ever; the row stays `pending_payment` and the user must re-subscribe. Don't expect renewals from an order whose first auth failed.

---

## Out of scope for M2 (deferred)

- **Real (prod) merchant + live charging** — M3 / [[ecpay-go-live]] (apply for a MerchantID, confirm 定期定額 is enabled, switch to `payment.ecpay.com.tw`).
- **電子發票 (e-invoice)** — a separate ECPay service with its own keypair; add `InvoiceMark=Y` later if needed.
- **ATM / CVS / 超商 / 分期** — M2 is credit-card recurring only.
- **退款 (refund)** — handled in the ECPay backoffice or a later `DoAction` integration; not in M2.
- **Apple Pay / wallets** — `ChoosePayment=Credit` only for the recurring flow.

---

## Cross-references

- [[m2-ecpay-subscription]] — where the recurring-checkout form (in `save_subscription`) + the two callback Lambdas + the cancel Lambda are written.
- [[m2-ecpay-subscription-prerequisites]] — ECPay account + the `flight/ecpay` secret + the stage test merchant.
- [[m2-ecpay-subscription-checklist]] — verifies CMV handling, the two callbacks, idempotency, and the `active` gate.
- [[aws-best-practice]] — the form-body/`isBase64Encoded` handling from the AWS side; where `flight/ecpay` lives; why no layer is needed.
- [[supabase-best-practice]] — ECPay never touches Supabase here (auth-only); the join key is `email`.
- [[ecpay-go-live]] — applying for a real MerchantID + switching to prod in M3.
- ECPay 信用卡定期定額: https://developers.ecpay.com.tw/?p=2868 · 定期定額結果通知: https://developers.ecpay.com.tw/?p=5631 · 定期定額訂單作業: https://developers.ecpay.com.tw/?p=2900 · CheckMacValue: https://developers.ecpay.com.tw/?p=2902
