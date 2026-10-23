# Inlogbescherming in Supabase Auth (docs/ACCOUNT.md "Inlogbescherming"). Draait in Backend na het schema.
# 1. Limieten per IP (per 5 minuten; strengere bestaande waarden blijven): token-endpoint (inloggen met wachtwoord en
#    sessies verversen) 100, verify (links uit mails, tv-koppeling) 20, sign-ups/sign-ins/OTP/wachtwoord vergeten 10.
# 2. Wachtwoorden: minimaal 8 tekens; gelekte wachtwoorden (HaveIBeenPwned) weigeren als het plan dat toestaat.
# 3. Hook Password Verification Attempt -> public.bingr_password_attempt (5 fouten in 15 min = account 15 min dicht,
#    oplopend). Staat het plan de hook niet toe, dan een waarschuwing (de functie staat wel klaar).
# 4. End-to-end met een tijdelijk account (example.com): 5x fout -> 429 met de melding, daarna ook goed -> 429; account weg.
# Log: alleen ja/nee, aantallen en HTTP-codes; nooit sleutels, adressen of serverantwoorden met gegevens.
# Env: REF, SUPABASE_ACCESS_TOKEN. Terug: exit 1 bij een fout.
import json, os, re, secrets, sys, time, urllib.error, urllib.request

REF = os.environ.get("REF", ""); MGMT = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
if not (REF and MGMT): print("::warning::SUPABASE_* ontbreken"); sys.exit(0)
API = f"https://api.supabase.com/v1/projects/{REF}"; BASE = f"https://{REF}.supabase.co"
HOOK = "pg-functions://postgres/public/bingr_password_attempt"
LIMITS = {"rate_limit_token_refresh": 100, "rate_limit_verify": 20, "rate_limit_otp": 10}
MIN_LEN = 8

def req(method, url, body=None, headers=None):
    h = {"Content-Type": "application/json", **(headers or {"Authorization": f"Bearer {MGMT}"})}
    r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp: raw = resp.read(); code = resp.status
    except urllib.error.HTTPError as e: raw = e.read(); code = e.code
    except Exception: return 0, None
    try: return code, json.loads(raw or b"{}")
    except Exception: return code, None
def why(r):
    # korte, opgeschoonde foutmelding van de Management API (bv. "requires Team plan"); geen adressen of id's
    m = (r.get("message") or r.get("msg") or r.get("error") or "") if isinstance(r, dict) else ""
    m = re.sub(r"[^\s\"'<>]+@[^\s\"'<>]+", "<e>", str(m)); m = re.sub(r"[0-9a-f]{8}-[0-9a-f-]{27}", "<id>", m)
    return m[:160]

fail, warn = [], []
code, cur = req("GET", f"{API}/config/auth")
if code != 200 or not isinstance(cur, dict): print(f"::error::Auth-config niet gelezen (HTTP {code})"); sys.exit(1)
# 1. limieten
def stricter(key, want):
    v = cur.get(key)
    return v if isinstance(v, int) and 0 < v <= want else want
patch = {k: stricter(k, v) for k, v in LIMITS.items()}
c, r = req("PATCH", f"{API}/config/auth", patch)
if c >= 300: fail.append(f"Auth-limieten niet gezet (HTTP {c} {why(r)})")
# 2. wachtwoorden
ml = cur.get("password_min_length")
c, r = req("PATCH", f"{API}/config/auth", {"password_min_length": max(ml if isinstance(ml, int) else 0, MIN_LEN)})
if c >= 300: fail.append(f"minimale wachtwoordlengte niet gezet (HTTP {c} {why(r)})")
hibp = True
if cur.get("password_hibp_enabled") is not True:
    c, r = req("PATCH", f"{API}/config/auth", {"password_hibp_enabled": True})
    if c >= 300: hibp = False; warn.append(f"gelekte wachtwoorden weigeren niet aangezet (HTTP {c} {why(r)}; plan?)")
