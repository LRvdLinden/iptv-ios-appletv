# End-to-end test van de bevestigingsmail van Supabase Auth (build 137). Draait in de workflows Backend (job authmail) en
# Diagnose (job mailtest). Het log is OPENBAAR: alleen ja/nee, tijden, het onderwerp, het afzenderdomein en
# SPF/DKIM/DMARC-uitkomsten; nooit adressen, wachtwoorden, IP's, tokens of serverantwoorden met gebruikersgegevens.
#
# Werkwijze:
#   1. controle: een gewone mail via BINGR_SMTP_* (zelfde server, login en afzender als Auth) naar het testadres;
#   2. echte aanmelding: POST /auth/v1/signup (publishable key, zoals de apps) met het testadres;
#   3. via IMAP (BINGR_IMAP_*, de mailbox support@) wachten tot beide binnen zijn (INBOX, spam- en andere mappen);
#   4. opruimen: testmails verwijderen (\Deleted + EXPUNGE), testaccount en de hookpoging weg.
# Testadres: support+ci-<willekeurig>@bingr.online (plus-adres; komt in dezelfde mailbox). De afzender is noreply@:
# de inbox-import negeert die (AUTO_SENDER), dus er komt nooit een ticket van; de mails worden ook direct verwijderd.
#
# MAILTEST_REQUIRE_HOOK=1: de mail moet via de functie auth-mail komen (kopregel X-Bingr-Mail: auth-…).
# Env: REF, SUPABASE_ACCESS_TOKEN, S_HOST, S_PORT, S_USER, S_PASS, S_FROM, I_HOST, I_PORT, I_USER, I_PASS,
#      MAILTEST_TO (optioneel, standaard support@bingr.online), MAILTEST_WAIT (seconden, standaard 180).
import email, email.policy, email.utils, imaplib, json, os, re, secrets, smtplib, ssl, sys, time, urllib.error, urllib.request
from email.message import EmailMessage

E = os.environ
REF = E.get("REF", ""); MGMT = E.get("SUPABASE_ACCESS_TOKEN", "")
BASE = f"https://{REF}.supabase.co"; PUB = "sb_publishable_lpIup6Omq5kW2k3oICGZ4g_HPGac5A3"
API = f"https://api.supabase.com/v1/projects/{REF}"
WAIT = int(E.get("MAILTEST_WAIT") or 180)
fail, warn = [], []

def note(title, msg): print(f"::notice title={title}::{str(msg)[:1500]}")
def mask(v):
    if v: print(f"::add-mask::{v}")

def req(method, url, body=None, headers=None):
    h = {"Content-Type": "application/json", **(headers or {})}
    r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method, headers=h)
    try:
        with urllib.request.urlopen(r, timeout=30) as resp: raw = resp.read(); code = resp.status
    except urllib.error.HTTPError as e: raw = e.read(); code = e.code
    except Exception: return 0, {}
    try: return code, json.loads(raw or b"{}")
    except Exception: return code, {}

def sql(q): return req("POST", f"{API}/database/query", {"query": q}, {"Authorization": f"Bearer {MGMT}"})
def lit(s): return "'" + str(s).replace("'", "''") + "'"
def addr(v):
    m = re.search(r"<([^>]+)>", v or ""); return (m.group(1) if m else (v or "")).strip()

if not (REF and MGMT): print("::warning::mailtest: SUPABASE_* ontbreken, overgeslagen"); sys.exit(0)
if not (E.get("I_HOST") and E.get("I_USER") and E.get("I_PASS")): print("::warning::mailtest: BINGR_IMAP_* ontbreken, overgeslagen"); sys.exit(0)
for k in ("S_USER", "S_PASS", "S_FROM", "I_USER", "I_PASS", "I_HOST", "S_HOST"): mask(E.get(k)); mask(addr(E.get(k)))

base_to = (E.get("MAILTEST_TO") or "support@bingr.online").strip().lower()
local, _, domain = base_to.partition("@")
tag = "ci-" + secrets.token_hex(5)
to = f"{local}+{tag}@{domain}"
mask(to); mask(tag)
sender = addr(E.get("S_FROM"))
note("mailtest afzender", "afzender noreply-achtig (inbox-import negeert): " + ("ja" if re.match(r"^(no-?reply|do-?not-?reply|donotreply)@", sender, re.I) else "nee"))

