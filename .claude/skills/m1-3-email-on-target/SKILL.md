---
name: m1-3-email-on-target
description: Flight Price Notifier Milestone 1.3 — actually send the price-drop email. A flight-fare-notification Lambda consumes the fare SQS queue (from M1.2), dedups against the notification_history DynamoDB table (24h floor + configurable re-alert thresholds), and emails the subscriber via Resend. NO payment guard in M1 — anyone whose target is met gets the email. Use when the student says "啟動 M1.3", "start M1.3", "做降價通知 email", or "達標寄信".
---

# M1.3 — Email on Target（達標就真的寄出降價通知 email）

## What this skill does

M1.2 left matching subscribers on the **fare SQS queue**. M1.3 adds the **consumer** that turns a queued match into a real email:

1. A **`flight-fare-notification` Lambda** triggered by the **fare SQS queue** (event-source mapping).
2. For each message `{email, route, cheapest, target_price}`, it **dedups against `notification_history`** and, if it should send, builds the email with `flightproxy/email_render.py` and **POSTs to Resend**, then writes a `notification_history` row.
3. **Dedup rules (all env-configurable):** send only if there's **no history row in the last `NOTIFY_FLOOR_HOURS` (24h)** for this `(email, route)` — UNLESS the new fare is **meaningfully cheaper** than the last alerted price (`≥ REALERT_PCT` % lower, default 20, OR `≥ REALERT_ABS_TWD` lower, default 2000). This gives "one alert per drop, 24h floor, but a notably better deal still gets through."

End state: a real email lands in the inbox when a watched route hits the target — with **no duplicate spam**, and **no payment required** (M1 has no guard).

> **NO payment guard in M1.** Every subscriber whose target is met is emailed — there's no `subscription_status` check anywhere (that attribute doesn't exist until M2). M2 adds the `active`-only filter (in the parser) so only paying users reach this point.

**Why email, not SMS:** US SMS needs A2P 10DLC carrier registration (10–15 days, paid account) — impractical for a live course. Resend sends to any inbox immediately. (SMS via Twilio is a documented later upgrade.)

## When to load this skill

- "啟動 M1.3" / "start M1.3" / "做降價通知 email" / "達標寄信"

Requires M1.2 done (`m1-2-fetch-prices-on-schedule-checklist` green — the parser enqueues matches to `flight-fare-queue`). Adds one account: **Resend**.

## Execution mode

`aws` CLI here (Cowork: AWS MCP / student terminal). All commands `--region us-east-1`.

## Required external accounts (new)

| # | Service | Used for |
|---|---|---|
| 7 | Resend (`resend.com`) | sending the alert email |

## Architecture

M1.3 **builds the Notification box** (right) — the consumer side of the **SQS** queue M1.2 fills. The `flight-fare-notification` Lambda drains the queue, dedups against **Notification History [DynamoDB]**, and sends via **Email [Resend]**. Everything left of the SQS is M1.1+M1.2 (shown for context).

```
 ┌──── Flight Fare Checker (M1.1 + M1.2) ───────────┐         ┌──── Notification (M1.3) ─────────────────┐
 │  ┌──────────┐  ┌─────────┐   ┌──────────────┐    │         │           ┌────────────────────────┐      │
 │  │  Event   │─▶│ Parser  │──▶│ Parser (×N)  │    │ ┌─────┐ │           │ Notification History   │      │
 │  │  Bridge  │  │ Wrapper │   │   λ  λ  λ     │───────▶│ SQS │─┼──┐        │ [DynamoDB]  (dedup)    │      │
 │  └──────────┘  └────┬────┘   └──────┬───────┘    │ └─────┘ │  │        └───────────┬────────────┘      │
 │      admin ✈ ─▶ Flight Routes [S3]  ▲ Travelpayouts│        │  ▼  query newest ──▲──┘ PutItem(sent_at)  │
 │                  Subscriptions [DynamoDB] (M1.1)  │         │ ┌──────────────────┴───────────────────┐ │
 │                  ▲ scan (subscriber, target price)│         │ │  Flight Fare Notification  λ          │ │
 └───────────────────────────────────────────────────┘        │ │   · 24h floor? or ≥20% / ≥NT$2000?     │ │
   message → {1.from 2.to 3.subscriber 4.target price 5.flight link} │   · email_render → POST Resend         │ │
                                                                │ └──────────────────┬───────────────────┘ │
                                                                └────────────────────┼─────────────────────┘
                                                                                     ▼
                                                                            ┌────────────────┐
                                                                            │ Email [Resend] │  ◀ alert lands
                                                                            └────────────────┘

 Legend:  ▮ orange = manual input (Flight Routes [S3])   ▮ teal = main component (λ)
          ▮ pink = user data (Subscriptions / Notification History [DynamoDB])   ▮ grey = SQS / 3rd-party / shared Lambda
```

