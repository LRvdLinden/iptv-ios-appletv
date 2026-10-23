# Inloggen via de functie login (build 141, docs/ACCOUNT.md "Inloggen via de functie login (build 141)"). Draait in Backend
# (job beveiliging) na het schema en de deploy van login.
# 1. Auth-config: IP-doorgifte (security_sb_forwarded_for_enabled, voor Sb-Forwarded-For met een secret key) aan; controle
#    dat er een secret key is (anders telt de IP-limiet van Auth alle logins via de functie samen: waarschuwing).
# 2. Custom Access Token hook -> pg-functions://postgres/public/bingr_access_token_hook aan (Free-plan). Een andere hook
#    wordt nooit overschreven. Direct daarna een rooktest (inloggen en verversen met een tijdelijk account); mislukt die,
#    dan gaat de hook terug naar de vorige stand en faalt de job.
# 3. End-to-end met tijdelijke accounts (example.com; A in testmodus app_metadata.bingr_login_ticket_required, B gewoon):
#    login ok (zelfde sessie-JSON) en verversen; directe /token zonder ticket geweigerd voor A en toegestaan voor B
#    (schakelaar uit); 4x fout = 400, 5e = 429 too_many_attempts met retry_after, daarna ook goed = 429; onbekend adres = 400;
#    geen tickets over; IP-doorgifte (auditlog: zelfde IP als een directe aanroep); schakelaar staat nog uit. Accounts weg.
# Log: alleen ja/nee, aantallen en HTTP-codes; nooit sleutels, adressen, IP's of serverantwoorden met gegevens.
# Env: REF, SUPABASE_ACCESS_TOKEN. Terug: exit 1 bij een fout.
import json, os, re, secrets, sys, time, urllib.error, urllib.request

REF = os.environ.get("REF", ""); MGMT = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
if not (REF and MGMT): print("::warning::SUPABASE_* ontbreken"); sys.exit(0)
API = f"https://api.supabase.com/v1/projects/{REF}"; BASE = f"https://{REF}.supabase.co"
LOGIN = f"{BASE}/functions/v1/login"
HOOK = "pg-functions://postgres/public/bingr_access_token_hook"

def req(method, url, body=None, headers=None):
    h = {"Content-Type": "application/json", **(headers or {"Authorization": f"Bearer {MGMT}"})}
    r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp: raw = resp.read(); code = resp.status; hd = dict(resp.headers)
    except urllib.error.HTTPError as e: raw = e.read(); code = e.code; hd = dict(e.headers or {})
    except Exception: return 0, None, {}
    try: return code, json.loads(raw or b"{}"), hd
    except Exception: return code, None, hd
def sql(q):
    c, r, _ = req("POST", f"{API}/database/query", {"query": q})
    return r if c < 300 and isinstance(r, list) else None
def why(r):
    m = (r.get("message") or r.get("msg") or r.get("error") or "") if isinstance(r, dict) else ""
    m = re.sub(r"[^\s\"'<>]+@[^\s\"'<>]+", "<e>", str(m)); m = re.sub(r"[0-9a-f]{8}-[0-9a-f-]{27}", "<id>", m)
    return m[:160]

fail, warn = [], []
code, cur, _ = req("GET", f"{API}/config/auth")
if code != 200 or not isinstance(cur, dict): print(f"::error::Auth-config niet gelezen (HTTP {code})"); sys.exit(1)

# 1. IP-doorgifte en secret key
if cur.get("security_sb_forwarded_for_enabled") is not True:
    c, r, _ = req("PATCH", f"{API}/config/auth", {"security_sb_forwarded_for_enabled": True})
    if c >= 300: warn.append(f"IP-doorgifte (security_sb_forwarded_for_enabled) niet aangezet (HTTP {c} {why(r)})")
code, keys, _ = req("GET", f"{API}/api-keys?reveal=true")
key = pub = None; has_secret = False
for k in keys if isinstance(keys, list) else []:
    v = k.get("api_key") or ""
    if k.get("type") == "secret": has_secret = True
    if not v or "·" in v: continue
    if (k.get("name") == "service_role" or k.get("type") == "secret") and not key: key = v
    if (k.get("name") == "anon" or k.get("type") == "publishable") and not pub: pub = v
for v in (key, pub):
    if v: print(f"::add-mask::{v}")
if not has_secret:
    warn.append("geen secret key (sb_secret_…) in het project: login roept /token aan zonder Sb-Forwarded-For, dus de IP-limiet "
                "van Auth telt alle logins via de functie samen. Maak er één aan (Settings > API Keys)")

