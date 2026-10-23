# Rooktest van de inbox-import (workflow Backend, job inbox; build 140). Het log is OPENBAAR: alleen ja/nee, tellingen en
# HTTP-codes; adressen, sleutels en het testlabel worden gemaskeerd.
#   1. tijdelijke mailtest-sleutel in app_settings ('mailtest', zie _shared/mail.ts) en het planningsgeheim uit cron.job
#   2. een testmail via BINGR_SMTP_* naar support+ci-…@bingr.online, als klant (afzender = het testadres); komt hij niet aan
#      (of weigert de SMTP-server die afzender), dan dezelfde mail via IMAP APPEND in de plusmap
#   3. support/poll_inbox (met ci_tag: ook de plusmap) -> precies één nieuw ticket met één bericht uit de mail
#   4. antwoord met [#nummer] en In-Reply-To -> in DAT ticket (geen tweede ticket); dezelfde mail nog eens -> niet dubbel
#   5. opruimen: testtickets, logregels, sleutel, testmails en de plusmap. Testtickets geven geen push en geen melding aan
#      support@ (functie push en support slaan support+ci-…@bingr.online over).
import email.utils, hashlib, imaplib, json, os, re, secrets, smtplib, ssl, sys, time, urllib.error, urllib.request
from email.message import EmailMessage

E = os.environ
REF, MGMT = (E.get("REF") or "").strip(), (E.get("SUPABASE_ACCESS_TOKEN") or "").strip()
FN = f"https://{REF}.supabase.co/functions/v1/support"
fail, warn = [], []


def mask(v):
    if v: print(f"::add-mask::{v}")


def note(title, msg): print(f"::notice title={title}::{str(msg)[:1500]}")


def lit(s): return "'" + str(s).replace("'", "''") + "'"


def req(method, url, body=None, headers=None, timeout=90):
    r = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body is not None else None,
                               headers={"Content-Type": "application/json", **(headers or {})})
    try:
        with urllib.request.urlopen(r, timeout=timeout) as resp: return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e:
        try: return e.code, json.loads(e.read() or b"null")
        except Exception: return e.code, None
    except Exception as e: return 0, {"error": type(e).__name__}


def sql(q):
    return req("POST", f"https://api.supabase.com/v1/projects/{REF}/database/query", {"query": q}, {"Authorization": f"Bearer {MGMT}"})


if not (REF and MGMT): print("::warning::inbox-rooktest: SUPABASE_* ontbreken, overgeslagen"); sys.exit(0)
if not (E.get("I_HOST") and E.get("I_USER") and E.get("I_PASS")): print("::notice::inbox-rooktest: BINGR_IMAP_* ontbreken, overgeslagen"); sys.exit(0)
for k in ("I_USER", "I_PASS", "I_HOST", "S_USER", "S_PASS", "S_HOST", "S_FROM"): mask(E.get(k))

tag = "ci-" + secrets.token_hex(5)
to = f"support+{tag}@bingr.online"
mask(tag); mask(to)
key = secrets.token_hex(32); mask(key)
sha = hashlib.sha256(key.encode()).hexdigest()

# planningsgeheim (x-support-cron) uit de pg_cron-taak; nooit in het log
code, r = sql("select command from cron.job where jobname = 'bingr-support-inbox'")
m = re.search(r"'x-support-cron',\s*'([A-Za-z0-9_-]{24,128})'", (r[0].get("command") or "") if isinstance(r, list) and r else "")
if not m: print("::warning::inbox-rooktest: geen planning bingr-support-inbox (IMAP uit?), overgeslagen"); sys.exit(0)
cron = m.group(1); mask(cron)
H = {"x-support-cron": cron, "x-bingr-mailtest": key}


def imap():
    c = imaplib.IMAP4_SSL(E["I_HOST"].strip(), int((E.get("I_PORT") or "993").strip() or 993), ssl_context=ssl.create_default_context(), timeout=60)
    c.login(E["I_USER"].strip(), E["I_PASS"])
    return c


def folders(c):
    out, delim = [], "."
    for b in c.list()[1] or []:
        s = b.decode(errors="replace")
        if re.search(r"\\Noselect|\\NonExistent", s, re.I): continue
        mm = re.search(r'\) (?:"([^"]*)"|NIL) (.+)$', s)
        if mm:
            name = mm.group(2).strip().strip('"'); out.append(name)
            if name.upper() == "INBOX" and mm.group(1): delim = mm.group(1)
    return out, delim