**Operational sequence (the consumer):**

```
[SQS flight-fare-queue]（M1.2 丟進來的達標訂閱者）
   ─event-source mapping─▶ [flight-fare-notification Lambda]
        對每則訊息 {email, route, cheapest, target_price}：
          · Query notification_history (pk="email#route") 最新一筆
          · 該寄嗎？ 24h 內沒寄過 OR 這次比上次便宜 ≥20% 或 ≥NT$2000  → 寄
          · email_render.py 產生信（NT$ 標價 headline + 約 US$ 補充 + 立即訂購）→ POST Resend
          · PutItem notification_history（email, route, sent_at, price）
```

## Conversational flow

### Step 1 — Confirm the Resend secret (created in the prereq)

The **`flight/resend`** secret was created **and the key verified** in `m1-3-email-on-target-prerequisites` (Step 1 — it stored `{"api_key","from"}` and proved a real send via the throwaway `flight-resend-test` Lambda, since the Cowork sandbox can't POST to `api.resend.com` directly). So there's nothing to create here — just confirm it's present. Paste to the agent:

ask """
>
Confirm the Resend secret exists (don't print the value): `aws secretsmanager describe-secret --secret-id flight/resend --region us-east-1 --query "Name"` — expect `flight/resend`.
>
"""

If it's missing → go back and run the M1.3 prereq Step 1. (Sending stays from `onboarding@resend.dev` until M3 verifies your own domain.)

### Step 2 — Write the fare-notification Lambda (consumer + dedup)

This is a **single self-contained `index.py`** (handler `index.handler`) — you write the renderer functions inline (Step 2 box below). It's **too big for inline CFN** (the folded HTML/text renderer is ~5–6 KB, over the 4096-char cap — and the handler mixes single + double quotes, which breaks shell-escaping a CFN template body), so it deploys via the **S3 `flight-seed` bridge** (Method 2), like the M1.2 parser. Triggered per SQS message, it:
1. Read `flight/resend` from Secrets Manager (for the API key + `from`).
2. For the message's `{email, route}`, **`Query notification_history`** on `pk = f"{email}#{route}"`, newest first, limit 1.
   - **Key schema (matters for the query):** `notification_history` is **`pk` (HASH, type S)** + **`sent_at` (RANGE/sort key, type S — ISO-8601 UTC string, e.g. `2026-06-07T12:00:00Z`)**. Because `sent_at` is a **sortable String** sort key, `Query … ScanIndexForward=False, Limit=1` returns the **latest** alert for that pk. **Don't** store `sent_at` as an epoch **Number** — that changes the range-key type and breaks the table / the "newest first" ordering.
3. **Decide to send** (the configurable rules — read from env vars):
   - If no recent row, or the last `sent_at` is **older than `NOTIFY_FLOOR_HOURS`** → **send**.
   - Else, within the floor, send only if the new fare is meaningfully cheaper than the last alerted `price`:
     `new <= last * (1 - REALERT_PCT/100)` **OR** `(last - new) >= REALERT_ABS_TWD`.
   - Otherwise **skip** (log "skipped (deduped)").
4. **Build the email** from the message's **`cheapest` (TWD)** as the headline + the optional **`cheapest_usd` (USD)** as a supplementary line:
   - `subject(fare)` → 「✈️ 台北 → 東京 降價通知！NT$9,325 已達標」 — leads with **NT$** (the gating currency).
   - `render_html(fare, target_price, usd_price=…)` → cheapest-ticket card with an **NT$ headline + optional 約 US$ supplementary** line (rendered **only when** the message has `cheapest_usd`), and a single **「立即訂購」** button via `fare.booking_url(currency="twd")`. *(The booking link works with no affiliate `marker` — un-attributed; monetizing is optional, see "Optional: monetize the booking link" below.)*
   - Here `fare` is built from **`cheapest`** (the TWD block, always present); pass `usd_price=message["cheapest_usd"]["price"]` **only if** `cheapest_usd` is in the message, else omit it (TWD-only card).
5. **POST to Resend** (set a `User-Agent` header — see Step 1 note), then **`PutItem notification_history`** `{pk, sent_at(now, ISO-8601 UTC), email, route, price, currency}`.
   - **Handle the failure classes — don't blindly redeliver** (M1 has no DLQ, so a raised exception retries **forever**): on a **transient** error (**`429`, `5xx`**) raise/return non-success so SQS redelivers with backoff; on a **permanent** error (**`403`, `422`** — e.g. the demo-sender `403` to a non-account address, a malformed payload) **log and DROP** (return success so the message is deleted) — these will never succeed on retry, and a tight retry loop triggers a Resend **`429` cascade**. Write the history row **only after a real 2xx**.

> **You WRITE `email_render.py` here — it doesn't exist yet.** No prior milestone created `flightproxy/email_render.py` or a `Fare` class, so don't `cp`/"reuse" it. Fold these functions into the consumer's `index.py` (or a small module you author). Required interface:
> - **`subject(fare) -> str`** → 「✈️ {台北 → 東京} 降價通知！NT${price} 已達標」 (TWD).
> - **`render_html(fare, target_price, marker=None, usd_price=None) -> str`** → **NT$ headline** + an optional 約 US$ line (only when `usd_price` given) + a 「立即訂購」 button. Keep it **simple, table-free, transactional** HTML (table-/image-heavy mail reads as marketing — see [[resend-best-practice]]).
> - **`render_text(fare, target_price, marker=None, usd_price=None) -> str`** → plain-text fallback (always send `html` **and** `text` — deliverability).
> - **`booking_url(fare, marker=None) -> str`** → an Aviasales deep link `ORIGIN+DDMM+DEST+DDMM` (+ passengers); append `?marker=` **only when** a marker is provided.
> A reference implementation lives in `flightproxy/email_render.py` in the repo — use it as the spec for what you fold inline.

**First: extend the IAM role with the CONSUMER-side SQS perms.** The role so far only has the *producer* perms (`sqs:SendMessage`/`GetQueueUrl` from M1.2). The event-source mapping needs **all three** of `sqs:ReceiveMessage`, `sqs:DeleteMessage`, **and `sqs:GetQueueAttributes`** on the fare queue — **miss any one and the mapping silently fails closed** (it just never polls; no error in the function log). Add them to `flight-lambda-role`'s `flight-data` policy (merge — don't drop existing statements; DynamoDB on `notification_history` is already granted from M1.1).

