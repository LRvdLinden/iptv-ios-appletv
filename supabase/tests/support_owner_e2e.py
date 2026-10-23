# Rooktest eigendom van supporttickets (security H1): een account met hetzelfde e-mailadres als een gast-ticket ziet dat
# ticket NIET (mine, get/reply/close zonder geheime link), ook niet als het adres "bevestigd" is (zoals met autoconfirm).
# Alleen met de geheime link kan het ingelogde account het ticket koppelen (actie link); daarna staat het in mine. Bij het
# verwijderen van het account gaan alleen de gekoppelde tickets weg; een gast-ticket met hetzelfde adres blijft staan.
# Testadressen ci-own-…@example.com (er gaat geen mail uit: de tickets worden via SQL aangemaakt). Alles wordt weer
# verwijderd. Log zonder adressen, tokens of ticketinhoud.
# Env: REF, SUPABASE_ACCESS_TOKEN. Terug: exit 1 bij een fout.
import json, os, secrets, sys, urllib.error, urllib.request

REF = os.environ.get("REF", ""); MGMT = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
if not (REF and MGMT): print("::warning::SUPABASE_* ontbreken; eigendomstest overgeslagen"); sys.exit(0)
API = f"https://api.supabase.com/v1/projects/{REF}"; BASE = f"https://{REF}.supabase.co"
PUB = "sb_publishable_lpIup6Omq5kW2k3oICGZ4g_HPGac5A3"
SU = f"{BASE}/functions/v1/support"
ORIGIN = {"Origin": "https://support.bingr.online"}

def req(method, url, body=None, headers=None):
    h = {"Content-Type": "application/json", **(headers or {})}
    r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp: raw = resp.read(); code = resp.status
    except urllib.error.HTTPError as e: raw = e.read(); code = e.code
    except Exception: return 0, {}
    try: return code, json.loads(raw or b"{}")
    except Exception: return code, {"raw": raw[:120].decode("utf-8", "replace")}
def sql(q):
    code, r = req("POST", f"{API}/database/query", {"query": q}, {"Authorization": f"Bearer {MGMT}"})
    if code >= 300 or not isinstance(r, list): raise SystemExit(f"SQL mislukt (HTTP {code})")
    return r

code, keys = req("GET", f"{API}/api-keys?reveal=true", None, {"Authorization": f"Bearer {MGMT}"})
key = None
for k in keys if isinstance(keys, list) else []:
    v = k.get("api_key") or ""
    if v and (k.get("name") == "service_role" or k.get("type") == "secret") and "·" not in v: key = v; break
if not key: print(f"::warning::eigendomstest overgeslagen: geen geheime sleutel via de Management API (HTTP {code})"); sys.exit(0)
print(f"::add-mask::{key}")
adm = {"apikey": key, **({"Authorization": f"Bearer {key}"} if key.startswith("ey") else {})}

