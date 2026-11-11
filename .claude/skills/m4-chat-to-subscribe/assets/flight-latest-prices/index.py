import json, os, time, urllib.request, urllib.parse, urllib.error
from datetime import date, datetime, timezone
import boto3

# GET /prices for the M4 Telegram bot: live cheapest fare per route in TWD.
# Only needed when the student's M1 has no GET /prices yet; same response shape either way.
UA = "Mozilla/5.0 (compatible; flight-notifier/1.0)"
TTL = 600  # cache per warm container so a busy bot doesn't burn the Travelpayouts quota
_s3 = boto3.client("s3")
_sm = boto3.client("secretsmanager")
_token = None
_cache = {"at": 0, "body": None}


def token():
    global _token
    if _token is None:
        _token = json.loads(_sm.get_secret_value(SecretId="flight/travelpayouts")["SecretString"])["token"]
    return _token


def next_month():
    t = date.today()
    y, m = (t.year + 1, 1) if t.month == 12 else (t.year, t.month + 1)
    return f"{y:04d}-{m:02d}"


def cheapest(origin, destination, month):
    q = urllib.parse.urlencode({"origin": origin, "destination": destination, "depart_date": month,
                                "currency": "twd", "token": token()})
    req = urllib.request.Request(f"https://api.travelpayouts.com/v1/prices/cheap?{q}",
                                 headers={"User-Agent": UA, "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=8) as r:
            body = json.loads(r.read())
    except (urllib.error.URLError, ValueError) as ex:
        print(f"fetch {origin}-{destination} failed: {ex}")
        return None
    offers = (body.get("data") or {}).get(destination, {}) if body.get("success") else {}
    if not offers:
        return None
    best = min(offers.values(), key=lambda o: o["price"])
    return {"route": f"{origin}-{destination}", "month": month, "price": best["price"], "currency": "TWD",
            "airline": best.get("airline"), "depart_date": best.get("departure_at"),
            "return_date": best.get("return_at"), "checked_at": datetime.now(timezone.utc).isoformat()}


def handler(event, context):
    if _cache["body"] is None or time.time() - _cache["at"] > TTL:
        obj = _s3.get_object(Bucket=os.environ["CONFIG_BUCKET"], Key="flight-routes.json")
        month = next_month()
        items = [p for r in json.loads(obj["Body"].read())
                 if (p := cheapest(r["origin"], r["destination"], month))]
        _cache.update(at=time.time(), body=json.dumps({"items": items}))
    return {"statusCode": 200, "headers": {"content-type": "application/json"}, "body": _cache["body"]}
