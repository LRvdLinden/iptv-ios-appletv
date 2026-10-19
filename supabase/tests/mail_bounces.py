# Bounces (DSN's) in de mailbox van de afzender (BINGR_SMTP_USER, IMAP met dezelfde login) van de laatste uren: per
# bounce alleen de status, een opgeschoonde foutmelding, het domein van de ontvanger als het een grote provider is en of
# het een bevestigingsmail was. Het log is OPENBAAR: geen adressen, IP's of hostnamen. Leest alleen (BODY.PEEK).
# Env: I_HOST, I_PORT (IMAP-server), S_USER, S_PASS, HOURS (standaard 24).
import collections, datetime, email, email.policy, email.utils, imaplib, json, os, re, ssl, sys

E = os.environ
for k in ("S_USER", "S_PASS", "I_HOST"):
    if E.get(k): print(f"::add-mask::{E[k]}")
if not (E.get("I_HOST") and E.get("S_USER") and E.get("S_PASS")): print("::warning::bounces: gegevens ontbreken"); sys.exit(0)
HOURS = int(E.get("HOURS") or 24)
BIG = {"gmail.com", "googlemail.com", "hotmail.com", "outlook.com", "live.com", "live.nl", "hotmail.nl", "outlook.nl", "msn.com",
       "icloud.com", "me.com", "mac.com", "yahoo.com", "ziggo.nl", "kpnmail.nl", "planet.nl", "home.nl", "xs4all.nl", "telenet.be", "proton.me", "protonmail.com", "gmx.net", "gmx.de", "web.de"}

def scrub(s):
    s = re.sub(r"[^\s\"'<>;()]+@[^\s\"'<>;()]+", "<e>", str(s)); s = re.sub(r"\b\d{1,3}(\.\d{1,3}){3}\b", "<ip>", s)
    s = re.sub(r"\[[0-9a-f:.]+\]", "[<ip>]", s, flags=re.I)
    s = re.sub(r"\b(?:[a-z0-9-]+\.)+[a-z]{2,}\b", lambda m: m.group(0) if m.group(0).lower() in BIG or m.group(0).lower().endswith(("google.com", "outlook.com", "bingr.online")) else "<host>", s, flags=re.I)
    s = re.sub(r"https?://\S+", "<url>", s)
    return re.sub(r"\s+", " ", s).strip()[:220]

def note(t, m): print(f"::notice title={t}::{str(m)[:3000]}")
try:
    c = imaplib.IMAP4_SSL(E["I_HOST"].strip(), int((E.get("I_PORT") or "993").strip() or 993), ssl_context=ssl.create_default_context(), timeout=30)
    c.login(E["S_USER"].strip(), E["S_PASS"])
except Exception as e:
    note("bounces", f"IMAP-login met de SMTP-gegevens niet gelukt: {type(e).__name__}"); sys.exit(0)
since = (datetime.datetime.utcnow() - datetime.timedelta(hours=HOURS)).strftime("%d-%b-%Y")
typ, data = c.list(); names = []
for line in data or []:
    s = line.decode("utf-8", "replace") if isinstance(line, bytes) else str(line)
    if re.search(r"\\Noselect", s, re.I): continue
    m = re.search(r'\) (?:"[^"]*"|NIL) (.+)$', s)
    if m: names.append(m.group(1).strip())
cutoff = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=HOURS)
per = collections.Counter(); totals = collections.Counter(); last = []
for f in names:
    try:
        if c.select(f, readonly=True)[0] != "OK": continue
        typ, d = c.uid("SEARCH", None, "SINCE", since)
    except Exception: continue
    uids = d[0].split() if typ == "OK" and d and d[0] else []
    totals["mails"] += len(uids)
    for uid in uids[-200:]:
        typ, dd = c.uid("FETCH", uid, "(BODY.PEEK[])")
        raw = next((p[1] for p in dd or [] if isinstance(p, tuple)), b"")
        msg = email.message_from_bytes(raw, policy=email.policy.default)
        try:
            dt = email.utils.parsedate_to_datetime(str(msg.get("Date")))
            if dt and dt.tzinfo and dt < cutoff: continue
        except Exception: dt = None
        frm = str(msg.get("From", "")).lower(); ctype = msg.get_content_type()
        if not (ctype == "multipart/report" or re.search(r"mailer-daemon|postmaster", frm) or re.search(r"undeliver|delivery status|returned mail|failure|niet bezorgd|onbestelbaar", str(msg.get("Subject", "")), re.I)):
            continue
        totals["bounces"] += 1
        text = raw.decode("utf-8", "replace")
        rcpt = re.search(r"Final-Recipient:\s*rfc822;\s*\S+@([^\s>]+)", text, re.I)
        dom = rcpt.group(1).lower().rstrip(".") if rcpt else "?"
        dom = dom if dom in BIG or dom == "bingr.online" else "<ander domein>"
        st = re.search(r"^Status:\s*([0-9.]+)", text, re.I | re.M)
        diag = re.search(r"Diagnostic-Code:\s*(?:smtp;)?\s*(.+(?:\n[ \t].+)*)", text, re.I)
        if not diag: diag = re.search(r"((?:5|4)\d\d[ -][0-9.]+ .{0,200})", text)
        conf = "ja" if re.search(r"Bevestig je e-mailadres|Confirm your email", text, re.I) else "nee"
        key = f"{dom} | status {st.group(1) if st else '?'} | bevestigingsmail: {conf} | {scrub(diag.group(1)) if diag else scrub(msg.get('Subject', ''))}"
        per[key] += 1
        last.append(f"{dt:%H:%M} UTC {dom} {st.group(1) if st else '?'} bevestiging={conf}" if dt else f"? {dom}")
c.logout()
note("bounces afzender", f"{HOURS} uur: {totals['mails']} mails in de mailbox van de afzender, waarvan {totals['bounces']} bounces")
note("bounces per soort", json.dumps(dict(per.most_common(10)), ensure_ascii=False) if per else "geen")
note("bounces laatste", "; ".join(last[-12:]) or "geen")