# geheime sleutel (admin-API) voor het opruimen
code, keys = req("GET", f"{API}/api-keys?reveal=true", headers={"Authorization": f"Bearer {MGMT}"})
key = None
for k in keys if isinstance(keys, list) else []:
    v = k.get("api_key") or ""
    if v and (k.get("name") == "service_role" or k.get("type") == "secret") and "·" not in v: key = v; break
mask(key)
adm = {"apikey": key or "", **({"Authorization": f"Bearer {key}"} if key and key.startswith("ey") else {})}

def imap():
    c = imaplib.IMAP4_SSL(E["I_HOST"].strip(), int((E.get("I_PORT") or "993").strip() or 993), ssl_context=ssl.create_default_context(), timeout=30)
    c.login(E["I_USER"].strip(), E["I_PASS"]); return c

def folders(c):
    out = []
    typ, data = c.list()
    for line in data or []:
        s = line.decode("utf-8", "replace") if isinstance(line, bytes) else str(line)
        if re.search(r"\\Noselect|\\NonExistent", s, re.I): continue
        m = re.search(r'\) (?:"[^"]*"|NIL) (.+)$', s)
        if m: out.append(m.group(1).strip())
    return out or ['"INBOX"']

def find(c, want_subject_tag=None):
    """Zoekt in alle mappen mails aan het testadres. Terug: {soort: (map, uid, bericht)}."""
    found = {}
    for f in folders(c):
        try:
            typ, _ = c.select(f, readonly=False)
            if typ != "OK": continue
            typ, data = c.uid("SEARCH", None, "TO", f'"{to}"')
        except Exception: continue
        for uid in (data[0].split() if typ == "OK" and data and data[0] else []):
            typ, d = c.uid("FETCH", uid, "(BODY.PEEK[HEADER])")
            raw = next((p[1] for p in d or [] if isinstance(p, tuple)), b"")
            msg = email.message_from_bytes(raw, policy=email.policy.default)
            kind = "controle" if tag in str(msg.get("Subject", "")) else "auth"
            found.setdefault(kind, (f, uid, msg))
    return found

def summary(f, msg, t_sent):
    fr = addr(str(msg.get("From", "")))
    ar = " ".join(str(v) for v in (msg.get_all("Authentication-Results") or [])[:1]).lower()
    res = " ".join(f"{a}={b}" for a, b in sorted(set(re.findall(r"\b(spf|dkim|dmarc)=([a-z]+)", ar)))) or "-"
    spam = str(msg.get("X-Spam-Flag") or msg.get("X-Spam-Status") or "-").split(",")[0][:20]
    when = email.utils.parsedate_to_datetime(str(msg.get("Date"))) if msg.get("Date") else None
    subj = re.sub(r"[^\s\"'<>]+@[^\s\"'<>]+", "<e>", str(msg.get("Subject", "")))[:80].replace(tag, "<tag>")
    fname = re.sub(r"[^\w .\-/]", "", f.strip('"').replace(tag, "<tag>"))[:40] or "?"
    def dom(v):
        m = re.search(r"@([^>\s]+)", v or "")
        if not m: return ""
        d = m.group(1).lower().rstrip(">")
        return d if d in ("bingr.online", "localhost") else "<ander>"
    dk = [re.search(r"\bd=([^;\s]+)", str(v)) for v in (msg.get_all("DKIM-Signature") or [])]
    dkim = ",".join(sorted({(m.group(1).lower() if m and m.group(1).lower() == "bingr.online" else "<ander>") for m in dk})) or "geen"
    names = sorted({k.lower() for k in msg.keys() if not k.lower().startswith(("x-", "received", "authentication", "arc-", "dkim", "return-path", "delivered-to", "envelope"))})
    return (f"map: {fname} | onderwerp: {subj} | afzenderdomein: {fr.partition('@')[2] or '-'} | auth-results: {res} | spam: {spam}"
            + f" | DKIM-Signature d=: {dkim} | Message-ID-domein: {dom(str(msg.get('Message-ID') or '')) or 'geen'} | Date: {'ja' if msg.get('Date') else 'nee'}"
            + f" | Return-Path-domein: {dom(str(msg.get('Return-Path') or '')) or '-'} | Received-hops: {len(msg.get_all('Received') or [])}"
            + f" | type: {msg.get_content_type()} | via auth-mail (hook): {'ja' if str(msg.get('X-Bingr-Mail') or '').startswith('auth-') else 'nee'}"
            + f" | kopregels: {','.join(names)}"
            + (f" | na {round(time.time() - t_sent)} s" if t_sent else ""))

