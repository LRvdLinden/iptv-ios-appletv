# End-to-end test van ALLE mails die Bingr verstuurt (workflow Diagnose, invoer alle_mails). Niet bij elke Backend-run:
# ±20 mails, een aanmelding en een supportticket per keer.
# Het log is OPENBAAR: alleen ja/nee, tijden, domeinen, HTTP-codes en SPF/DKIM/DMARC-uitkomsten; nooit tokens, links met
# tokens, wachtwoorden, IP's of inhoud. Adressen alleen als soort (testadres support+ci-…@bingr.online of support@).
#
# Werkwijze:
#   1. tijdelijke mailtest-sleutel in app_settings ('mailtest', SHA-256 + geldig tot, max. 25 min; zie _shared/mail.ts);
#      daarmee mogen newsletter/status/support/admin alleen voorbeeld- en testmails naar support+ci-…@bingr.online sturen;
#   2. Auth (via de Send Email Hook auth-mail): aanmelding (bevestigen), wachtwoord vergeten, inloglink (magic link),
#      e-mailadres wijzigen, verificatiecode (alleen als Auth die vraagt); daarna de ECHTE welkomstmail (pg_cron, ≤ 5 min);
#   3. voorbeelden: nieuwsbrief, welkomstmail, statusmelding, monitoringmail; echt: bevestiging statusupdates;
#      supportticket als gast (captcha opgelost) met reactie, antwoord, status opgelost en sluiten (6 mails);
#      accountmails van het beheer (verwijderd, geblokkeerd, opgeheven) met voorbeeldgegevens (admin, mailtest_account_mails);
#   4. via IMAP (BINGR_IMAP_*, mailbox support@) per mail: aangekomen + vertraging, kopregels, Authentication-Results,
#      DKIM-Signature, List-Unsubscribe, taal, links (domein + HTTP-code, alleen GET zonder redirect; de pagina's op
#      bingr.online gebruiken een token pas na een klik) en afbeeldingen;
#   5. externe controle van SPF/DKIM/DMARC: mails tussen adressen op dezelfde server worden vaak niet ondertekend en niet
#      gecontroleerd. Daarom één controlemail via BINGR_SMTP_* (dezelfde server en login als alle functies) naar de
#      automatische verifier van Port25 (check-auth@verifier.port25.com, geen inhoud of gegevens van gebruikers); het
#      rapport komt terug in de mailbox van de afzender (BINGR_SMTP_USER via IMAP) en wordt daarna verwijderd;
#   6. opruimen: testmails (alle mappen), testaccount, testticket(s), statusabonnement, logregels en de sleutel.
# Env: REF, SUPABASE_ACCESS_TOKEN, I_HOST, I_PORT, I_USER, I_PASS, S_HOST, S_PORT, S_USER, S_PASS, S_FROM (optioneel, voor 5),
#      MAILTEST_WAIT (s, standaard 420).
import email, email.policy, email.utils, hashlib, html as htmlmod, imaplib, json, os, re, secrets, smtplib, ssl, sys, time
from email.message import EmailMessage
import urllib.error, urllib.parse, urllib.request

E = os.environ
REF = E.get("REF", ""); MGMT = E.get("SUPABASE_ACCESS_TOKEN", "")
BASE = f"https://{REF}.supabase.co"; FN = f"{BASE}/functions/v1"; PUB = "sb_publishable_lpIup6Omq5kW2k3oICGZ4g_HPGac5A3"
API = f"https://api.supabase.com/v1/projects/{REF}"
WAIT = int(E.get("MAILTEST_WAIT") or 420)
SUPPORT = "support@bingr.online"
OWN = {"bingr.online", "support.bingr.online", "beheer.bingr.online"}
OK_EXTERNAL = {"image.tmdb.org", "www.themoviedb.org", "testflight.apple.com", "apps.apple.com", "play.google.com"}
fail, warn, rows = [], [], []

def note(title, msg): print(f"::notice title={title}::" + str(msg)[:3800].replace("%", "%25").replace("\r", "").replace("\n", "%0A"))
def mask(v):
    if v: print(f"::add-mask::{v}")

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *a, **k): return None
plain_opener = urllib.request.build_opener()
noredir_opener = urllib.request.build_opener(NoRedirect)

def req(method, url, body=None, headers=None, timeout=60):
    h = {"Content-Type": "application/json", **(headers or {})}
    r = urllib.request.Request(url, data=None if body is None else json.dumps(body).encode(), method=method, headers=h)
    try:
        with plain_opener.open(r, timeout=timeout) as resp: raw = resp.read(); code = resp.status
    except urllib.error.HTTPError as e: raw = e.read(); code = e.code
    except Exception: return 0, {}
    try: return code, json.loads(raw or b"{}")
    except Exception: return code, {}