# 2. Custom Access Token hook
prev = {"hook_custom_access_token_enabled": cur.get("hook_custom_access_token_enabled") is True,
        "hook_custom_access_token_uri": cur.get("hook_custom_access_token_uri") or ""}
if prev["hook_custom_access_token_enabled"] and prev["hook_custom_access_token_uri"] not in ("", HOOK):
    print("::error::er staat al een andere Custom Access Token hook aan; niet overschreven"); sys.exit(1)
changed = False
if not (prev["hook_custom_access_token_enabled"] and prev["hook_custom_access_token_uri"] == HOOK):
    c, r, _ = req("PATCH", f"{API}/config/auth", {"hook_custom_access_token_enabled": True, "hook_custom_access_token_uri": HOOK})
    if c >= 300: print(f"::error::Custom Access Token hook niet aangezet (HTTP {c} {why(r)})"); sys.exit(1)
    changed = True
code, now, _ = req("GET", f"{API}/config/auth"); now = now if isinstance(now, dict) else {}
hook_on = now.get("hook_custom_access_token_enabled") is True and now.get("hook_custom_access_token_uri") == HOOK
if not hook_on: fail.append("Custom Access Token hook staat na het zetten niet aan")
sw = sql("select value from public.app_settings where key = 'login_via_function_required'")
switch = sw[0].get("value") if sw else None
print(f"::notice::Inloggen via login: hook={'aan' if hook_on else 'UIT'}, schakelaar login_via_function_required={json.dumps(switch)}, "
      f"IP-doorgifte={'aan' if now.get('security_sb_forwarded_for_enabled') is True else 'UIT'}, secret key={'ja' if has_secret else 'nee'}")
if switch is None: fail.append("app_settings.login_via_function_required ontbreekt")

if not (key and pub):
    fail.append("geen sleutels voor de end-to-end-test")