**Set a real VisibilityTimeout BEFORE wiring** — the queue ships at the default **30s**, equal to the Lambda's 30s timeout, but Rule 5 needs **strictly greater** (≈6×). Set it to **180s** so a slow send isn't redelivered mid-flight:
```bash
aws sqs set-queue-attributes --queue-url <flight-fare-queue-URL> \
  --attributes VisibilityTimeout=180 --region us-east-1
```

**Then PURGE stale test messages before creating the mapping** — creating the mapping **instantly drains whatever is already on the queue**. Old `test@example.com` matches from M1.2 testing (undeliverable on the demo sender) would burst through as `403`s and trip a Resend `429` cascade. Purge first, then seed one clean test subscriber:
```bash
aws sqs purge-queue --queue-url <flight-fare-queue-URL> --region us-east-1
```

**Now wire the trigger + the config knobs:**
```bash
# event-source mapping: fare queue → this Lambda (drains the queue on creation — purge first, above)
aws lambda create-event-source-mapping \
  --function-name flight-fare-notification \
  --event-source-arn <flight-fare-queue-ARN> \
  --region us-east-1
# the tunable knobs (change live, no redeploy):
aws lambda update-function-configuration --function-name flight-fare-notification \
  --environment 'Variables={NOTIFY_FLOOR_HOURS=24,REALERT_PCT=20,REALERT_ABS_TWD=2000}' \
  --region us-east-1
```
*(Optional but recommended even without a full DLQ: a redrive policy with a small `maxReceiveCount` so a permanent-failure message can't retry forever — see the failure-class handling in Step 2.5.)*

**Verify before moving on:** with a seeded match on the queue (re-run the M1.2 parser if needed), the consumer sends one email (read its logs with `filter-log-events` — the MCP rejects `logs tail`):
```bash
aws logs filter-log-events --log-group-name /aws/lambda/flight-fare-notification \
  --query "events[].message" --region us-east-1
```
Inbox receives the alert (subject 「✈️ 台北 → 東京 降價通知！NT$9,325 已達標」, **NT$ headline + optional 約 US$**, 「立即訂購」 button).

### Step 3 — Prove dedup + the re-alert threshold

1. **Re-run the parser immediately** (so the same match re-enqueues) → you should NOT get a second email (within `NOTIFY_FLOOR_HOURS`).
2. **Re-alert on a notably better price:** simulate/seed a cheapest that's ≥20% or ≥NT$2,000 below the last alerted price → a fresh email DOES go out despite the window.

**Verify before moving on:**
```bash
aws dynamodb query --table-name notification_history \
  --key-condition-expression 'pk = :p' \
  --expression-attribute-values '{":p":{"S":"you@example.com#TPE-TYO"}}' \
  --no-scan-index-forward --max-items 3 \
  --region us-east-1
```
Shows a recent `sent_at` + `price`; the immediate re-run logged "skipped (deduped)"; the big-drop case wrote a new row.

## Optional: monetize the booking link (affiliate marker)

**You don't need this for the notifier.** The alert email already works end-to-end — the subscriber gets the deal and a working 「立即訂購」 link. This step is purely about *getting paid* when they book through that link, and it's entirely skippable.

Travelpayouts gives you a **marker** (your affiliate/partner ID, e.g. `736582`). If a booking link carries `?marker=<id>`, any booking made through it (30-day cookie) credits commission to you. Without the marker the link is identical to the user — just un-attributed.

To turn it on:
1. Travelpayouts dashboard → copy your **marker** (partner ID, top corner).
2. Add it to the existing secret — **`put-secret-value` with both fields** (a partial update would drop the token):
   ```bash
   aws secretsmanager put-secret-value --secret-id flight/travelpayouts \
     --secret-string '{"token":"<YOUR_TOKEN>","marker":"<YOUR_MARKER>"}' \
     --region us-east-1
   ```
3. In the handler, read `marker` from `flight/travelpayouts` and pass it through: `render_html(fare, target_price, marker=marker, …)`. `email_render.py` / `booking_url()` already accept an optional `marker` and add `?marker=…` only when it's present — no other code change.

Skip all of this and the milestone is still complete; the booking link just earns nothing.

## Things to watch out for

1. **Dedup BEFORE sending** — query history, decide, send, then write. A crash mid-send must not double-spam (the next delivery re-checks history).
2. **No payment guard in M1** — this Lambda emails whoever the parser enqueued; it does NOT check `subscription_status` (doesn't exist yet). M2 gates at the parser, not here.
3. **`target_price >= cheapest`** (not `>`) — the *parser* already applied this; the consumer just sends. Equal price counts as "hit your target."
4. **The two re-alert thresholds are OR'd** — ≥`REALERT_PCT`% lower **or** ≥`REALERT_ABS_TWD` lower. Both env-configurable; change live with `update-function-configuration`.
5. **Resend `from`** — until M3 domain verification, use `onboarding@resend.dev`; a custom from-domain without DNS verification bounces.
6. **SQS visibility timeout ≥ Lambda timeout** + idempotent consumer — SQS is at-least-once; the `notification_history` check is what makes a re-delivery safe (see [[aws-best-practice]] Rule 5).
7. **Decimal** — `price`/`target_price` are DynamoDB Numbers (`Decimal`); convert before arithmetic/JSON (see [[aws-best-practice]] Rule 3).
8. **Empty fares never reach here** — the parser skips empty Travelpayouts results, so a message on the queue always carries a real fare.
9. **TWD is the headline, USD is supplementary** — read **`cheapest`** (TWD) for the gate/dedup/headline; render the 約 US$ line only when the message has **`cheapest_usd`** (it's optional — the parser omits it if the USD fetch failed). The subject is NT$.
10. **Drop permanent failures, retry only transient** — `403`/`422` (incl. demo-sender to a non-account address) → log + delete; `429`/`5xx` → let SQS redeliver. With no DLQ, raising on a permanent error loops forever and triggers a `429` cascade.
11. **This Lambda deploys via the S3 bridge, not inline** — the folded renderer is >4096 chars and mixes quote types; use Method 2 (see [[aws-best-practice]]).
12. **Cloudflare blocks the default urllib UA** — POST to `api.resend.com` with a custom `User-Agent` or you get `403` `error code: 1010` (looks like a bad key — it isn't). See [[resend-best-practice]] Rule 4.
13. **`notification_history` `sent_at` is an ISO-8601 String sort key** — not an epoch Number, or the range-key type / "newest first" query breaks.

## Expected duration

45–75 minutes.

## Next step

When `m1-3-email-on-target-checklist` is green: 「M1.3 完成！達標會真的寄 email，而且不會重複轟炸（24 小時內只寄一次，除非又明顯更便宜）。你現在有一個能動的*免費*通知器了 — 還沒有付款門檻。跟我說『啟動 M2』，我們來接 Stripe，加上『只有付費者才收得到』的門檻。」Then load `m2-stripe-subscription`.

## Reference

- Resend API: https://resend.com/docs/api-reference/emails/send-email
- Renderer: **write** `subject`/`render_html`/`render_text`/`booking_url` inline (Step 2) — `flightproxy/email_render.py` in the repo is the reference spec (NT$ headline + optional 約 US$; marker optional).
- Dedup pattern modeled on the sibling bag-notification service's history-table + window approach.
- [[aws-best-practice]] — Cowork S3 deploy (Method 2), SQS visibility timeout, Decimal, the event-source-mapping IAM actions.
- [[resend-best-practice]] — the demo-sender-only-to-self trap, verified-`from` deliverability, dedup-before-send, html+text, no-VPC, rate limits.