def find(c, mid):
    """Mappen waar een mail met deze Message-ID staat."""
    hits = []
    for f in folders(c)[0]:
        if c.select(f'"{f}"', readonly=True)[0] != "OK": continue
        t, d = c.uid("SEARCH", None, "HEADER", "Message-ID", f'"{mid}"')
        if t == "OK" and d and d[0].split(): hits.append(f)
    return hits


def mail(subject, mid, body, extra=None):
    m = EmailMessage()
    m["From"] = f"Bingr CI <{to}>"; m["To"] = to; m["Subject"] = subject; m["Message-ID"] = mid
    m["Date"] = email.utils.formatdate(localtime=False)
    for k, v in (extra or {}).items(): m[k] = v
    m.set_content(body)
    return m


def poll(label):
    for _ in range(14):
        code, r = req("POST", FN, {"action": "poll_inbox", "source": "ci", "ci_tag": tag}, H, timeout=100)
        if code == 200 and isinstance(r, dict) and r.get("busy"): time.sleep(10); continue
        if code != 200 or not isinstance(r, dict) or not r.get("ok"):
            fail.append(f"poll_inbox ({label}) gaf HTTP {code}: {str((r or {}).get('error') if isinstance(r, dict) else r)[:200]}")
            return {}
        note(f"inbox-rooktest poll {label}", ", ".join(f"{k}={r.get(k)}" for k in ("fetched", "imported", "new_tickets", "duplicates", "ignored", "rejected", "errors", "pending", "keywords", "ci_folder")))
        return r
    fail.append(f"poll_inbox ({label}): bleef bezet")
    return {}


def ticket_state():
    code, r = sql(f"select t.number, t.status, (select count(*) from public.support_messages m where m.ticket_id = t.id and m.author = 'customer' and m.source = 'email')::int msgs "
                  f"from public.support_tickets t where t.email = {lit(to)} order by t.number")
    return r if isinstance(r, list) else []


mid1 = email.utils.make_msgid(idstring="ci", domain="bingr.online"); mid2 = email.utils.make_msgid(idstring="ci", domain="bingr.online")
mask(mid1); mask(mid2)
t0 = None
try:
    code, r = sql("select now()::text t"); t0 = r[0]["t"] if isinstance(r, list) and r else None
    val = json.dumps({"sha256": sha})
    code, _ = sql(f"insert into public.app_settings (key, value, updated_at) values ('mailtest', {lit(val)}::jsonb || jsonb_build_object('until', now() + interval '20 minutes'), now()) "
                  f"on conflict (key) do update set value = excluded.value, updated_at = now()")
    if code >= 300: raise SystemExit(print(f"::error::inbox-rooktest: mailtest-sleutel niet gezet (HTTP {code})") or 1)

    # 2. testmail versturen
    via = "smtp"
    m1 = mail(f"Bingr CI inbox {tag}", mid1, "Automatische controle van de inbox-import. Wordt direct verwijderd.")
    try:
        port = int((E.get("S_PORT") or "465").strip() or 465)
        with (smtplib.SMTP_SSL(E["S_HOST"].strip(), port, timeout=30, context=ssl.create_default_context()) if port == 465
              else smtplib.SMTP(E["S_HOST"].strip(), port, timeout=30)) as s:
            if port != 465: s.starttls(context=ssl.create_default_context())
            s.login(E["S_USER"].strip(), E["S_PASS"]); s.send_message(m1, from_addr=E["S_USER"].strip(), to_addrs=[to])
    except Exception as e:
        via = f"append (smtp: {type(e).__name__})"
    c = imap()
    where = []
    if via == "smtp":
        for _ in range(18):
            where = find(c, mid1)
            if where: break
            time.sleep(10)
        if not where: via = "append (smtp: niet aangekomen in 3 min)"
    flist, delim = folders(c)
    ci_box = next((f for f in flist if f.split(delim)[-1].lower() == tag), None)
    if not where:
        ci_box = ci_box or f"INBOX{delim}{tag}"
        if ci_box not in flist: c.create(f'"{ci_box}"')
        t, _ = c.append(f'"{ci_box}"', None, None, m1.as_bytes())
        if t != "OK": fail.append("APPEND van de testmail mislukt")
        where = [ci_box]
    box = where[0]
    kind = "plusmap" if box.split(delim)[-1].lower() == tag else "INBOX" if box.upper() == "INBOX" else "andere map"
    note("inbox-rooktest testmail", f"via {via}; aangekomen in: {kind}")
    if kind == "andere map": warn.append("testmail kwam in een andere map dan INBOX of de plusmap (spam?)")

    # 3. nieuw ticket
    rows = []
    for i in range(3):
        poll(f"nieuw {i + 1}")
        rows = ticket_state()
        if rows: break
        time.sleep(15)
    if len(rows) != 1 or rows[0]["msgs"] != 1: fail.append(f"testmail -> verwacht 1 ticket met 1 bericht, kreeg {len(rows)} ticket(s) {[x['msgs'] for x in rows]}")
    else: note("inbox-rooktest nieuw ticket", "ja: 1 ticket met 1 bericht uit de mail")

    # 4. antwoord in hetzelfde ticket, daarna dezelfde mail nog eens (idempotent op Message-ID)
    if len(rows) == 1:
        n = rows[0]["number"]
        m2 = mail(f"Re: [#{n}] Bingr CI inbox", mid2, "Antwoord op het testticket.",
                  {"In-Reply-To": f"<bingr-ticket-{n}@bingr.online>", "References": f"<bingr-ticket-{n}@bingr.online>"})
        target = ci_box or next((f for f in folders(c)[0] if f.split(delim)[-1].lower() == tag), None) or "INBOX"
        c.append(f'"{target}"', None, None, m2.as_bytes())
        poll("antwoord")
        rows = ticket_state()
        if len(rows) != 1 or rows[0]["msgs"] != 2: fail.append(f"antwoord -> verwacht 1 ticket met 2 berichten, kreeg {len(rows)} ticket(s) {[x['msgs'] for x in rows]}")
        else: note("inbox-rooktest antwoord", "ja: in hetzelfde ticket (2 berichten, geen tweede ticket)")
        c.append(f'"{target}"', None, None, m2.as_bytes())
        r = poll("dubbel")
        rows = ticket_state()
        if len(rows) != 1 or rows[0]["msgs"] != 2: fail.append(f"dubbele mail -> verwacht nog steeds 1 ticket met 2 berichten, kreeg {len(rows)} {[x['msgs'] for x in rows]}")
        elif not r.get("duplicates"): warn.append("dubbele mail niet als duplicate geteld")
        else: note("inbox-rooktest dubbel", "ja: dezelfde Message-ID niet nog eens opgeslagen")
    try: c.logout()
    except Exception: pass
