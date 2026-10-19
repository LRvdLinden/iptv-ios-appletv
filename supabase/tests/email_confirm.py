# Bevestigen per e-mail aan/uit volgens app_settings.require_email_confirm (build 137; tijdelijk false zolang de
# bevestigingsmail niet aantoonbaar aankomt). Zet Auth mailer_autoconfirm = !require_email_confirm. Staat bevestigen uit,
# dan worden onbevestigde accounts (nog niet weggeruimd, dus jonger dan 48 uur) via de admin-API bevestigd, zodat ze
# meteen kunnen inloggen; testaccounts van de CI (example.*, plus-adressen van bingr.online) niet. Draait in Backend en
# in de workflow Auth-bevestiging. Log alleen aantallen. De hook Before User Created blijft ongemoeid.
# Env: REF, SUPABASE_ACCESS_TOKEN. Terug: exit 1 bij een fout.
import json, os, sys, urllib.error, urllib.request

REF = os.environ.get("REF", ""); MGMT = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
if not (REF and MGMT): print("::warning::SUPABASE_* ontbreken"); sys.exit(0)
API = f"https://api.supabase.com/v1/projects/{REF}"; BASE = f"https://{REF}.supabase.co"

def req(method, url, body=None, headers=None):
    h = {"Content-Type": "application/json", **(headers or {"Authorization": f"Bearer {MGMT}"})}
    r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=60) as resp: raw = resp.read(); code = resp.status
    except urllib.error.HTTPError as e: raw = e.read(); code = e.code
    except Exception: return 0, None
    try: return code, json.loads(raw or b"{}")
    except Exception: return code, None
def sql(q): return req("POST", f"{API}/database/query", {"query": q})

fail = []
code, r = sql("insert into public.app_settings (key, value) values ('require_email_confirm', 'false'::jsonb) on conflict (key) do nothing;\n"
              "select value from public.app_settings where key = 'require_email_confirm'")
if code >= 300 or not isinstance(r, list) or not r:
    print(f"::error::require_email_confirm niet gelezen (HTTP {code})"); sys.exit(1)
require = r[0].get("value") is True
code, _ = req("PATCH", f"{API}/config/auth", {"mailer_autoconfirm": not require})
if code >= 300: print(f"::error::mailer_autoconfirm zetten mislukt (HTTP {code})"); sys.exit(1)
code, c = req("GET", f"{API}/config/auth")
if not isinstance(c, dict) or c.get("mailer_autoconfirm") is not (not require):
    print("::error::mailer_autoconfirm staat na het zetten niet goed"); sys.exit(1)
print(f"::notice::Bevestigen per e-mail: {'verplicht' if require else 'TIJDELIJK UIT (require_email_confirm = false)'}"
      + ("" if require else "; de hook (limiet, wegwerpadressen, namen) blijft aan" if c.get("hook_before_user_created_enabled") else "; LET OP: hook Before User Created staat uit"))
if not require:
    code, keys = req("GET", f"{API}/api-keys?reveal=true")
    key = None
    for k in keys if isinstance(keys, list) else []:
        v = k.get("api_key") or ""
        if v and (k.get("name") == "service_role" or k.get("type") == "secret") and "·" not in v: key = v; break
    if key: print(f"::add-mask::{key}")
    code, rows = sql("select id::text from auth.users where email_confirmed_at is null and email is not null and deleted_at is null "
                     "and split_part(lower(email), '@', 2) not like 'example.%' "
                     "and not (split_part(lower(email), '@', 2) = 'bingr.online' and split_part(lower(email), '@', 1) like '%+ci-%') limit 1000")
    ids = [x["id"] for x in rows] if code < 300 and isinstance(rows, list) else []
    for i in ids: print(f"::add-mask::{i}")
    ok = 0
    if ids and not key: fail.append("geen geheime sleutel: onbevestigde accounts niet bevestigd")
    adm = {"apikey": key or "", **({"Authorization": f"Bearer {key}"} if key and key.startswith("ey") else {})}
    for i in ids if key else []:
        c2, _ = req("PUT", f"{BASE}/auth/v1/admin/users/{i}", {"email_confirm": True}, adm)
        ok += 1 if c2 == 200 else 0
    print(f"::notice::Onbevestigde accounts bevestigd: {ok} van {len(ids)}")
    if ok < len(ids): fail.append(f"{len(ids) - ok} account(s) niet bevestigd")
for f in fail: print(f"::error::{f}")
sys.exit(1 if fail else 0)