def http_status(url):
    """GET zonder redirects te volgen (een 30x telt als goed); (code, content-type)."""
    r = urllib.request.Request(url, method="GET", headers={"User-Agent": "BingrMailtest/1.0"})
    try:
        with noredir_opener.open(r, timeout=20) as resp: return resp.status, resp.headers.get("Content-Type", "")
    except urllib.error.HTTPError as e: return e.code, e.headers.get("Content-Type", "") if e.headers else ""
    except Exception as e: return 0, type(e).__name__

def sql(q): return req("POST", f"{API}/database/query", {"query": q}, {"Authorization": f"Bearer {MGMT}"})
def lit(s): return "'" + str(s).replace("'", "''") + "'"
def errtxt(r):
    s = str((r or {}).get("error") or (r or {}).get("msg") or (r or {}).get("error_code") or (r or {}).get("message") or "") if isinstance(r, dict) else ""
    return re.sub(r"[^\s\"'<>]+@[^\s\"'<>]+", "<e>", s)[:80]

if not (REF and MGMT): print("::warning::alle_mails: SUPABASE_* ontbreken, overgeslagen"); sys.exit(0)
if not (E.get("I_HOST") and E.get("I_USER") and E.get("I_PASS")): print("::warning::alle_mails: BINGR_IMAP_* ontbreken, overgeslagen"); sys.exit(0)
for k in ("I_USER", "I_PASS", "I_HOST", "S_USER", "S_PASS", "S_HOST", "S_FROM"): mask(E.get(k))
mask(email.utils.parseaddr(E.get("S_FROM") or "")[1])

tag = "ci-" + secrets.token_hex(5)
addr = {k: f"support+{tag}{'-' + k if k else ''}@bingr.online" for k in ("", "new", "nb", "wp", "st", "sp", "ad")}
A = addr[""]
key = secrets.token_hex(32); mask(key)
MT = {"x-bingr-mailtest": key}

# geheime sleutel (admin-API) voor Auth-beheer en opruimen
code, keys = req("GET", f"{API}/api-keys?reveal=true", headers={"Authorization": f"Bearer {MGMT}"})
skey = None
for k in keys if isinstance(keys, list) else []:
    v = k.get("api_key") or ""
    if v and (k.get("name") == "service_role" or k.get("type") == "secret") and "·" not in v: skey = v; break
mask(skey)
adm = {"apikey": skey or "", **({"Authorization": f"Bearer {skey}"} if skey and skey.startswith("ey") else {})}

code, cfg = req("GET", f"{API}/config/auth", headers={"Authorization": f"Bearer {MGMT}"})
cfg = cfg if isinstance(cfg, dict) else {}
yn = lambda b: "ja" if b else "nee"
reauth_on = bool(cfg.get("security_update_password_require_reauthentication"))
secure_change = cfg.get("mailer_secure_email_change_enabled") is not False
note("alle_mails auth-config", " | ".join([
    f"Send Email Hook aan: {yn(cfg.get('hook_send_email_enabled'))}", f"autoconfirm: {cfg.get('mailer_autoconfirm')}",
    f"secure email change: {yn(secure_change)}", f"reauthentication vereist: {yn(reauth_on)}",
    f"e-mail-OTP/magic link mogelijk: {yn(cfg.get('external_email_enabled'))}", f"smtp_max_frequency: {cfg.get('smtp_max_frequency')}",
    f"rate_limit_email_sent: {cfg.get('rate_limit_email_sent')}", f"mailer_otp_exp: {cfg.get('mailer_otp_exp')}"]))

# verwacht: sleutel -> {to, lang, unsub (List-Unsubscribe verplicht), main (regex van de hoofdlink), t (verstuurd om)}
expect = {}
def expect_mail(k, to, lang, main=None, unsub=False, t=None, header=None):
    expect[k] = {"to": to.lower(), "lang": lang, "main": main, "unsub": unsub, "t": t or time.time(), "header": header or k}