# 3. hook
hook_ok = True
if cur.get("hook_password_verification_attempt_enabled") is not True or cur.get("hook_password_verification_attempt_uri") != HOOK:
    c, r = req("PATCH", f"{API}/config/auth", {"hook_password_verification_attempt_enabled": True,
                                               "hook_password_verification_attempt_uri": HOOK})
    if c >= 300: hook_ok = False; warn.append(f"hook Password Verification Attempt niet aangezet (HTTP {c} {why(r)}; plan?)")
code, now = req("GET", f"{API}/config/auth"); now = now if isinstance(now, dict) else {}
for k, v in patch.items():
    if not isinstance(now.get(k), int) or now[k] > v: fail.append(f"{k} staat niet goed")
if not isinstance(now.get("password_min_length"), int) or now["password_min_length"] < MIN_LEN: fail.append("password_min_length staat niet goed")
hook_on = now.get("hook_password_verification_attempt_enabled") is True and now.get("hook_password_verification_attempt_uri") == HOOK
if hook_ok and not hook_on: warn.append("hook Password Verification Attempt staat na het zetten niet aan")
print("::notice::Inlogbescherming: " + ", ".join(f"{k}={now.get(k)}" for k in LIMITS)
      + f", password_min_length={now.get('password_min_length')}, gelekte wachtwoorden weigeren={'ja' if now.get('password_hibp_enabled') is True else 'nee'}"
      + f", blokkade per account={'aan' if hook_on else 'UIT'}")

# 4. end-to-end (alleen met de hook aan)
if hook_on:
    code, keys = req("GET", f"{API}/api-keys?reveal=true")
    key = pub = None
    for k in keys if isinstance(keys, list) else []:
        v = k.get("api_key") or ""
        if not v or "·" in v: continue
        if (k.get("name") == "service_role" or k.get("type") == "secret") and not key: key = v
        if (k.get("name") == "anon" or k.get("type") == "publishable") and not pub: pub = v
    for v in (key, pub):
        if v: print(f"::add-mask::{v}")
    if not (key and pub): fail.append("geen sleutels voor de end-to-end-test")
    else:
        adm = {"apikey": key, **({"Authorization": f"Bearer {key}"} if key.startswith("ey") else {})}
        email = f"ci-pw-{secrets.token_hex(6)}@example.com"; pw = secrets.token_urlsafe(18)
        c, u = req("POST", f"{BASE}/auth/v1/admin/users", {"email": email, "password": pw, "email_confirm": True}, adm)
        uid = u.get("id") if isinstance(u, dict) else None
        if uid: print(f"::add-mask::{uid}")
        try:
            if c >= 300 or not uid: fail.append(f"testaccount niet gemaakt (HTTP {c})")
            else:
                login = lambda p: req("POST", f"{BASE}/auth/v1/token?grant_type=password", {"email": email, "password": p}, {"apikey": pub})
                codes = []
                for i in range(5):
                    c, r = login(pw + "x"); codes.append(c); time.sleep(0.3)
                c5, r5 = codes[-1], r
                msg = (r5.get("msg") or r5.get("message") or "") if isinstance(r5, dict) else ""
                if codes[:4] != [400] * 4: fail.append(f"fout wachtwoord 1-4: HTTP {codes[:4]} (verwacht 400)")
                if c5 != 429 or not msg.startswith("Too many attempts. Try again in"): fail.append(f"5e fout: HTTP {c5} (verwacht 429 met melding)")
                c, r = login(pw)
                if c != 429: fail.append(f"goed wachtwoord tijdens blokkade: HTTP {c} (verwacht 429)")
                if not fail: print("::notice::Blokkade per account werkt: 4x fout = 400, 5e = 429 'Too many attempts. Try again in 15 minutes.', daarna ook goed = 429")
        finally:
            if uid:
                c, _ = req("DELETE", f"{BASE}/auth/v1/admin/users/{uid}", None, adm)
                if c >= 300: warn.append(f"testaccount niet verwijderd (HTTP {c})")
for w in warn: print(f"::warning::{w}")
for f in fail: print(f"::error::{f}")
sys.exit(1 if fail else 0)