finally:
    # 5. opruimen
    n_mail = 0
    try:
        c = imap()
        flist, delim = folders(c)
        for f in flist:
            if c.select(f'"{f}"')[0] != "OK": continue
            uids = set()
            for crit in (("HEADER", "Message-ID", f'"{mid1}"'), ("HEADER", "Message-ID", f'"{mid2}"'), ("TO", f'"{tag}"')):
                t, d = c.uid("SEARCH", None, *crit)
                if t == "OK" and d and d[0]: uids |= set(d[0].split())
            for u in uids: c.uid("STORE", u, "+FLAGS.SILENT", r"(\Deleted)"); n_mail += 1
            if uids: c.expunge()
        c.select("INBOX")
        for f in flist:
            if f.split(delim)[-1].lower() == tag: c.delete(f'"{f}"')
        c.logout()
    except Exception as e:
        warn.append(f"testmails opruimen: {type(e).__name__}")
    stmts = [f"delete from public.support_tickets where email = {lit(to)}",
             f"delete from public.support_inbox_log where folder like {lit('%' + tag)} or sender = {lit(to)} or message_id in ({lit(mid1)}, {lit(mid2)})"
             + (f" or (at >= {lit(t0)}::timestamptz and coalesce(subject, '') like {lit('%' + tag + '%')})" if t0 else ""),
             f"delete from public.app_settings where key = 'mailtest' and value->>'sha256' = {lit(sha)}"]
    for q in stmts:
        code, _ = sql(q)
        if code >= 300: warn.append(f"opruimen gaf HTTP {code}")
    code, r = sql(f"select count(*)::int n from public.support_tickets where email = {lit(to)}")
    left = r[0]["n"] if isinstance(r, list) and r else "?"
    note("inbox-rooktest opgeruimd", f"{n_mail} testmail(s) verwijderd, testtickets over: {left}")
    for w in warn: print(f"::warning::inbox-rooktest: {w}")
    for f in fail: print(f"::error::inbox-rooktest: {f}")
    if fail: sys.exit(1)