email = f"ci-own-{secrets.token_hex(6)}@example.com"
tok_a, tok_b = secrets.token_urlsafe(24), secrets.token_urlsafe(24)
for t in (tok_a, tok_b): print(f"::add-mask::{t}")
fail, uid = [], None
try:
    rows = sql(
        "insert into public.support_tickets (email, name, subject, category, lang, access_token) values "
        f"('{email}', 'CI', 'CI eigendom A', 'overig', 'nl', '{tok_a}'), ('{email}', 'CI', 'CI eigendom B', 'overig', 'nl', '{tok_b}') "
        "returning number, access_token")
    num = {r["access_token"]: int(r["number"]) for r in rows}
    na, nb = num[tok_a], num[tok_b]
    sql(f"insert into public.support_messages (ticket_id, author, body, source) select id, 'customer', 'CI-bericht', 'web' "
        f"from public.support_tickets where number in ({na}, {nb})")
    # account met hetzelfde adres, "bevestigd" zoals met autoconfirm
    code, u = req("POST", f"{BASE}/auth/v1/admin/users", {"email": email, "password": (pw := secrets.token_urlsafe(18)), "email_confirm": True}, adm)
    uid = u.get("id")
    if not uid: raise SystemExit(f"testaccount aanmaken mislukt (HTTP {code})")
    code, t = req("POST", f"{BASE}/auth/v1/token?grant_type=password", {"email": email, "password": pw}, {"apikey": PUB})
    tok = t.get("access_token")
    if not tok: raise SystemExit(f"inloggen testaccount mislukt (HTTP {code})")
    print(f"::add-mask::{tok}")
    user = {"apikey": PUB, "Authorization": f"Bearer {tok}", **ORIGIN}
    mine = lambda: {int(x.get("number")) for x in (req("POST", SU, {"action": "mine"}, user)[1].get("items") or [])}

    # 1. zonder geheime link: niets
    m = mine()
    if na in m or nb in m: fail.append("mine toont een gast-ticket met hetzelfde adres")
    for action, extra in (("get", {}), ("reply", {"message": "CI: dit mag niet aankomen"}), ("close", {})):
        code, r = req("POST", SU, {"action": action, "n": str(nb), **extra}, user)
        if code != 404: fail.append(f"{action} zonder link op een gast-ticket: HTTP {code} (verwacht 404)")
    code, r = req("POST", SU, {"action": "link", "n": str(nb), "t": secrets.token_urlsafe(24)}, user)
    if code != 404: fail.append(f"link met een verkeerde link: HTTP {code} (verwacht 404)")
    code, r = req("POST", SU, {"action": "link", "n": str(na), "t": tok_a}, {"apikey": PUB, **ORIGIN})
    if code != 401: fail.append(f"link zonder inloggen: HTTP {code} (verwacht 401)")
    if not fail: print("::notice::eigendom: account met hetzelfde adres ziet het gast-ticket niet (mine, get, reply, close: 404)")

    # 2. met de geheime link: zien en koppelen
    code, r = req("POST", SU, {"action": "get", "n": str(na), "t": tok_a}, user)
    tk = r.get("ticket") or {}
    if code != 200 or tk.get("can_link") is not True or tk.get("linked") is not False: fail.append(f"get met link: HTTP {code}, can_link {tk.get('can_link')}, linked {tk.get('linked')}")
    code, r = req("POST", SU, {"action": "link", "n": str(na), "t": tok_a}, user)
    if code != 200 or not r.get("ok"): fail.append(f"link met de geheime link: HTTP {code} {str(r)[:120]}")
    m = mine()
    if na not in m or nb in m: fail.append("na koppelen: mine klopt niet (verwacht alleen het gekoppelde ticket)")
    code, r = req("POST", SU, {"action": "get", "n": str(na)}, user)
    if code != 200 or (r.get("ticket") or {}).get("linked") is not True: fail.append(f"get zonder link op het gekoppelde ticket: HTTP {code}")
    if not fail: print("::notice::eigendom: koppelen met de geheime link werkt; daarna staat alleen dat ticket in mine")

    # 3. account verwijderen: alleen het gekoppelde ticket weg, het gast-ticket blijft
    code, _ = req("DELETE", f"{BASE}/auth/v1/admin/users/{uid}", None, adm)
    if code not in (200, 204): fail.append(f"testaccount verwijderen: HTTP {code}")
    else:
        uid = None
        left = {int(r["number"]) for r in sql(f"select number from public.support_tickets where number in ({na}, {nb})")}
        if na in left: fail.append("gekoppeld ticket staat er nog na het verwijderen van het account")
        if nb not in left: fail.append("gast-ticket met hetzelfde adres is mee verwijderd")
        if not any("verwijder" in f for f in fail): print("::notice::eigendom: account verwijderd -> alleen het gekoppelde ticket weg, gast-ticket blijft")
except SystemExit as e:
    fail.append(str(e))
finally:
    if uid:
        code, _ = req("DELETE", f"{BASE}/auth/v1/admin/users/{uid}", None, adm)
        if code not in (200, 204): print(f"::warning::testaccount niet verwijderd (HTTP {code})")
    try: sql(f"delete from public.support_tickets where email = '{email}'")
    except SystemExit: print("::warning::testtickets niet opgeruimd")
for f in fail: print(f"::error::{f[:300]}")
sys.exit(1 if fail else 0)
