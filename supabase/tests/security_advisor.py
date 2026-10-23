# Beveiligingscontrole van de database en Auth (Supabase security/performance advisor + eigen RLS-controle).
# Het log is OPENBAAR: alleen namen van regels, schema's, tabellen/functies, niveaus en aantallen; nooit rijen,
# sleutels of serverantwoorden. Env: REF, SUPABASE_ACCESS_TOKEN.
#   python3 -I supabase/tests/security_advisor.py report   alle bevindingen (security + performance) en Auth-instellingen
#   python3 -I supabase/tests/security_advisor.py gate     faalt als een tabel in een blootgesteld schema geen RLS heeft,
#                                                         of de security-advisor een ERROR geeft (WARN = waarschuwing)
import json, os, sys, time, urllib.error, urllib.request

REF = os.environ.get("REF", ""); MGMT = os.environ.get("SUPABASE_ACCESS_TOKEN", "")
MODE = (sys.argv[1] if len(sys.argv) > 1 else "report")
if not (REF and MGMT): print("::warning::SUPABASE_* ontbreken"); sys.exit(0)
API = f"https://api.supabase.com/v1/projects/{REF}"
# schema's die PostgREST blootstelt (Data API); graphql_public heeft geen tabellen
EXPOSED = ("public",)
# WARN-regels die bewust blijven (met reden); ERROR-regels nooit
ACCEPTED_WARN = {
    # pg_net en pg_trgm/citext e.d. staan door Supabase in public/extensions; verplaatsen breekt bestaande aanroepen
    "extension_in_public": "extensie in public (door Supabase geïnstalleerd)",
}

def req(method, url, body=None):
    h = {"Authorization": f"Bearer {MGMT}", "Content-Type": "application/json"}
    for wait in (5, 15, 30, 0):
        r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method, headers=h)
        try:
            with urllib.request.urlopen(r, timeout=90) as resp: raw = resp.read(); code = resp.status
        except urllib.error.HTTPError as e: raw = e.read(); code = e.code
        except Exception: raw, code = b"", 0
        if code in (429, 0, 502, 503, 504) and wait: time.sleep(wait); continue
        try: return code, json.loads(raw or b"{}")
        except Exception: return code, None
def sql(q): return req("POST", f"{API}/database/query", {"query": q})
def note(title, msg): print(f"::notice title={title}::{msg[:3800]}")

def lints(kind):
    code, r = req("GET", f"{API}/advisors/{kind}")
    if code != 200 or not isinstance(r, dict) or not isinstance(r.get("lints"), list): return None, code
    return r["lints"], code
def label(l):
    m = l.get("metadata") or {}
    obj = ".".join(x for x in (m.get("schema"), m.get("name")) if x)
    return f"{l.get('name')}{' ' + obj if obj else ''}"
def summary(ls):
    by = {}
    for l in ls: by.setdefault(l.get("level") or "?", {}).setdefault(l.get("name") or "?", 0); by[l.get("level") or "?"][l.get("name") or "?"] += 1
    return "; ".join(f"{lvl}: " + ", ".join(f"{n} x{c}" for n, c in sorted(d.items())) for lvl, d in sorted(by.items())) or "geen bevindingen"

fail, warn = [], []
# 1. eigen controle: tabellen zonder RLS in blootgestelde schema's
code, rows = sql("select n.nspname || '.' || c.relname as t from pg_class c join pg_namespace n on n.oid = c.relnamespace "
                 f"where n.nspname in ({','.join(repr(s) for s in EXPOSED)}) and c.relkind in ('r','p') and not c.relrowsecurity order by 1")
if code >= 300 or not isinstance(rows, list): fail.append(f"RLS-controle niet uitgevoerd (HTTP {code})")
elif rows: fail.append("tabellen zonder RLS: " + ", ".join(r["t"] for r in rows))
else: note("RLS", "alle tabellen in " + ", ".join(EXPOSED) + " hebben RLS aan")
# 2. security-advisor
sec, code = lints("security")
if sec is None: (fail if MODE == "gate" else warn).append(f"security-advisor niet gelezen (HTTP {code})")
else:
    # GitHub toont max. 10 annotaties per soort per stap: alles samen in een paar regels
    note("security-advisor", f"{len(sec)} bevinding(en) - {summary(sec)}")
    errs = [label(l) for l in sec if l.get("level") == "ERROR"]
    warns = [label(l) for l in sec if l.get("level") == "WARN" and l.get("name") not in ACCEPTED_WARN]
    if errs: fail.append("security-advisor ERROR: " + "; ".join(errs))
    if warns: warn.append("security-advisor WARN: " + "; ".join(warns))
if MODE == "report":
    perf, code = lints("performance")
    if perf is None: warn.append(f"performance-advisor niet gelezen (HTTP {code})")
    else:
        note("performance-advisor", f"{len(perf)} bevinding(en) - {summary(perf)}")
        pw = [f"{l.get('level')} {label(l)}" for l in perf if l.get("level") in ("ERROR", "WARN")]
        if pw: note("performance ERROR/WARN", "; ".join(pw))
    # Auth-instellingen die met inloggen te maken hebben (getallen en ja/nee, geen geheimen)
    code, c = req("GET", f"{API}/config/auth")
    if isinstance(c, dict):
        keys = sorted(k for k in c if k.startswith("rate_limit_")) + ["password_min_length", "password_required_characters",
               "password_hibp_enabled", "mailer_otp_exp", "mailer_otp_length", "security_refresh_token_reuse_interval",
               "security_captcha_enabled", "sessions_timebox", "sessions_inactivity_timeout", "jwt_exp"]
        note("Auth-limieten", ", ".join(f"{k}={c.get(k)}" for k in keys if k in c))
        note("Auth-hooks", ", ".join(f"{k}={c.get(k)}" for k in sorted(c) if k.startswith("hook_") and k.endswith("_enabled")))
    else: warn.append(f"Auth-config niet gelezen (HTTP {code})")
    code, p = req("GET", f"{API}")
    org = p.get("organization_id") if isinstance(p, dict) else None
    if org:
        code, o = req("GET", f"https://api.supabase.com/v1/organizations/{org}")
        if isinstance(o, dict): note("plan", str(o.get("plan")))
for w in warn: print(f"::warning::{w}")
for f in fail: print(f"::error::{f}")
sys.exit(1 if (fail and MODE == "gate") else 0)