else:
    adm = {"apikey": key, **({"Authorization": f"Bearer {key}"} if key.startswith("ey") else {})}
    P = {"apikey": pub}
    accts = {}
    def make(tag, app):
        email = f"ci-login-{tag}-{secrets.token_hex(6)}@example.com"; pw = secrets.token_urlsafe(18)
        c, u, _ = req("POST", f"{BASE}/auth/v1/admin/users", {"email": email, "password": pw, "email_confirm": True, "app_metadata": app}, adm)
        uid = u.get("id") if isinstance(u, dict) else None
        if uid: print(f"::add-mask::{uid}"); accts[tag] = uid
        return (email, pw, uid) if c < 300 and uid else (None, None, None)
    direct = lambda e, p: req("POST", f"{BASE}/auth/v1/token?grant_type=password", {"email": e, "password": p}, P)
    viaf = lambda e, p: req("POST", LOGIN, {"email": e, "password": p, "device_id": "ci", "platform": "ci"}, P)
    refresh = lambda t: req("POST", f"{BASE}/auth/v1/token?grant_type=refresh_token", {"refresh_token": t}, P)
    try:
        eb, pb, ub = make("b", {})
        if not ub: fail.append("testaccount B niet gemaakt")
        else:
            # rooktest direct na de hook: inloggen en verversen moeten gewoon werken
            c, t, _ = direct(eb, pb)
            c2 = refresh(t.get("refresh_token"))[0] if c == 200 and isinstance(t, dict) else 0
            if c != 200 or c2 != 200:
                fail.append(f"rooktest met de hook: direct inloggen HTTP {c}, verversen HTTP {c2} (verwacht 200/200)")
                if changed:
                    rc, _, _ = req("PATCH", f"{API}/config/auth", prev)
                    print(f"::error::Custom Access Token hook teruggezet naar de vorige stand (HTTP {rc})")
                raise SystemExit
            print("::notice::Rooktest met de hook: direct inloggen en verversen werken (schakelaar uit)")
        ea, pa, ua = make("a", {"bingr_login_ticket_required": True})
        if not ua: fail.append("testaccount A niet gemaakt"); raise SystemExit
        # login ok: zelfde sessie-JSON als /token
        c, t, _ = viaf(ea, pa)
        want = {"access_token", "token_type", "expires_in", "expires_at", "refresh_token", "user"}
        if c != 200 or not isinstance(t, dict) or not want <= set(t) or (t.get("user") or {}).get("id") != ua:
            fail.append(f"login met goed wachtwoord: HTTP {c} (verwacht 200 met {sorted(want)})")
        else:
            c2, t2, _ = refresh(t["refresh_token"])
            if c2 != 200 or not isinstance(t2, dict) or not t2.get("access_token"): fail.append(f"verversen na login: HTTP {c2}")
        # directe route zonder ticket: A (testmodus) geweigerd, B (schakelaar uit) toegestaan
        c, r, _ = direct(ea, pa)
        if c == 200 or (isinstance(r, dict) and r.get("access_token")): fail.append("directe /token zonder ticket (testmodus) niet geweigerd")
        else: print(f"::notice::Directe /token zonder ticket geweigerd (HTTP {c}); met ticket via login wel")
        c, _, _ = direct(eb, pb)
        if c != 200: fail.append(f"directe /token met schakelaar uit: HTTP {c} (verwacht 200)")
        # blokkade per account via de functie
        codes = []
        for i in range(4):
            c, r, _ = viaf(ea, pa + "x"); codes.append((c, (r or {}).get("error_code") if isinstance(r, dict) else None)); time.sleep(0.2)
        if codes != [(400, "invalid_credentials")] * 4: fail.append(f"fout wachtwoord 1-4: {[c for c, _ in codes]} (verwacht 400 invalid_credentials)")
        c, r, hd = viaf(ea, pa + "x"); r = r if isinstance(r, dict) else {}
        ra = r.get("retry_after")
        if c != 429 or r.get("error_code") != "too_many_attempts" or not isinstance(ra, int) or not 800 <= ra <= 900:
            fail.append(f"5e fout: HTTP {c} {r.get('error_code')} retry_after={ra} (verwacht 429 too_many_attempts ~900)")
        if not {k.lower(): v for k, v in hd.items()}.get("retry-after"): warn.append("5e fout: geen Retry-After-kopregel")
        c, r, _ = viaf(ea, pa)
        if c != 429 or (r or {}).get("error_code") != "too_many_attempts": fail.append(f"goed wachtwoord tijdens blokkade: HTTP {c} (verwacht 429)")
        else: print("::notice::Blokkade per account via login werkt: 4x fout = 400, 5e = 429 too_many_attempts (15 min), daarna ook goed = 429")
        # onbekend adres
        c, r, _ = viaf(f"ci-login-none-{secrets.token_hex(6)}@example.com", "x" * 12)
        if c != 400 or (r or {}).get("error_code") != "invalid_credentials": fail.append(f"onbekend adres: HTTP {c} (verwacht 400 invalid_credentials)")
        # geen tickets over, schakelaar nog uit
        rows = sql(f"select count(*)::int as n from public.login_tickets where user_id in ('{ua}', '{ub}')")
        if rows is None or rows[0].get("n") != 0: fail.append(f"login-tickets over na de test: {rows[0].get('n') if rows else '?'}")
        sw = sql("select value from public.app_settings where key = 'login_via_function_required'")
        if not sw or sw[0].get("value") is not False: warn.append(f"schakelaar login_via_function_required staat niet op false ({json.dumps(sw[0].get('value')) if sw else '?'})")
        # IP-doorgifte: het IP in het auditlog bij login via de functie = het IP bij de directe aanroep (alleen ja/nee)
        rows = sql("select (select ip_address from auth.audit_log_entries where payload->>'actor_id' = '" + ub + "' and payload->>'action' = 'login'"
                   " order by created_at desc limit 1) as d, (select ip_address from auth.audit_log_entries where payload->>'actor_id' = '" + ua + "'"
                   " and payload->>'action' = 'login' order by created_at asc limit 1) as f")
        if rows and rows[0].get("d") and rows[0].get("f"):
            same = rows[0]["d"] == rows[0]["f"]
            if same: print("::notice::IP-doorgifte werkt: Auth ziet bij login via de functie het IP van de bezoeker")
            else: warn.append("IP-doorgifte: Auth ziet bij login via de functie een ander IP dan de bezoeker (secret key / security_sb_forwarded_for_enabled?)")
        else: warn.append("IP-doorgifte niet te controleren (geen auditlog)")
    except SystemExit:
        pass
    finally:
        for tag, uid in accts.items():
            c, _, _ = req("DELETE", f"{BASE}/auth/v1/admin/users/{uid}", None, adm)
            if c >= 300: warn.append(f"testaccount {tag} niet verwijderd (HTTP {c})")
for w in warn: print(f"::warning::{w}")
for f in fail: print(f"::error::{f}")
sys.exit(1 if fail else 0)
