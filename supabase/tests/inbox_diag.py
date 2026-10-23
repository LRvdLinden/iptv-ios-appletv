# Diagnose van de support-inbox (workflow Diagnose, invoer "inbox"). Alleen-lezen (EXAMINE, BODY.PEEK): verandert niets aan
# de mailbox of de database. Het log is OPENBAAR: alleen tellingen, leeftijden en foutsoorten; nooit adressen, namen,
# onderwerpen, mapnamen van gebruikers of inhoud.
#   1. database: stand van de import (support_inbox_state), logboek per resultaat (30 dagen), pg_cron-runs (24 uur)
#   2. IMAP: per soort map het aantal berichten en ongelezen; in INBOX per bericht een indeling op kopregels
#      (eigen systeem, automatisch, testadres, met ticketverwijzing, al geïmporteerd op Message-ID, UID boven last_uid, ...)
import collections, datetime, email, email.policy, email.utils, imaplib, json, os, re, ssl, sys, urllib.request

E = os.environ
REF = E["REF"]


def sql(q):
    r = urllib.request.Request(f"https://api.supabase.com/v1/projects/{REF}/database/query", data=json.dumps({"query": q}).encode(),
                               headers={"Authorization": f"Bearer {E['SUPABASE_ACCESS_TOKEN']}", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(r, timeout=60) as resp: return resp.status, json.loads(resp.read() or b"null")
    except urllib.error.HTTPError as e: return e.code, None
    except Exception: return 0, None


def note(title, msg): print(f"::notice title={title}::{str(msg)[:1800]}")


def lit(s): return "'" + s.replace("'", "''") + "'"


# ---- 1. database ----
code, st = sql("select uidvalidity, last_uid, scan_until, scan_cursor, last_poll_at::text, last_ok_at::text, last_import_at::text, "
               "(last_error is not null) as has_error, last_error_at::text, last_result, last_source, error_uid, error_count "
               "from public.support_inbox_state where id = 1")
state = st[0] if isinstance(st, list) and st else {}
note("inbox-stand", ", ".join(f"{k}={state.get(k)}" for k in ("uidvalidity", "last_uid", "scan_until", "scan_cursor", "last_poll_at", "last_ok_at", "last_import_at", "has_error", "last_source", "error_uid", "error_count")) or f"HTTP {code}")
note("inbox-laatste-ronde", json.dumps(state.get("last_result")))
code, lg = sql("select split_part(result, ':', 1) || coalesce(':' || nullif(split_part(result, ':', 2), ''), '') r, count(*)::int n, max(at)::text last "
               "from public.support_inbox_log where at > now() - interval '30 days' group by 1 order by 2 desc")
note("inbox-logboek-30d", "; ".join(f"{x['r']}={x['n']} (laatst {x['last'][:16]})" for x in lg) if isinstance(lg, list) and lg else f"leeg (HTTP {code})")
code, cr = sql("select j.jobname, j.schedule, j.active, (select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.start_time > now() - interval '24 hours')::int runs, "
               "(select count(*) from cron.job_run_details d where d.jobid = j.jobid and d.start_time > now() - interval '24 hours' and d.status <> 'succeeded')::int failed, "
               "(select max(start_time)::text from cron.job_run_details d where d.jobid = j.jobid) last "
               "from cron.job j where j.jobname like 'bingr-support%'")
note("inbox-planning", "; ".join(f"{x['jobname']} {x['schedule']} actief={x['active']} runs24u={x['runs']} mislukt={x['failed']} laatst={str(x['last'])[:16]}" for x in cr) if isinstance(cr, list) and cr else f"geen taken (HTTP {code})")
code, tk = sql("select count(*) filter (where created_at > now() - interval '30 days')::int t30, "
               "(select count(*) from public.support_messages m where m.source = 'email' and m.created_at > now() - interval '30 days')::int mail30, "
               "(select count(*) from public.support_messages m where m.source = 'email')::int mail_all from public.support_tickets")
note("tickets", json.dumps(tk[0] if isinstance(tk, list) and tk else code))

# ---- 2. IMAP ----
host, user, pw = (E.get("I_HOST") or "").strip(), (E.get("I_USER") or "").strip(), E.get("I_PASS") or ""
if not (host and user and pw):
    note("imap", "BINGR_IMAP_* ontbreken"); sys.exit(0)
c = imaplib.IMAP4_SSL(host, int((E.get("I_PORT") or "993").strip() or 993), ssl_context=ssl.create_default_context(), timeout=60)
c.login(user, pw)
own = {a.strip().lower() for a in [user, E.get("SUP_EMAIL") or "support@bingr.online", "support@bingr.online"] if a}
agents = {a.strip().lower() for a in re.split(r"[\s,;]+", E.get("AGENTS") or "") if "@" in a}

typ, boxes = c.list()
kinds = collections.Counter()
rows = []
for b in boxes or []:
    s = b.decode(errors="replace")
    if re.search(r"\\Noselect|\\NonExistent", s, re.I): continue
    m = re.search(r'\(([^)]*)\) (?:"([^"]*)"|NIL) (.+)$', s)
    if not m: continue
    flags, delim, name = m.group(1), m.group(2) or ".", m.group(3).strip().strip('"')
    leaf = name.split(delim)[-1].lower() if delim else name.lower()
    if name.upper() == "INBOX": kind = "INBOX"
    elif leaf == "bingr-verwerkt": kind = "Bingr-verwerkt"
    elif re.search(r"\\Junk", flags, re.I) or re.search(r"spam|junk|ongewenst", leaf): kind = "spam"
    elif re.search(r"\\Sent", flags, re.I) or re.search(r"^sent|verzonden", leaf): kind = "verzonden"
    elif re.search(r"\\Trash", flags, re.I) or re.search(r"trash|prullenbak|deleted|verwijderd", leaf): kind = "prullenbak"
    elif re.search(r"\\Drafts", flags, re.I) or re.search(r"draft|concept", leaf): kind = "concepten"
    elif re.search(r"\\Archive", flags, re.I) or re.search(r"archi", leaf): kind = "archief"
    elif leaf.startswith("ci-") or leaf == "tag": kind = "plusmap-ci"
    elif name.upper().startswith("INBOX" + delim.upper()): kind = "submap-INBOX"
    else: kind = "overig"
    t, d = c.status(f'"{name}"', "(MESSAGES UNSEEN)")
    mm = re.search(rb"MESSAGES (\d+).*UNSEEN (\d+)", d[0] if d and d[0] else b"") if t == "OK" else None
    n, u = (int(mm.group(1)), int(mm.group(2))) if mm else (None, None)
    kinds[kind] += 1
    rows.append((kind, n, u))
agg = collections.defaultdict(lambda: [0, 0, 0])
for k, n, u in rows:
    agg[k][0] += 1; agg[k][1] += n or 0; agg[k][2] += u or 0
note("imap-mappen", "; ".join(f"{k}: {v[0]} map(pen), {v[1]} berichten, {v[2]} ongelezen" for k, v in sorted(agg.items())))

AUTO_SUBJ = re.compile(r"^(automatisch antwoord|automatic reply|auto(matic)?[- ]?reply|autoreply|auto:|out of (the )?office|afwezig|undeliverable|onbestelbaar|delivery status notification|mail delivery|returned mail|failure notice|undelivered mail)", re.I)
AUTO_FROM = re.compile(r"^(mailer-daemon|postmaster|no-?reply|do-?not-?reply|donotreply|noreply-[^@]*|bounces?(\+[^@]*)?|mail-?daemon)@", re.I)


def classify(msg):
    h = lambda k: str(msg.get(k) or "")
    frm = (email.utils.parseaddr(h("From"))[1] or "").lower()
    to_all = " ".join(h(k) for k in ("To", "Delivered-To", "X-Original-To", "Cc")).lower()
    if h("X-Bingr-Ticket"): return "eigen_systeem"
    if re.search(r"support\+ci-", to_all) or re.search(r"support\+ci-", frm): return "testadres_ci"
    asub = h("Auto-Submitted").strip().lower()
    if asub and asub != "no": return "auto_submitted"
    if h("Precedence").strip().lower() in ("bulk", "junk", "list", "auto_reply"): return "precedence_bulk"
    if h("X-Autoreply") or h("X-Autorespond") or h("X-Autogenerated") or h("X-Auto-Response").lower() == "yes": return "autoreply_kop"
    if msg.get_content_type() == "multipart/report" or re.match(r"^<\s*>$", h("Return-Path").strip()): return "bounce"
    if not frm or "@" not in frm: return "geen_afzender"
    if AUTO_FROM.search(frm): return "noreply_afzender"
    if AUTO_SUBJ.search(re.sub(r"^\s*(re|fw|fwd|aw|wg|antw)\s*:\s*", "", h("Subject"), flags=re.I)): return "auto_onderwerp"
    if h("List-Id") or h("List-Unsubscribe"): return "lijst_nieuwsbrief"
    if re.match(r"^yes", h("X-Spam-Flag"), re.I) or re.match(r"^yes", h("X-Spam-Status"), re.I): return "spam_kop"
    if frm in own or frm in agents: return "van_support_zelf"
    return "klant"


def scan(box, last_uid=None):
    t, _ = c.select(f'"{box}"', readonly=True)
    if t != "OK": return None
    t, d = c.uid("SEARCH", None, "ALL")
    uids = [int(x) for x in (d[0] or b"").split()] if t == "OK" else []
    res = collections.Counter(); mids = {}; ages = collections.Counter(); refs = collections.Counter()
    now = datetime.datetime.now(datetime.timezone.utc)
    for i in range(0, len(uids), 100):
        part = uids[i:i + 100]
        t, d = c.uid("FETCH", ",".join(map(str, part)), "(UID FLAGS INTERNALDATE BODY.PEEK[HEADER])")
        for item in d or []:
            if not isinstance(item, tuple): continue
            meta = item[0].decode(errors="replace")
            uid = int(re.search(r"UID (\d+)", meta).group(1))
            seen = "\\Seen" in meta
            msg = email.message_from_bytes(item[1], policy=email.policy.compat32)
            cls = classify(msg)
            res[cls] += 1
            res["ongelezen" if not seen else "gelezen"] += 1
            if last_uid is not None: res["uid>last_uid" if uid > last_uid else "uid<=last_uid"] += 1
            subj = str(msg.get("Subject") or "")
            if re.search(r"\[#\d+\]", subj) or re.search(r"bingr-ticket-\d+", str(msg.get("In-Reply-To") or "") + str(msg.get("References") or "")): refs["met_ticketverwijzing"] += 1
            mid = str(msg.get("Message-ID") or "").strip()
            if cls == "klant": mids[uid] = (mid, seen, uid > (last_uid or 0))
            dm = re.search(r'INTERNALDATE "([^"]+)"', meta)
            if dm:
                try:
                    age = (now - datetime.datetime.strptime(dm.group(1), "%d-%b-%Y %H:%M:%S %z")).days
                    ages["<1d" if age < 1 else "<7d" if age < 7 else "<30d" if age < 30 else ">=30d"] += 1
                except Exception: pass
    return len(uids), res, mids, ages, refs


last_uid = state.get("last_uid")
r = scan("INBOX", int(last_uid) if last_uid is not None else None)
if r:
    n, res, mids, ages, refs = r
    note("inbox-indeling", f"{n} berichten in INBOX; " + ", ".join(f"{k}={v}" for k, v in res.most_common()) + "; " + ", ".join(f"{k}={v}" for k, v in refs.items()))
    note("inbox-leeftijd", ", ".join(f"{k}={v}" for k, v in sorted(ages.items())))
    # klantmails: al geïmporteerd (Message-ID in support_messages)?
    ids = [m for m, _, _ in mids.values() if m]
    known = set()
    for i in range(0, len(ids), 200):
        q = ",".join(lit(x[:300]) for x in ids[i:i + 200])
        code, rr = sql(f"select message_id from public.support_messages where message_id in ({q})")
        if isinstance(rr, list): known |= {x["message_id"] for x in rr}
    imp = collections.Counter()
    for mid, seen, above in mids.values():
        k = "al_geimporteerd" if mid and mid[:300] in known else "nooit_geimporteerd"
        imp[k] += 1
        if k == "nooit_geimporteerd": imp[f"nooit_{'ongelezen' if not seen else 'gelezen'}_{'boven' if above else 'onder'}_last_uid"] += 1
        if not mid: imp["zonder_message_id"] += 1
    note("inbox-klantmails", ", ".join(f"{k}={v}" for k, v in imp.most_common()) or "geen klantmails in INBOX")
for kind in ("spam", "Bingr-verwerkt"):
    for b in boxes or []:
        s = b.decode(errors="replace")
        m = re.search(r'\(([^)]*)\) (?:"([^"]*)"|NIL) (.+)$', s)
        if not m: continue
        name = m.group(3).strip().strip('"'); flags = m.group(1); leaf = name.split(m.group(2) or ".")[-1].lower()
        hit = (kind == "spam" and (re.search(r"\\Junk", flags, re.I) or re.search(r"spam|junk|ongewenst", leaf))) or (kind != "spam" and leaf == "bingr-verwerkt")
        if not hit: continue
        r = scan(name)
        if r: note(f"map-{kind}", f"{r[0]} berichten; " + ", ".join(f"{k}={v}" for k, v in r[1].most_common()) + "; " + ", ".join(f"{k}={v}" for k, v in sorted(r[3].items())))
c.logout()