uid_user = None; t0_db = None; signup_ok = False; ticket = None
code, r = sql("select now()::text t")
t0_db = r[0]["t"] if code < 300 and isinstance(r, list) and r else None
try:
    # ---- 1. mailtest-sleutel ----
    val = json.dumps({"sha256": hashlib.sha256(key.encode()).hexdigest()})
    code, r = sql(f"insert into public.app_settings (key, value, updated_at) values ('mailtest', {lit(val)}::jsonb || jsonb_build_object('until', now() + interval '25 minutes'), now()) "
                  f"on conflict (key) do update set value = excluded.value, updated_at = now()")
    if code >= 300: fail.append(f"mailtest-sleutel niet gezet (HTTP {code})")

    # ---- 2. Auth: aanmelding ----
    pw = secrets.token_urlsafe(18); mask(pw)
    code, r = req("POST", f"{BASE}/auth/v1/signup", {"email": A, "password": pw, "data": {"lang": "nl", "first_name": "CI", "last_name": "Mailtest"}}, {"apikey": PUB})
    u = (r.get("user") or r) if isinstance(r, dict) else {}
    uid_user = u.get("id"); mask(uid_user)
    if code == 200 and uid_user:
        signup_ok = True
        if r.get("access_token"):
            # bevestigen staat uit (autoconfirm): onbevestigd maken en de bevestigingsmail opnieuw laten sturen (zelfde template)
            sql(f"update auth.users set email_confirmed_at = null, confirmation_sent_at = null where id = {lit(uid_user)}")
            time.sleep(2)
            c2, r2 = req("POST", f"{BASE}/auth/v1/resend", {"type": "signup", "email": A}, {"apikey": PUB})
            if c2 >= 300: fail.append(f"bevestigingsmail opnieuw sturen: HTTP {c2} {errtxt(r2)}")
        expect_mail("auth-confirmation", A, "nl", r"^https://bingr\.online/bevestigen/\?token_hash=[^&]+&type=signup")
    else:
        fail.append(f"aanmelding mislukt: HTTP {code} {errtxt(r)}")

    # ---- 3. voorbeelden en echte mails buiten Auth ----
    c, r = req("POST", f"{FN}/newsletter", {"action": "preview", "to": addr["nb"], "lang": "en"}, MT, timeout=120)
    if c == 200: expect_mail("newsletter-preview", addr["nb"], "en", r"^https://bingr\.online/", unsub=True)
    else: fail.append(f"nieuwsbrief-voorbeeld: HTTP {c} {errtxt(r)}")
    c, r = req("POST", f"{FN}/newsletter", {"action": "welcome_preview", "to": addr["wp"], "lang": "en"}, MT)
    if c == 200: expect_mail("welcome-preview", addr["wp"], "en", r"^https://bingr\.online/", unsub=True)
    else: fail.append(f"welkomstmail-voorbeeld: HTTP {c} {errtxt(r)}")
    c, r = req("POST", f"{FN}/status", {"action": "subscribe", "email": addr["st"], "lang": "en"}, {"apikey": PUB})
    if c == 200: expect_mail("status-confirm", addr["st"], "en", r"^https://bingr\.online/status/\?confirm=")
    else: fail.append(f"statusupdates aanmelden: HTTP {c} {errtxt(r)}")
    c, r = req("POST", f"{FN}/status", {"action": "mail_preview", "to": addr["st"], "lang": "nl", "kind": "notice"}, MT)
    if c == 200: expect_mail("status-notice", addr["st"], "nl", r"^https://bingr\.online/status/", unsub=True)
    else: fail.append(f"statusmelding-voorbeeld: HTTP {c} {errtxt(r)}")
    c, r = req("POST", f"{FN}/status", {"action": "mail_preview", "to": addr["st"], "lang": "nl", "kind": "alert"}, MT)
    if c == 200: expect_mail("status-alert-preview", addr["st"], "nl", r"^https://beheer\.bingr\.online/")
    else: fail.append(f"monitoringmail-voorbeeld: HTTP {c} {errtxt(r)}")
    c, r = req("POST", f"{FN}/admin", {"action": "mailtest_account_mails", "to": addr["ad"], "lang": "en"}, {"apikey": PUB, **MT})
    if c in (200, 502) and isinstance(r, dict) and isinstance(r.get("sent"), dict):
        for k2 in ("deleted", "blocked", "unblocked"):
            if r["sent"].get(k2):
                expect_mail(f"account-{k2}", addr["ad"], "en", {"deleted": r"^https://bingr\.online/?$", "blocked": r"^https://support\.bingr\.online/nieuw/", "unblocked": r"^https://bingr\.online/account/"}[k2])
            else: fail.append(f"accountmail {k2}: niet verstuurd")
    else: fail.append(f"accountmails (beheer): HTTP {c} {errtxt(r)}")

    # supportticket als gast: captcha oplossen zoals de browser
    c, ch = req("POST", f"{FN}/support", {"action": "challenge"}, {"apikey": PUB})
    if c == 200 and isinstance(ch, dict) and ch.get("salt"):
        need = int(ch["difficulty"]); n = 0
        while True:
            d = hashlib.sha256((ch["salt"] + str(n)).encode()).digest()
            bits = 0
            for x in d:
                if x == 0: bits += 8; continue
                bits += 8 - x.bit_length(); break
            if bits >= need: break
            n += 1
        time.sleep(3)  # het formulier telt "te snel" (< 2,5 s) als spam
        c, r = req("POST", f"{FN}/support", {
            "action": "create", "name": "CI Mailtest", "email": addr["sp"], "category": "overig", "platform": "web",
            "subject": f"Mailtest {tag}", "message": "Automatische controle van de supportmails. Wordt direct verwijderd.",
            "lang": "en", "website": "", "elapsed_ms": 5000,
            "pow": {"salt": ch["salt"], "difficulty": ch["difficulty"], "expires": ch["expires"], "signature": ch["signature"], "nonce": str(n)}}, {"apikey": PUB})
        if c == 200 and r.get("number"):
            ticket = {"n": int(r["number"]), "t": r.get("token")}; mask(ticket["t"])
            tn = ticket["n"]
            # bestaat het ticket echt (een geweigerde captcha geeft een schijnbaar "gelukt")
            cc, rr = sql(f"select count(*)::int n from public.support_tickets where number = {tn} and email = {lit(addr['sp'])}")
            if not (cc < 300 and isinstance(rr, list) and rr and rr[0].get("n") == 1):
                fail.append("supportticket niet opgeslagen (captcha of lokveld tegengehouden?)"); ticket = None
        else: fail.append(f"supportticket aanmaken: HTTP {c} {errtxt(r)}")
    else: fail.append(f"support-captcha: HTTP {c}")
    if ticket:
        tn = ticket["n"]; turl = r"^https://support\.bingr\.online/ticket/\?n=" + str(tn); burl = r"^https://beheer\.bingr\.online/"
        expect_mail("support-customer_created", addr["sp"], "en", turl)
        expect_mail("support-support_created", SUPPORT, "nl", burl)
        steps = [
            ("reply", {"action": "reply", "n": tn, "t": ticket["t"], "message": "Reactie van de klant (mailtest)."}, {"apikey": PUB}, ("support-support_reply", SUPPORT, "nl", burl)),
            ("admin_reply", {"action": "admin_reply", "number": tn, "message": "Antwoord van support (mailtest)."}, {"apikey": PUB, **MT}, ("support-customer_reply", addr["sp"], "en", turl)),
            ("admin_status", {"action": "admin_status", "number": tn, "status": "resolved"}, {"apikey": PUB, **MT}, ("support-customer_status", addr["sp"], "en", turl)),
            ("close", {"action": "close", "n": tn, "t": ticket["t"]}, {"apikey": PUB}, ("support-support_closed", SUPPORT, "nl", burl)),
        ]
        for name, body, hdr, ex in steps:
            time.sleep(1)
            c, r = req("POST", f"{FN}/support", body, hdr)
            if c == 200 and (r.get("email_sent") is not False): expect_mail(*ex)
            else: fail.append(f"support {name}: HTTP {c} {errtxt(r)} (mail verstuurd: {r.get('email_sent') if isinstance(r, dict) else '?'})")

    # ---- 4. Auth: overige mails (eigen tijdstempel per soort; magic link deelt die met recovery: 60 s ertussen) ----
    session = None
    if signup_ok:
        sql(f"update auth.users set email_confirmed_at = now() where id = {lit(uid_user)} and email_confirmed_at is null")
        # bevestigd: de echte welkomstmail komt van pg_cron (elke 5 min)
        expect_mail("welcome", A, "nl", r"^https://bingr\.online/", unsub=False)
        t_rec = time.time()
        c, r = req("POST", f"{BASE}/auth/v1/recover?redirect_to=https%3A%2F%2Fbingr.online%2Freset", {"email": A}, {"apikey": PUB})
        if c == 200: expect_mail("auth-recovery", A, "nl", r"^https://bingr\.online/bevestigen/\?token_hash=[^&]+&type=recovery")
        else: fail.append(f"wachtwoord vergeten: HTTP {c} {errtxt(r)}")
        c, r = req("POST", f"{BASE}/auth/v1/token?grant_type=password", {"email": A, "password": pw}, {"apikey": PUB})
        session = r.get("access_token") if c == 200 and isinstance(r, dict) else None
        mask(session); mask((r or {}).get("refresh_token") if isinstance(r, dict) else None)
        if not session: fail.append(f"inloggen testaccount: HTTP {c} {errtxt(r)}")
        if session:
            c, r = req("PUT", f"{BASE}/auth/v1/user", {"email": addr["new"]}, {"apikey": PUB, "Authorization": f"Bearer {session}"})
            if c == 200:
                expect_mail("auth-email_change", addr["new"], "nl", r"^https://bingr\.online/bevestigen/\?token_hash=[^&]+&type=email_change")
                if secure_change: expect_mail("auth-email_change-current", A, "nl", r"^https://bingr\.online/bevestigen/\?token_hash=[^&]+&type=email_change", header="auth-email_change")
            else: fail.append(f"e-mailadres wijzigen: HTTP {c} {errtxt(r)}")
            if reauth_on:
                c, r = req("GET", f"{BASE}/auth/v1/reauthenticate", None, {"apikey": PUB, "Authorization": f"Bearer {session}"})
                if c == 200: expect_mail("auth-reauthentication", A, "nl", None)
                else: fail.append(f"verificatiecode: HTTP {c} {errtxt(r)}")
        if cfg.get("external_email_enabled") is not False:
            time.sleep(max(0, 63 - (time.time() - t_rec)))
            c, r = req("POST", f"{BASE}/auth/v1/otp", {"email": A, "create_user": False}, {"apikey": PUB})
            if c == 200: expect_mail("auth-magic_link", A, "nl", r"^https://bingr\.online/bevestigen/\?token_hash=[^&]+&type=magiclink")
            else: fail.append(f"inloglink (magic link): HTTP {c} {errtxt(r)}")

    # ---- 4b. externe SPF/DKIM/DMARC-controle (Port25) ----
    ext_t = None
    if E.get("S_HOST") and E.get("S_USER") and E.get("S_PASS"):
        try:
            m = EmailMessage(); m["From"] = E.get("S_FROM") or E["S_USER"]; m["To"] = "check-auth@verifier.port25.com"
            m["Subject"] = f"Bingr mailcontrole {tag}"; m["Message-ID"] = email.utils.make_msgid(domain="bingr.online")
            m["Date"] = email.utils.formatdate(localtime=False)
            m.set_content("Automatische controle van SPF, DKIM en DMARC van bingr.online.")
            m.add_alternative("<p>Automatische controle van SPF, DKIM en DMARC van bingr.online.</p>", subtype="html")
            port = int((E.get("S_PORT") or "465").strip() or 465)
            with (smtplib.SMTP_SSL(E["S_HOST"].strip(), port, timeout=30, context=ssl.create_default_context()) if port == 465
                  else smtplib.SMTP(E["S_HOST"].strip(), port, timeout=30)) as sm:
                if port != 465: sm.starttls(context=ssl.create_default_context())
                sm.login(E["S_USER"].strip(), E["S_PASS"]); sm.send_message(m)
            ext_t = time.time()
        except Exception as e:
            warn.append(f"externe controle niet verstuurd: {type(e).__name__}")

    # ---- 5. IMAP: wachten tot alles binnen is ----
    def imap():
        c = imaplib.IMAP4_SSL(E["I_HOST"].strip(), int((E.get("I_PORT") or "993").strip() or 993), ssl_context=ssl.create_default_context(), timeout=60)
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
    def search(c):
        """Alle testmails in alle mappen: [(map, uid)]"""
        hits = []
        for f in folders(c):
            try:
                typ, _ = c.select(f, readonly=False)
                if typ != "OK": continue
                uids = set()
                typ, data = c.uid("SEARCH", None, "TO", f'"{tag}"')
                if typ == "OK" and data and data[0]: uids.update(data[0].split())
                if ticket:
                    typ, data = c.uid("SEARCH", None, "HEADER", "X-Bingr-Ticket", str(ticket["n"]))
                    if typ == "OK" and data and data[0]: uids.update(data[0].split())
                hits += [(f, u) for u in uids]
            except Exception: continue
        return hits
    def key_of(msg):
        h = str(msg.get("X-Bingr-Mail") or "").strip().lower()
        to = email.utils.getaddresses([str(msg.get("To") or "")])
        to = to[0][1].lower() if to else ""
        if h == "auth-email_change": return "auth-email_change" if to == addr["new"] else "auth-email_change-current"
        return h or "?"
    got, seen_at = {}, {}
    deadline = time.time() + WAIT
    while time.time() < deadline and set(expect) - set(got):
        time.sleep(15)
        try:
            c = imap()
            for f, uid in search(c):
                if (f, uid) in seen_at: continue
                c.select(f, readonly=True)
                typ, d = c.uid("FETCH", uid, "(BODY.PEEK[])")
                raw = next((p[1] for p in d or [] if isinstance(p, tuple)), b"")
                msg = email.message_from_bytes(raw, policy=email.policy.default)
                k = key_of(msg); seen_at[(f, uid)] = time.time()
                got.setdefault(k, (f, msg, time.time()))
            c.logout()
        except Exception as e:
            warn.append(f"IMAP: {type(e).__name__}")

    # ---- 6. per mail beoordelen ----
    def recv_time(msg):
        rs = msg.get_all("Received") or []
        if not rs: return None
        try: return email.utils.parsedate_to_datetime(str(rs[0]).rsplit(";", 1)[1].strip()).timestamp()
        except Exception: return None
    def parts(msg):
        types, htmls, texts = set(), [], []
        for p in msg.walk():
            ct = p.get_content_type(); types.add(ct)
            if p.is_multipart() or p.get_content_disposition() == "attachment": continue
            try: body = p.get_content()
            except Exception: continue
            if ct == "text/html": htmls.append(body)
            elif ct == "text/plain": texts.append(body)
        return types, "\n".join(htmls), "\n".join(texts)
    def dom(u):
        try: return (urllib.parse.urlsplit(u).hostname or "").lower()
        except Exception: return ""
    def dname(v):
        n, a = email.utils.parseaddr(str(v or ""))
        n = re.sub(r"[^\w .\-]", "", n)[:30]
        loc, _, d = a.lower().partition("@")
        kind = "support@" if loc == "support" else "noreply@" if re.match(r"^(no-?reply|do-?not-?reply)$", loc) else "ander@"
        return (f"\"{n}\"" if n else "geen naam") + " " + kind, d or "-"
    groups = {}
    def group(k):
        return {"auth": "Auth", "welcome": "Welkom/nieuwsbrief", "newsletter": "Welkom/nieuwsbrief", "status": "Status", "support": "Support",
                "account": "Beheer"}.get(k.split("-")[0], "Overig")
    status_cache = {}
    def check(u):
        if u not in status_cache: status_cache[u] = http_status(u)
        return status_cache[u]
    nodkim = []
    for k in sorted(expect):
        ex = expect[k]
        if k not in got:
            rows.append((k, "nee", "", "", "", "", "", "", "", "", "", ""))
            groups.setdefault(group(k), []).append(f"{k}: NIET aangekomen"); fail.append(f"{k}: niet aangekomen (na {WAIT} s)"); continue
        f, msg, t_seen = got[k]
        rt = recv_time(msg)
        delay = max(0, round((rt or t_seen) - ex["t"])) if (rt or t_seen) else None
        fname, fdom = dname(msg.get("From"))
        rto = msg.get("Reply-To")
        rto_dom = dname(rto)[1] if rto else "-"
        mid = str(msg.get("Message-ID") or "")
        mid_dom = (re.search(r"@([^>\s]+)>?", mid).group(1).lower() if re.search(r"@([^>\s]+)>?", mid) else "-")
        types, html, text = parts(msg)
        multipart = "text/plain" in types and "text/html" in types
        ar = " ".join(str(v) for v in (msg.get_all("Authentication-Results") or [])[:1]).lower()
        auth = {a: b for a, b in re.findall(r"\b(spf|dkim|dmarc)=([a-z]+)", ar)}
        dk = sorted({(m.group(1).lower() if m else "?") for m in (re.search(r"\bd=([^;\s]+)", str(v)) for v in (msg.get_all("DKIM-Signature") or []))})
        lu = str(msg.get("List-Unsubscribe") or "")
        lu_dom = ",".join(sorted({dom(x) for x in re.findall(r"<(https?://[^>]+)>", lu)})) or ("mailto" if "mailto:" in lu else "-")
        lup = bool(msg.get("List-Unsubscribe-Post"))
        m = re.search(r"<html[^>]*\blang=\"([a-zA-Z-]+)\"", html or "")
        lang = (m.group(1).lower()[:2] if m else (str(msg.get("Content-Language") or "")[:2] or "?"))
        hrefs = [htmlmod.unescape(h) for h in re.findall(r"""href=["']([^"']+)["']""", html or "", re.I)]
        turls = re.findall(r"https?://[^\s<>()\"']+", text or "")
        links = []
        for u in hrefs + turls:
            u = u.strip().rstrip(".,;")
            if u.lower().startswith("mailto:"): continue
            if u not in links: links.append(u)
        doms = sorted({dom(u) for u in links if dom(u)})
        bad_doms = [d for d in doms if d not in OWN and d not in OK_EXTERNAL]
        supa = any(d.endswith("supabase.co") for d in doms) or "supabase.co" in (html + text)
        http_bad = []
        for u in links[:40]:
            code_, _ = check(u)
            if not (200 <= code_ < 400): http_bad.append(f"{dom(u)}:{code_}")
        main = next((u for u in links if ex["main"] and re.search(ex["main"], u)), None)
        main_code = check(main)[0] if main else None
        imgs = [htmlmod.unescape(s) for s in re.findall(r"""<img[^>]+src=["']([^"']+)["']""", html or "", re.I)]
        img_ok = sum(1 for s in imgs[:30] if check(s)[0] == 200 and check(s)[1].startswith("image/"))
        spam = bool(re.search(r"spam|junk|ongewenst", f, re.I))
        line = "; ".join([
            f"{k}: ja{' (SPAMMAP)' if spam else ''} na {delay}s", f"From {fname} @{fdom}", f"Reply-To {'ja @' + rto_dom if rto else 'nee'}",
            f"MsgID {'ja @' + mid_dom if mid else 'NEE'}", f"Date {'ja' if msg.get('Date') else 'NEE'}", f"text+html {'ja' if multipart else 'NEE ' + ','.join(sorted(types))}",
            f"AR spf={auth.get('spf', '-')} dkim={auth.get('dkim', '-')} dmarc={auth.get('dmarc', '-')}", f"DKIM-Sig {','.join(dk) or 'geen'}",
            f"List-Unsub {('ja ' + lu_dom + (' 1-klik' if lup else '')) if lu else 'nee'}", f"taal {lang}/{ex['lang']}",
            f"links {len(links)} [{','.join(doms) or '-'}] supabase.co {'JA' if supa else 'nee'} fout {','.join(http_bad[:4]) or '0'}",
            f"hoofdlink {('HTTP ' + str(main_code)) if main else ('GEEN' if ex['main'] else 'n.v.t.')}", f"img {img_ok}/{len(imgs)}" if imgs else "img geen",
        ])
        groups.setdefault(group(k), []).append(line)
        rows.append((k, "ja" + (" (spam)" if spam else ""), str(delay), f"{fname} @{fdom}", "ja" if rto else "nee", "ja" if mid and msg.get("Date") else "NEE",
                     "ja" if multipart else "NEE", f"{auth.get('spf', '-')}/{auth.get('dkim', '-')}/{auth.get('dmarc', '-')}", ",".join(dk) or "geen",
                     ("ja" if lu else "nee") + (" (1-klik)" if lup else ""), f"{lang}/{ex['lang']}",
                     f"{len(links)}, {'supabase.co!' if supa else 'ok'}, fout {len(http_bad)}, hoofd {main_code if main else '-'}, img {img_ok}/{len(imgs)}"))
        if spam: fail.append(f"{k}: in de spammap")
        if not mid: fail.append(f"{k}: geen Message-ID")
        if not msg.get("Date"): fail.append(f"{k}: geen Date")
        if not multipart: fail.append(f"{k}: geen text+html")
        if fdom != "bingr.online": fail.append(f"{k}: afzender niet @bingr.online")
        if ex["unsub"] and not lu: fail.append(f"{k}: List-Unsubscribe ontbreekt")
        if lang != ex["lang"]: fail.append(f"{k}: taal {lang}, verwacht {ex['lang']}")
        if supa: fail.append(f"{k}: link naar supabase.co in de mail")
        if bad_doms: warn.append(f"{k}: links naar andere domeinen: {','.join(bad_doms)}")
        if http_bad: fail.append(f"{k}: links met HTTP-fout: {','.join(http_bad[:6])}")
        if ex["main"] and not main: fail.append(f"{k}: hoofdlink niet gevonden")
        if main and not (200 <= (main_code or 0) < 400): fail.append(f"{k}: hoofdlink HTTP {main_code}")
        if imgs and img_ok < len(imgs[:30]): fail.append(f"{k}: afbeeldingen laden niet ({img_ok}/{len(imgs)})")
        if not dk: nodkim.append(k)
        elif auth.get("dkim") not in (None, "pass"): warn.append(f"{k}: DKIM {auth.get('dkim')}")
        if auth.get("spf") not in (None, "pass"): warn.append(f"{k}: SPF {auth.get('spf')}")
        if auth.get("dmarc") not in (None, "pass"): warn.append(f"{k}: DMARC {auth.get('dmarc')}")
    for g, lines in groups.items(): note(f"mails {g}", "\n".join(lines))
    if nodkim: warn.append(f"geen DKIM-Signature bij {len(nodkim)}/{len(got)} mails (aflevering op dezelfde server tekent vaak niet; zie de externe DKIM-controle)")
    # rapport van Port25 in de mailbox van de afzender
    if ext_t:
        res = None
        end = time.time() + 180
        while time.time() < end and res is None:
            try:
                c = imaplib.IMAP4_SSL(E["I_HOST"].strip(), int((E.get("I_PORT") or "993").strip() or 993), ssl_context=ssl.create_default_context(), timeout=60)
                c.login(E["S_USER"].strip(), E["S_PASS"])
                for f in folders(c):
                    try:
                        if c.select(f)[0] != "OK": continue
                        typ, d = c.uid("SEARCH", None, "FROM", '"port25"')
                        for uid in (d[0].split() if typ == "OK" and d and d[0] else []):
                            typ, dd = c.uid("FETCH", uid, "(BODY.PEEK[])")
                            raw = next((p_[1] for p_ in dd or [] if isinstance(p_, tuple)), b"")
                            body = raw.decode("utf-8", "replace")
                            if tag not in body: continue
                            res = {a.lower(): b.lower() for a, b in re.findall(r"^(SPF|DKIM|DMARC|iprev) check:\s+(\w+)", body, re.M)}
                            dkd = re.findall(r"\bd=([a-z0-9.-]+)", body.split("DKIM check details", 1)[-1][:4000])
                            res["dkim_d"] = (dkd[0] if dkd else "-")
                            c.uid("STORE", uid, "+FLAGS.SILENT", r"(\Deleted)"); c.expunge()
                    except Exception: continue
                    if res is not None: break
                c.logout()
            except Exception as e:
                warn.append(f"externe controle IMAP: {type(e).__name__}"); break
            if res is None: time.sleep(15)
        if res is None:
            note("externe SPF/DKIM/DMARC (Port25)", "geen rapport binnen 3 min (verifier niet bereikbaar of rapport elders)")
        else:
            dkd = res.get("dkim_d", "-"); dkd = dkd if dkd in ("bingr.online", "-") else "<ander>"
            note("externe SPF/DKIM/DMARC (Port25)", f"SPF {res.get('spf', '-')} | DKIM {res.get('dkim', '-')} (d={dkd}) | DMARC {res.get('dmarc', '-')} | iprev {res.get('iprev', '-')}")
            for a in ("spf", "dkim", "dmarc"):
                if res.get(a) and res[a] != "pass": fail.append(f"extern: {a.upper()} {res[a]}")
            if nodkim and res.get("dkim") == "pass":
                warn[:] = [w for w in warn if not w.startswith("geen DKIM-Signature bij")]
                note("DKIM", f"intern {len(nodkim)} mails zonder handtekening (aflevering op dezelfde server); extern DKIM pass")
    extra = sorted(set(got) - set(expect))
    if extra: note("alle_mails extra", "ook binnen (niet verwacht): " + ",".join(re.sub(r"[^\w-]", "", x)[:40] for x in extra))