uid_user = None; t0 = None; signup_ok = False
try:
    # 0. bestaat er al een account met het testadres? (dan stuurt Auth geen mail)
    code, r = sql(f"select now()::text t, (select count(*) from auth.users where lower(email) = lower({lit(to)}))::int n")
    t0 = r[0]["t"] if code < 300 and isinstance(r, list) and r else None
    # 1. controlemail via dezelfde SMTP-login en afzender als Auth
    t_ctrl = None
    try:
        m = EmailMessage(); m["From"] = E.get("S_FROM") or sender; m["To"] = to
        m["Subject"] = f"Bingr CI mailtest {tag}"; m["Auto-Submitted"] = "auto-generated"; m["Message-ID"] = email.utils.make_msgid(domain="bingr.online")
        m["Date"] = email.utils.formatdate(localtime=False); m.set_content("Automatische controle van de Bingr-mail. Wordt direct verwijderd.")
        port = int((E.get("S_PORT") or "465").strip() or 465)
        with (smtplib.SMTP_SSL(E["S_HOST"].strip(), port, timeout=30, context=ssl.create_default_context()) if port == 465
              else smtplib.SMTP(E["S_HOST"].strip(), port, timeout=30)) as s:
            if port != 465: s.starttls(context=ssl.create_default_context())
            s.login(E["S_USER"].strip(), E["S_PASS"]); s.send_message(m)
        t_ctrl = time.time(); note("mailtest controle", "verstuurd via BINGR_SMTP_* (geaccepteerd door de server)")
    except Exception as e:
        warn.append(f"controlemail niet verstuurd: {type(e).__name__}")
    # 2. echte aanmelding (zoals de apps en de website)
    pw = secrets.token_urlsafe(18); mask(pw)
    code, r = req("POST", f"{BASE}/auth/v1/signup", {"email": to, "password": pw,
                  "data": {"lang": "nl", "first_name": "CI", "last_name": "Mailtest"}}, {"apikey": PUB})
    t_auth = time.time()
    u = (r.get("user") or r) if isinstance(r, dict) else {}
    uid_user = u.get("id")
    if uid_user: mask(uid_user)
    if code == 200 and uid_user:
        signup_ok = True
        note("mailtest aanmelding", f"HTTP 200 | sessie terug (geen bevestiging nodig): {'ja' if r.get('access_token') else 'nee'} | "
             f"confirmation_sent_at gezet: {'ja' if u.get('confirmation_sent_at') else 'nee'} | identities: {len(u.get('identities') or [])}")
    else:
        msg = re.sub(r"[^\s\"'<>]+@[^\s\"'<>]+", "<e>", str((r or {}).get("msg") or (r or {}).get("message") or (r or {}).get("error_code") or ""))[:160]
        fail.append(f"aanmelding mislukt: HTTP {code} {msg}")
    # 3. wachten op beide mails
    got = {}
    want = {"auth"} if signup_ok else set()
    if t_ctrl: want.add("controle")
    deadline = time.time() + WAIT
    while want - set(got) and time.time() < deadline:
        time.sleep(10)
        try:
            c = imap(); got = find(c); c.logout()
        except Exception as e:
            warn.append(f"IMAP: {type(e).__name__}"); break
    for kind, t in (("controle", t_ctrl), ("auth", t_auth)):
        if kind not in want: continue
        if kind in got: note(f"mailtest {kind}mail", "binnengekomen: ja | " + summary(got[kind][0], got[kind][2], t))
        else: note(f"mailtest {kind}mail", f"binnengekomen: nee (na {WAIT} s)")
    if signup_ok and "auth" not in got:
        fail.append("bevestigingsmail van Supabase Auth niet binnengekomen" + (" (controlemail wel)" if "controle" in got else ""))
    elif signup_ok and "auth" in got and re.search(r"spam|junk|ongewenst", got["auth"][0], re.I):
        fail.append("bevestigingsmail van Supabase Auth komt in de spammap")
    if signup_ok and "auth" in got:
        am = got["auth"][2]
        if not am.get("Message-ID"): fail.append("bevestigingsmail zonder Message-ID (Gmail/Outlook stellen die uit of weigeren hem)")
        if E.get("MAILTEST_REQUIRE_HOOK") and not str(am.get("X-Bingr-Mail") or "").startswith("auth-"):
            fail.append("bevestigingsmail niet via de Send Email Hook (auth-mail) verstuurd")
    if t_ctrl and "controle" not in got: warn.append("controlemail niet binnengekomen (plus-adres of mailbox?)")
    # Auth-logs rond de aanmelding: alleen meldingen met 'mail'/smtp (zonder adressen)
    try:
        import datetime, urllib.parse
        end = datetime.datetime.now(datetime.timezone.utc); start = end - datetime.timedelta(minutes=10)
        q = "select event_message from logs where source_name = 'auth_logs' order by timestamp desc limit 300"
        qs = urllib.parse.urlencode({"sql": q, "iso_timestamp_start": start.strftime("%Y-%m-%dT%H:%M:%SZ"), "iso_timestamp_end": end.strftime("%Y-%m-%dT%H:%M:%SZ")})
        code, lr = req("GET", f"{API}/analytics/endpoints/logs?{qs}", headers={"Authorization": f"Bearer {MGMT}"})
        cnt = {}
        for row in (lr.get("result") or []) if isinstance(lr, dict) else []:
            s = str(row.get("event_message") or "")
            try: j = json.loads(s)
            except Exception: j = {"msg": s}
            text = f"{j.get('msg') or ''} {j.get('error') or ''}"
            if re.search(r"mail|smtp|535|550|554|EOF|timeout|dial tcp|rate limit", text, re.I) and not re.search(r"^request (started|completed)\s*$", text.strip()):
                t = re.sub(r"[^\s\"'<>]+@[^\s\"'<>]+", "<e>", text); t = re.sub(r"\b\d{1,3}(\.\d{1,3}){3}(:\d+)?\b", "<ip>", t)
                t = re.sub(r"\b[\w-]+(\.[\w-]+)+:\d+\b", "<host>", t)[:120]
                cnt[f"{j.get('level') or '?'}: {t}"] = cnt.get(f"{j.get('level') or '?'}: {t}", 0) + 1
        note("mailtest auth-logs (10 min)", json.dumps(cnt, ensure_ascii=False) if cnt else f"geen mailregels (HTTP {code})")
    except Exception as e:
        note("mailtest auth-logs (10 min)", f"niet gelezen: {type(e).__name__}")
