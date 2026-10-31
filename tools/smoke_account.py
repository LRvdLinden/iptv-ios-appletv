#!/usr/bin/env python3
"""Start-rooktest (build 141): tijdelijk testaccount voor de rooktest met een Bingr-account.

  smoke_account.py create   maakt een account (ci-smoke-…@example.com, Lifetime) en zet SMOKE_EMAIL/SMOKE_PASSWORD
                            in $GITHUB_ENV (gemaskeerd); het id komt in $RUNNER_TEMP/smoke-account.json
  smoke_account.py delete   verwijdert dat account weer (account_data en de rest gaan mee via de foreign keys)

Nodig: SUPABASE_ACCESS_TOKEN en SUPABASE_PROJECT_REF (als REF). Zonder die secrets: niets doen (de rooktest draait dan
zonder account). De geheime sleutel komt via de Management API, wordt gemaskeerd en nooit gelogd of bewaard.
"""
import json
import os
import secrets
import sys
import urllib.error
import urllib.request

REF = os.environ.get("REF", "").strip()
MGMT = os.environ.get("SUPABASE_ACCESS_TOKEN", "").strip()
STATE = os.path.join(os.environ.get("RUNNER_TEMP", "/tmp"), "smoke-account.json")


def req(method, url, body=None, headers=None):
    h = {"Content-Type": "application/json", **(headers or {})}
    r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            raw, code = resp.read(), resp.status
    except urllib.error.HTTPError as e:
        raw, code = e.read(), e.code
    except Exception:
        return 0, {}
    try:
        return code, json.loads(raw or b"{}")
    except Exception:
        return code, {}


def admin_key():
    code, keys = req("GET", f"https://api.supabase.com/v1/projects/{REF}/api-keys?reveal=true",
                     headers={"Authorization": f"Bearer {MGMT}"})
    for k in keys if isinstance(keys, list) else []:
        v = k.get("api_key") or ""
        if v and (k.get("name") == "service_role" or k.get("type") == "secret") and "·" not in v:
            print(f"::add-mask::{v}")
            return v
    print(f"::warning::Rooktest zonder account: geen geheime sleutel via de Management API (HTTP {code})")
    return None


def sql(q):
    return req("POST", f"https://api.supabase.com/v1/projects/{REF}/database/query", {"query": q},
               headers={"Authorization": f"Bearer {MGMT}"})


def main():
    if not REF or not MGMT:
        print("::notice::Rooktest zonder account (geen SUPABASE_ACCESS_TOKEN/SUPABASE_PROJECT_REF)")
        return
    key = admin_key()
    if not key:
        return
    base = f"https://{REF}.supabase.co"
    adm = {"apikey": key, **({"Authorization": f"Bearer {key}"} if key.startswith("ey") else {})}
    if sys.argv[1:] == ["delete"]:
        try:
            uid = json.load(open(STATE)).get("uid")
        except Exception:
            uid = None
        if not uid:
            return
        code, _ = req("DELETE", f"{base}/auth/v1/admin/users/{uid}", None, adm)
        print(f"Testaccount verwijderd (HTTP {code})")
        if code not in (200, 204, 404):
            print(f"::warning::Testaccount van de rooktest niet verwijderd (HTTP {code})")
        return
    email, pw = f"ci-smoke-{secrets.token_hex(6)}@example.com", secrets.token_urlsafe(18)
    print(f"::add-mask::{email}")
    print(f"::add-mask::{pw}")
    code, u = req("POST", f"{base}/auth/v1/admin/users", {"email": email, "password": pw, "email_confirm": True}, adm)
    uid = u.get("id") if isinstance(u, dict) else None
    if not uid:
        print(f"::warning::Rooktest zonder account: aanmaken mislukt (HTTP {code})")
        return
    json.dump({"uid": uid}, open(STATE, "w"))
    # Lifetime, zodat de apparaatlimiet van Gratis de test niet stopt (iPhone, Apple TV en Mac).
    # SMOKE_PLAN=free (handmatige diagnose): het standaardabonnement Gratis laten staan.
    if os.environ.get("SMOKE_PLAN", "").strip().lower() == "free":
        print("Testaccount blijft Gratis (SMOKE_PLAN=free)")
        with open(os.environ["GITHUB_ENV"], "a") as f:
            f.write(f"SMOKE_EMAIL={email}\nSMOKE_PASSWORD={pw}\n")
        return
    code, _ = sql("insert into public.account_plans (user_id, plan, source, note) values "
                  f"('{uid}', 'lifetime', 'admin', 'ci-rooktest') on conflict (user_id) do update set plan = 'lifetime'")
    if code not in (200, 201):
        print(f"::warning::Lifetime voor het testaccount niet gezet (HTTP {code})")
    with open(os.environ["GITHUB_ENV"], "a") as f:
        f.write(f"SMOKE_EMAIL={email}\nSMOKE_PASSWORD={pw}\n")
    print("Testaccount voor de rooktest klaar")


if __name__ == "__main__":
    main()