finally:
    # ---- 7. opruimen ----
    try:
        c = imaplib.IMAP4_SSL(E["I_HOST"].strip(), int((E.get("I_PORT") or "993").strip() or 993), ssl_context=ssl.create_default_context(), timeout=60)
        c.login(E["I_USER"].strip(), E["I_PASS"]); n = 0
        typ, data = c.list()
        for line in data or []:
            s = line.decode("utf-8", "replace") if isinstance(line, bytes) else str(line)
            if re.search(r"\\Noselect|\\NonExistent", s, re.I): continue
            mm = re.search(r'\) (?:"[^"]*"|NIL) (.+)$', s)
            if not mm: continue
            f = mm.group(1).strip()
            try:
                if c.select(f)[0] != "OK": continue
                uids = set()
                typ, d = c.uid("SEARCH", None, "TO", f'"{tag}"')
                if typ == "OK" and d and d[0]: uids.update(d[0].split())
                if ticket:
                    typ, d = c.uid("SEARCH", None, "HEADER", "X-Bingr-Ticket", str(ticket["n"]))
                    if typ == "OK" and d and d[0]: uids.update(d[0].split())
                for uid in uids: c.uid("STORE", uid, "+FLAGS.SILENT", r"(\Deleted)"); n += 1
                if uids: c.expunge()
            except Exception: continue
        c.logout(); note("alle_mails opruimen", f"testmails verwijderd: {n}")
    except Exception as e:
        warn.append(f"testmails niet verwijderd: {type(e).__name__}")
    if not uid_user and skey:
        code, r = sql(f"select id::text from auth.users where lower(email) = lower({lit(A)})")
        if code < 300 and isinstance(r, list) and r: uid_user = r[0].get("id"); mask(uid_user)
    if uid_user and skey:
        code, _ = req("DELETE", f"{BASE}/auth/v1/admin/users/{uid_user}", None, adm)
        if code not in (200, 204, 404): warn.append(f"testaccount niet verwijderd (HTTP {code})")
    if t0_db and signup_ok:
        sql(f"delete from public.signup_attempts where id = (select max(id) from public.signup_attempts where allowed and at >= {lit(t0_db)}::timestamptz)")
    cleanup = [
        "delete from public.support_tickets where email like 'support+ci-%@bingr.online'",
        "delete from public.status_subscribers where email like 'support+ci-%@bingr.online'",
        "delete from public.app_settings where key = 'mailtest'",
    ]
    if t0_db:
        tn_sql = f" or ticket_number = {ticket['n']}" if ticket else ""
        cleanup.append(f"delete from public.support_inbox_log where at >= {lit(t0_db)}::timestamptz and (coalesce(subject, '') like {lit('%' + tag + '%')} "
                       f"or lower(coalesce(sender, '')) like 'support+ci-%'{tn_sql})")
    for q in cleanup:
        code, _ = sql(q)
        if code >= 300: warn.append(f"opruimen mislukt (HTTP {code}): {q.split(' where')[0][:60]}")
    code, r = sql("select (select count(*) from auth.users where email like 'support+ci-%@bingr.online')::int a, "
                  "(select count(*) from public.support_tickets where email like 'support+ci-%@bingr.online')::int t, "
                  "(select count(*) from public.app_settings where key = 'mailtest')::int k")
    note("alle_mails opruimen", f"over na opruimen: {json.dumps(r[0]) if code < 300 and isinstance(r, list) and r else 'onbekend'}")

if rows and E.get("GITHUB_STEP_SUMMARY"):
    hdr = ["mail", "aangekomen", "vertraging (s)", "From", "Reply-To", "Message-ID+Date", "text+html", "spf/dkim/dmarc", "DKIM d=", "List-Unsubscribe", "taal", "links"]
    with open(E["GITHUB_STEP_SUMMARY"], "a") as fh:
        fh.write("## Alle Bingr-mails (end-to-end)\n\n| " + " | ".join(hdr) + " |\n|" + "---|" * len(hdr) + "\n")
        for r_ in rows: fh.write("| " + " | ".join(str(x) for x in r_) + " |\n")
def esc_ann(s): return s.replace("%", "%25").replace("\r", "").replace("\n", "%0A")
if warn: print("::warning title=alle_mails waarschuwingen::" + esc_ann("\n".join(w[:300] for w in warn))[:3800])
if fail: print("::error title=alle_mails fouten::" + esc_ann("\n".join(f[:300] for f in fail))[:3800])
if not fail: print(f"::notice title=alle_mails::alle {len(expect)} mails komen aan en zijn in orde")
sys.exit(1 if fail else 0)