finally:
    # 4. opruimen: testmails (alle mappen), testaccount, hookpoging en regels van de inbox-import
    try:
        c = imap(); left = find(c); n = 0
        for kind, (f, uid, _) in left.items():
            c.select(f); c.uid("STORE", uid, "+FLAGS.SILENT", r"(\Deleted)"); c.expunge(); n += 1
        c.logout(); note("mailtest opruimen", f"testmails verwijderd: {n}")
    except Exception as e:
        warn.append(f"testmails niet verwijderd: {type(e).__name__}")
    if not uid_user and key:
        code, r = sql(f"select id::text from auth.users where lower(email) = lower({lit(to)})")
        if code < 300 and isinstance(r, list) and r: uid_user = r[0].get("id"); mask(uid_user)
    if uid_user and key:
        code, _ = req("DELETE", f"{BASE}/auth/v1/admin/users/{uid_user}", None, adm)
        if code not in (200, 204, 404): warn.append(f"testaccount niet verwijderd (HTTP {code})")
    if t0 and signup_ok:
        sql(f"delete from public.signup_attempts where id = (select max(id) from public.signup_attempts where allowed and at >= {lit(t0)}::timestamptz)")
    if t0:
        sql(f"delete from public.support_inbox_log where at >= {lit(t0)}::timestamptz and (subject like {lit('%' + tag + '%')} or lower(coalesce(sender, '')) = lower({lit(sender)}))")

for w in warn: print(f"::warning::{w[:300]}")
for f in fail: print(f"::error::{f[:300]}")
if not fail: print("::notice title=mailtest::Bevestigingsmail van Supabase Auth komt aan (echte aanmelding, via IMAP gecontroleerd)")
sys.exit(1 if fail else 0)
