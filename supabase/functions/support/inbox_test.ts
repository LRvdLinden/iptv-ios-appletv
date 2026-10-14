// Tests voor de inbox-import (geen database, geen SMTP; de IMAP-client tegen een nep-server op localhost):
//   deno test --allow-net=127.0.0.1 supabase/functions/support/inbox_test.ts
import { decodeWords, htmlToText, parseAddresses, parseMessage, parseParams, REPLY_MARKER, stripReply } from "./mime.ts";
import {
  agentList, authFailed, authservNames, automatedReason, candidateNumbers, cleanSubject, decide, dkimPassDomains, findFolder, guessLang, imapDate, messageBody,
  numberFromSubject, numbersFromIds, senderVerified, type TicketLite,
} from "./inbox.ts";
import { Imap, type ImapConn, tokenize } from "./imap.ts";
import { renderMail } from "./templates.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }
const crlf = (s: string) => s.replace(/\r?\n/g, "\r\n");

// ---- kopregels ----
Deno.test("encoded-words: B en Q, utf-8 en latin-1, aangrenzend zonder spatie", () => {
  eq(decodeWords("=?utf-8?B?SGFsbG8gTMOpb24=?="), "Hallo Léon");
  eq(decodeWords("=?ISO-8859-1?Q?Caf=E9_au_lait?="), "Café au lait");
  eq(decodeWords("Re: =?utf-8?Q?Stream_hapert_?= =?utf-8?Q?=E2=82=AC5?= ok"), "Re: Stream hapert €5 ok");
  // één utf-8-teken over twee woorden verdeeld
  eq(decodeWords("=?utf-8?B?w6k=?= =?utf-8?B?w6k=?="), "éé");
  eq(decodeWords("=?utf-8?Q?a?=  b =?utf-8?Q?c?="), "a  b c");
  eq(decodeWords("=?windows-1252?Q?=93hoi=94?="), "“hoi”");
  eq(decodeWords("geen =?onzin"), "geen =?onzin");
});

Deno.test("adressen en parameters (RFC 2231)", () => {
  eq(parseAddresses('"Linden, Léon" <Leon@Example.COM>, kees@x.nl (Kees)'), [
    { name: "Linden, Léon", address: "leon@example.com" }, { name: "Kees", address: "kees@x.nl" },
  ]);
  eq(parseAddresses("<a@b.nl>"), [{ name: "", address: "a@b.nl" }]);
  eq(parseParams('attachment; filename*=UTF-8\'\'na%C3%AFve%20file.pdf').params.filename, "naïve file.pdf");
  eq(parseParams('attachment; filename*0*=utf-8\'\'d%C3%A9el; filename*1="2.txt"').params.filename, "déel2.txt");
  eq(parseParams('text/plain; charset="ISO-8859-1"; format=flowed').params, { charset: "ISO-8859-1", format: "flowed" });
  eq(parseParams('multipart/mixed; boundary="a;b"').params.boundary, "a;b");
});

// ---- MIME ----
const GMAIL_REPLY = crlf(`Return-Path: <klant@example.com>
Authentication-Results: mx.hoster.nl; dkim=pass header.d=example.com; spf=pass smtp.mailfrom=example.com; dmarc=pass
From: =?UTF-8?Q?L=C3=A9on_Klant?= <Klant@Example.com>
To: Bingr Support <support@bingr.online>
Subject: Re: [#1007] Nieuw antwoord: Stream hapert
Message-ID: <CAF=abc123@mail.gmail.com>
In-Reply-To: <bingr-ticket-1007.Xy12@bingr.online>
References: <bingr-ticket-1007@bingr.online> <bingr-ticket-1007.Xy12@bingr.online>
Date: Tue, 14 Oct 2026 10:00:00 +0200
MIME-Version: 1.0
Content-Type: multipart/alternative; boundary="000000000000abc"

--000000000000abc
Content-Type: text/plain; charset="UTF-8"
Content-Transfer-Encoding: quoted-printable

Het werkt nu, dank je! Caf=C3=A9 =E2=82=AC 5.
Lange regel die doorloopt =
op de volgende regel.

Op di 14 okt 2026 om 09:00 schreef Bingr Support <
support@bingr.online>:

> -- Antwoord boven deze lijn / Reply above this line --
>
> BINGR Support
> Probeer VLC.

--000000000000abc
Content-Type: text/html; charset="UTF-8"

<div dir="ltr">Het werkt nu, dank je!</div><div class="gmail_quote">citaat</div>
--000000000000abc--
`);

Deno.test("Gmail-antwoord: kopregels, quoted-printable, citaat weg", () => {
  const m = parseMessage(GMAIL_REPLY);
  eq(m.from, { name: "Léon Klant", address: "klant@example.com" });
  eq(m.subject, "Re: [#1007] Nieuw antwoord: Stream hapert");
  eq(m.messageId, "<CAF=abc123@mail.gmail.com>");
  eq(m.inReplyTo, ["<bingr-ticket-1007.Xy12@bingr.online>"]);
  eq(m.references.length, 2);
  ok(!m.fromHtml, "text/plain gekozen");
  eq(stripReply(m.text), "Het werkt nu, dank je! Café € 5.\nLange regel die doorloopt op de volgende regel.");
  eq(candidateNumbers(m), [1007]);
  ok(!authFailed(m), "auth ok");
  eq(automatedReason(m), null);
});

Deno.test("alleen HTML (Outlook), base64 en windows-1252, bijlagen", () => {
  const html = `<html><head><style>p{color:red}</style></head><body><p>Hallo,</p><p>Mijn &quot;stream&quot; hapert&nbsp;nog steeds.<br>Zie <a href="https://x.nl/a">https://x.nl/a</a> en <a href="https://y.nl/">deze link</a>.</p>
<div id="appendonsend"></div><hr><div id="divRplyFwdMsg"><b>Van:</b> Bingr Support</div><div>oud bericht</div></body></html>`;
  const b64 = btoa(html).replace(/(.{76})/g, "$1\r\n");
  const raw = crlf(`From: Kees <kees@x.nl>
Subject: =?windows-1252?Q?Probleem_met_=93Bingr=94?=
Message-ID: <abc@x.nl>
Content-Type: multipart/mixed; boundary=XYZ

--XYZ
Content-Type: text/html; charset=windows-1252
Content-Transfer-Encoding: base64

${b64}
--XYZ
Content-Type: application/pdf; name="factuur.pdf"
Content-Disposition: attachment; filename="factuur.pdf"
Content-Transfer-Encoding: base64

JVBERi0xLjQK
--XYZ
Content-Type: image/png
Content-ID: <logo@x>
Content-Disposition: inline

iVBORw0K
--XYZ--
`);
  const m = parseMessage(raw);
  eq(m.subject, "Probleem met “Bingr”");
  ok(m.fromHtml, "uit html");
  eq(stripReply(m.text), 'Hallo,\n\nMijn "stream" hapert nog steeds.\nZie https://x.nl/a en deze link (https://y.nl/).');
  eq(m.attachments.map((a) => a.filename), ["factuur.pdf"]);
  eq(messageBody(m, "nl"), 'Hallo,\n\nMijn "stream" hapert nog steeds.\nZie https://x.nl/a en deze link (https://y.nl/).\n\n(bijlage niet overgenomen: factuur.pdf)');
});

Deno.test("latin-1 zonder multipart, 8-bit kopregels, afgekapt bericht", () => {
  const head = "From: Jos <jos@x.nl>\r\nSubject: Café\r\nContent-Type: text/plain; charset=iso-8859-1\r\nContent-Transfer-Encoding: 8bit\r\n\r\n";
  const bytes = new Uint8Array([...new TextEncoder().encode(head.replace("Café", "Café")), ...[0x48, 0xe9, 0x20, 0x64, 0x61, 0x61, 0x72]]);
  const m = parseMessage(bytes);
  eq(m.subject, "Café");
  eq(m.text, "Hé daar");
  const cut = parseMessage(crlf(`From: a@b.nl\nContent-Type: multipart/mixed; boundary=Q\n\n--Q\nContent-Type: text/plain\n\nbegin\n--Q\nContent-Type: application/zip; name=x.zip\n\nAAAA`));
  ok(cut.truncated, "niet afgesloten multipart = afgekapt");
  eq(cut.text, "begin");
  eq(cut.attachments[0].filename, "x.zip");
});

Deno.test("format=flowed en geneste multipart (Apple Mail)", () => {
  const raw = crlf(`From: Anna <anna@icloud.com>
Subject: Vraag
Content-Type: multipart/mixed; boundary=A

--A
Content-Type: multipart/alternative; boundary=B

--B
Content-Type: text/plain; charset=utf-8; format=flowed

Dit is een lange zin die door Apple Mail is =
--B
Content-Type: text/html; charset=utf-8

<p>html</p>
--B--
--A
Content-Type: text/plain; name=log.txt
Content-Disposition: attachment; filename=log.txt

regels
--A--
`).replace("is =\r\n", "is \r\nafgebroken.\r\n\r\nVerstuurd vanaf mijn iPhone\r\n");
  const m = parseMessage(raw);
  eq(stripReply(m.text), "Dit is een lange zin die door Apple Mail is afgebroken.");
  eq(m.attachments.map((a) => a.filename), ["log.txt"]);
});

// ---- citaten ----
Deno.test("citaat en handtekening weghalen (Gmail, Outlook, Apple Mail, Engels, onderaan)", () => {
  eq(stripReply("Top!\n\nOn Mon, Oct 13, 2026 at 10:00 AM Bingr Support <support@bingr.online> wrote:\n> oud"), "Top!");
  eq(stripReply("Ok\n\nVan: Bingr Support <support@bingr.online>\nVerzonden: maandag 13 oktober 2026 10:00\nAan: Kees\nOnderwerp: [#1001]\n\noud"), "Ok");
  eq(stripReply("Ja\r\n\r\n-----Original Message-----\r\nFrom: x"), "Ja");
  eq(stripReply("Ja\n________________________________\nFrom: x\nSent: y"), "Ja");
  eq(stripReply("Prima\n\n-- \nKees de Vries\n06-12345678"), "Prima");
  eq(stripReply(`Antwoord\n${REPLY_MARKER}\nBINGR Support`), "Antwoord");
  eq(stripReply("Dank!\n\nSent from my iPhone"), "Dank!");
  eq(stripReply("Am 13.10.2026 um 10:00 schrieb Bingr Support <support@bingr.online>:\n> alt\nNeu unten"), "Neu unten");
  // onderaan geantwoord: citaat weg, eigen tekst blijft
  eq(stripReply("Op ma 13 okt 2026 schreef X <x@y.nl>:\n> Werkt het?\n\nJa, nu wel.\n> En dit?\nOok."), "Ja, nu wel.\nOok.");
  // gewone regel die met "Op" begint is geen citaat
  eq(stripReply("Op mijn Apple TV werkt het niet.\nGroet"), "Op mijn Apple TV werkt het niet.\nGroet");
  eq(stripReply("Van: mij"), "Van: mij");
  eq(htmlToText("<p>a</p><blockquote type=\"cite\">oud</blockquote>").split("\n")[0], "a");
});

// ---- herkennen en beslissen ----
const mailFrom = (from: string, extra = "", subject = "Vraag over Bingr") =>
  parseMessage(crlf(`From: ${from}\nSubject: ${subject}\nMessage-ID: <m1@x>\n${extra}${extra ? "\n" : ""}Content-Type: text/plain\n\nHallo, mijn stream werkt niet.`));
const T = (number: number, email: string, status: TicketLite["status"] = "pending"): TicketLite => ({ number, email, status, lang: "nl" });
const AGENTS = agentList(["support@bingr.online", "Bingr Support <support@bingr.online>", ""], "Leon@Prive.nl, ander@x.nl;fout");

Deno.test("ticketnummers uit onderwerp en Message-ID's", () => {
  eq(numberFromSubject("Re: [#1007] Nieuw antwoord: x"), 1007);
  eq(numberFromSubject("Vraag over ticket #1012"), 1012);
  eq(numberFromSubject("Ik heb 3 vragen #1"), null);
  eq(numberFromSubject("[#5] kort"), 5);
  eq(numberFromSubject("Bestelling 1007"), null);
  eq(numbersFromIds(["<bingr-ticket-1007@bingr.online>", "<bingr-ticket-1008.aB_c@bingr.online>", "<x@y>", "<bingr-ticket-1007.z@bingr.online>"]), [1007, 1008]);
  eq(AGENTS, ["support@bingr.online", "leon@prive.nl", "ander@x.nl"]);
});

Deno.test("beslissen: klant, ander adres, agent, nieuw, gesloten, eigen, automatisch", () => {
  const klant = mailFrom("Klant <KLANT@example.com>");
  eq(decide(klant, [T(1007, "klant@example.com")], AGENTS), { kind: "customer_reply", ticket: T(1007, "klant@example.com") });
  eq(decide(klant, [T(1007, "iemand@anders.nl")], AGENTS), { kind: "reject", reason: "sender_mismatch" });
  eq(decide(klant, [], AGENTS), { kind: "new_ticket", followUp: null });
  eq(decide(klant, [T(1007, "klant@example.com", "closed")], AGENTS), { kind: "new_ticket", followUp: 1007 });
  // build 95: agent alleen met DKIM van het eigen domein (bovenste Authentication-Results)
  eq(decide(mailFrom("Léon <leon@prive.nl>", "Authentication-Results: mx.h.nl; dkim=pass header.d=prive.nl"), [T(1007, "klant@example.com")], AGENTS).kind, "agent_reply");
  eq(decide(mailFrom("Bingr Support <support@bingr.online>", "Authentication-Results: mx.h.nl; dkim=pass header.i=@bingr.online"), [T(1007, "klant@example.com")], AGENTS).kind, "agent_reply");
  eq(decide(mailFrom("leon@prive.nl", "Authentication-Results: mx.h.nl; dkim=pass header.d=prive.nl"), [], AGENTS), { kind: "reject", reason: "agent_no_ticket" });
  // agent die zelf een ticket heeft: als klant
  eq(decide(mailFrom("leon@prive.nl"), [T(1009, "leon@prive.nl", "open")], AGENTS).kind, "customer_reply");
  eq(decide(mailFrom("Bingr Support <support@bingr.online>", "X-Bingr-Ticket: 1007"), [T(1007, "klant@example.com")], AGENTS), { kind: "ignore", reason: "own_system" });
  eq(decide(mailFrom("klant@example.com", "Auto-Submitted: auto-replied"), [], AGENTS), { kind: "ignore", reason: "auto" });
  eq(decide(mailFrom("klant@example.com", "Auto-Submitted: no"), [], AGENTS).kind, "new_ticket");
  eq(decide(mailFrom("klant@example.com", "Precedence: bulk"), [], AGENTS), { kind: "ignore", reason: "bulk" });
  eq(decide(mailFrom("nieuws@winkel.nl", "List-Unsubscribe: <mailto:u@winkel.nl>"), [], AGENTS), { kind: "ignore", reason: "bulk" });
  eq(decide(mailFrom("MAILER-DAEMON@mx.hoster.nl"), [], AGENTS), { kind: "ignore", reason: "bounce" });
  eq(decide(mailFrom("noreply@dienst.nl"), [], AGENTS), { kind: "ignore", reason: "auto" });
  eq(decide(mailFrom("klant@example.com", "", "Automatisch antwoord: [#1007] Nieuw antwoord"), [], AGENTS), { kind: "ignore", reason: "auto" });
  eq(decide(mailFrom("klant@example.com", "X-Spam-Flag: YES"), [], AGENTS), { kind: "ignore", reason: "spam" });
  eq(decide(mailFrom("leon@prive.nl", "Authentication-Results: mx.h.nl; spf=fail smtp.mailfrom=prive.nl; dkim=none; dmarc=fail"), [T(1007, "k@x.nl")], AGENTS), { kind: "reject", reason: "auth_failed" });
  eq(decide(mailFrom("klant@example.com", "Authentication-Results: mx.h.nl; spf=fail; dkim=pass header.d=example.com"), [], AGENTS).kind, "new_ticket");
  eq(decide(parseMessage("Subject: x\r\n\r\nhoi"), [], AGENTS), { kind: "reject", reason: "no_sender" });
});

Deno.test("nieuw ticket: onderwerp, taal, tekst met limiet", () => {
  eq(cleanSubject("Re: Fwd: [#1007] Stream hapert", "nl"), "Stream hapert");
  eq(cleanSubject("RE:", "nl"), "(geen onderwerp)");
  eq(cleanSubject("", "en"), "(no subject)");
  eq(guessLang(mailFrom("a@b.nl"), "Hallo, mijn stream werkt niet bij de app."), "nl");
  eq(guessLang(mailFrom("a@b.com", "", "Help"), "Hi, the app does not work on my TV and I can't sign in. Thanks"), "en");
  const long = parseMessage(crlf(`From: a@b.nl\nContent-Type: text/plain\n\n${"woord ".repeat(2000)}`));
  const body = messageBody(long, "nl")!;
  ok(body.length <= 5000 && body.endsWith("… (ingekort)"), body.slice(-30));
  eq(messageBody(parseMessage(crlf("From: a@b.nl\nContent-Type: text/plain\n\n> alleen citaat")), "nl"), null);
  eq(imapDate(new Date("2026-10-07T12:00:00Z")), "7-Oct-2026");
  eq(findFolder([{ name: "INBOX", delim: ".", flags: [] }, { name: "INBOX.Bingr-verwerkt", delim: ".", flags: ["\\HasNoChildren"] }]), "INBOX.Bingr-verwerkt");
  eq(findFolder([{ name: "INBOX", delim: "/", flags: [] }]), null);
});

Deno.test("uitgaande mail: markeringsregel en X-Bingr-Ticket-antwoord wordt netjes afgeknipt", () => {
  const d = { kind: "customer_reply" as const, lang: "nl" as const, number: 1007, subject: "Stream", status: "pending" as const, url: "https://x", body: "Probeer VLC", replyByMail: true };
  const mail = renderMail(d);
  ok(mail.text.startsWith(REPLY_MARKER), "marker bovenaan tekst");
  ok(mail.html.includes(REPLY_MARKER), "marker in html");
  ok(mail.text.includes("Beantwoord deze e-mail"), "voettekst");
  ok(!renderMail({ ...d, replyByMail: false }).text.includes(REPLY_MARKER), "zonder import geen marker");
  // een antwoord dat de hele mail citeert zonder "schreef"-regel (sommige webmails)
  eq(stripReply(`Bedankt, gelukt!\n\n${mail.text}`), "Bedankt, gelukt!");
  // HTML-antwoord met onze mail eronder (zonder blockquote)
  eq(stripReply(htmlToText(`<p>Gelukt</p>${mail.html}`)), "Gelukt");
});

// ---- build 95: vervalste afzender support@ ----
const AR = (v: string) => `Authentication-Results: ${v}`;
Deno.test("build 95: afzender support@ zonder DKIM is geen agent", () => {
  const tk = [T(1007, "klant@example.com")];
  // vervalst From zonder Authentication-Results
  eq(decide(mailFrom("Bingr Support <support@bingr.online>"), tk, AGENTS), { kind: "reject", reason: "agent_unverified" });
  // dkim=pass, maar van een ander domein (aanvaller tekent met zijn eigen domein)
  eq(decide(mailFrom("support@bingr.online", AR("mx.h.nl; dkim=pass header.d=evil.example; spf=pass")), tk, AGENTS), { kind: "reject", reason: "agent_unverified" });
  eq(decide(mailFrom("support@bingr.online", AR("mx.h.nl; dkim=fail header.d=bingr.online")), tk, AGENTS), { kind: "reject", reason: "agent_unverified" });
  // subdomein telt niet als hetzelfde domein
  eq(decide(mailFrom("support@bingr.online", AR("mx.h.nl; dkim=pass header.d=mail.bingr.online")), tk, AGENTS).kind, "reject");
  // nooit customer_reply op het ticket van een ander, ook niet via [#1007] in het onderwerp
  eq(decide(mailFrom("support@bingr.online", "", "Re: [#1007] x"), tk, AGENTS).kind, "reject");
});
Deno.test("build 95: alleen de BOVENSTE Authentication-Results telt (onze server); lagere zijn van de afzender", () => {
  const tk = [T(1007, "klant@example.com")];
  // onze server: dkim=none bovenaan; de afzender stuurde zelf een "dkim=pass" eronder mee
  const injected = mailFrom("support@bingr.online", `${AR("mx.h.nl; dkim=none; spf=softfail")}\n${AR("mx.h.nl; dkim=pass header.d=bingr.online")}`);
  eq(dkimPassDomains(injected), []);
  eq(decide(injected, tk, AGENTS), { kind: "reject", reason: "agent_unverified" });
  // geldig: bovenste kopregel van onze server met dkim=pass d=bingr.online (lagere kopregels doen er niet toe)
  const valid = mailFrom("Bingr Support <support@bingr.online>", `${AR("mx2.hoster.nl 1; dkim=pass (2048-bit key; unprotected) header.d=bingr.online header.s=x header.b=AbC; spf=pass")}\n${AR("evil; dkim=fail")}`);
  eq(dkimPassDomains(valid), ["bingr.online"]);
  ok(senderVerified(valid, authservNames("imap.hoster.nl")), "authserv-id mx2.hoster.nl past bij imap.hoster.nl");
  eq(decide(valid, tk, AGENTS, authservNames("imap.hoster.nl")), { kind: "agent_reply", ticket: tk[0] });
  // authserv-id van een andere server: niet vertrouwd (onze server zette geen Authentication-Results)
  eq(decide(valid, tk, AGENTS, authservNames("imap.anders.nl")), { kind: "reject", reason: "agent_unverified" });
  eq(decide(valid, tk, AGENTS, authservNames("", "mx2.hoster.nl, mx.google.com")).kind, "agent_reply");
  eq(authservNames("imap.hoster.nl"), ["imap.hoster.nl", "hoster.nl"]);
  eq(authservNames("hoster.nl"), ["hoster.nl"]);
  eq(authservNames("1.2.3.4"), []);
  eq(authservNames("imap.hoster.nl", "MX.Google.com"), ["mx.google.com"]);
  // een klant mag nog steeds gewoon reageren (geen DKIM nodig), alleen vanaf het adres van het ticket
  eq(decide(mailFrom("klant@example.com", "", "Re: [#1007] x"), tk, AGENTS).kind, "customer_reply");
  eq(decide(mailFrom("iemand@anders.nl", "", "Re: [#1007] x"), tk, AGENTS), { kind: "reject", reason: "sender_mismatch" });
});

Deno.test("build 95: blockquote alleen in een antwoord weghalen, en alleen het blok", () => {
  const html = "<p>Eerst</p><blockquote>citaat<blockquote>dieper</blockquote>nog citaat</blockquote><p>Daarna</p>";
  eq(stripReply(htmlToText(html, { reply: true })), "Eerst\n\nDaarna");
  eq(stripReply(htmlToText(html, { reply: false })), "Eerst\n\ncitaat\ndieper\nnog citaat\n\nDaarna");
  const mk = (extra: string) => parseMessage(crlf(`From: a@b.nl\nSubject: Vraag\n${extra}Content-Type: text/html\n\n${html}`));
  ok(stripReply(mk("").text).includes("nog citaat\n\nDaarna"), "nieuwe mail: citaat blijft");
  eq(stripReply(mk("In-Reply-To: <x@y>\n").text), "Eerst\n\nDaarna");
  eq(stripReply(parseMessage(crlf(`From: a@b.nl\nSubject: Re: [#1007] x\nContent-Type: text/html\n\n${html}`)).text), "Eerst\n\nDaarna");
  // Apple Mail onderaan geantwoord: toeschrijving + citaat weg, eigen tekst erna blijft
  eq(stripReply(htmlToText('<div>Op ma 13 okt 2026 schreef X &lt;x@y.nl&gt;:</div><blockquote type="cite">oud</blockquote><div>Nieuw onderaan</div>')), "Nieuw onderaan");
});

// ---- IMAP ----
Deno.test("tokenizer: lijsten, strings, NIL, literals, secties", () => {
  const lit = new TextEncoder().encode("Hallo");
  const show = (t: unknown): unknown => t instanceof Uint8Array ? "LIT" : Array.isArray(t) ? t.map(show) : t;
  eq(show(tokenize('12 FETCH (UID 34 FLAGS (\\Seen) BODY[HEADER.FIELDS (FROM)]<0> \u00000\u0000 X NIL "a \\"b\\"")', [lit])),
    ["12", "FETCH", ["UID", "34", "FLAGS", ["\\Seen"], "BODY[HEADER.FIELDS (FROM)]<0>", "LIT", "X", null, 'a "b"']]);
});

/** Nep-IMAP-server (één verbinding) met een paar mails; logt de commando's. */
function fakeServer(opts: { mails: Record<number, string>; folders?: string[]; move?: boolean; failLogin?: boolean; stall?: boolean }) {
  const listener = Deno.listen({ hostname: "127.0.0.1", port: 0 });
  const log: string[] = [];
  const port = (listener.addr as Deno.NetAddr).port;
  const done = (async () => {
    const conn = await listener.accept();
    const enc = new TextEncoder(), dec = new TextDecoder();
    const w = (s: string | Uint8Array) => conn.write(typeof s === "string" ? enc.encode(s) : s);
    await w(`* OK [CAPABILITY IMAP4rev1 LITERAL+ ${opts.move ? "MOVE " : ""}UIDPLUS] Nep klaar\r\n`);
    let buf = "";
    const b = new Uint8Array(65536);
    const flags: Record<number, string[]> = {};
    const more = async () => { const n = await conn.read(b).catch(() => null); if (!n) return false; buf += dec.decode(b.subarray(0, n)); return true; };
    const readLine = async (): Promise<string | null> => {
      while (!buf.includes("\r\n")) if (!(await more())) return null;
      const i = buf.indexOf("\r\n");
      const line = buf.slice(0, i); buf = buf.slice(i + 2);
      return line;
    };
    for (;;) {
      let line = await readLine();
      if (line === null) break;
      // literal {n} in het commando: voortzetting sturen, de bytes en de rest van de regel lezen
      let m: RegExpExecArray | null;
      while (line !== null && (m = /\{(\d+)\}$/.exec(line))) {
        if (opts.stall) break;
        await w("+ Ga door\r\n");
        const len = Number(m[1]);
        while (enc.encode(buf).length < len) if (!(await more())) break;
        const lit = buf.slice(0, len); buf = buf.slice(len);
        const rest: string | null = await readLine();
        line = line.slice(0, m.index) + `<${lit}>` + (rest ?? "");
      }
      if (line === null) break;
      {
        log.push(line);
        if (opts.stall) continue;
        const [tag, cmd, ...rest] = line.split(" ");
        const arg = rest.join(" ");
        const C = cmd?.toUpperCase();
        if (C === "LOGIN") await w(opts.failLogin ? `${tag} NO [AUTHENTICATIONFAILED] Onjuist\r\n` : `${tag} OK [CAPABILITY IMAP4rev1 ${opts.move ? "MOVE " : ""}UIDPLUS] Welkom\r\n`);
        else if (C === "LIST") { for (const f of ["INBOX", ...(opts.folders ?? [])]) await w(`* LIST (\\HasNoChildren) "." ${f}\r\n`); await w(`${tag} OK LIST\r\n`); }
        else if (C === "SELECT") await w(`* ${Object.keys(opts.mails).length} EXISTS\r\n* OK [UIDVALIDITY 777] ok\r\n* OK [UIDNEXT ${Math.max(0, ...Object.keys(opts.mails).map(Number)) + 1}] ok\r\n${tag} OK [READ-WRITE] SELECT\r\n`);
        else if (C === "UID" && /^SEARCH/i.test(arg)) {
          const r = /UID (\d+):\*/.exec(arg);
          const from = r ? Number(r[1]) : 0;
          let uids = Object.keys(opts.mails).map(Number).filter((u) => u >= from);
          if (r && !uids.length) uids = [Math.max(...Object.keys(opts.mails).map(Number))]; // n:* geeft altijd de laatste
          if (/UNSEEN/.test(arg)) uids = uids.filter((u) => !(flags[u] ?? []).includes("\\Seen"));
          await w(`* SEARCH ${uids.join(" ")}\r\n${tag} OK SEARCH\r\n`);
        } else if (C === "UID" && /^FETCH/i.test(arg)) {
          const uid = Number(arg.split(" ")[1]);
          const body = enc.encode(opts.mails[uid] ?? "");
          await w(`* 1 EXISTS\r\n* ${uid} FETCH (UID ${uid} RFC822.SIZE ${body.length} BODY[]<0> {${body.length}}\r\n`);
          await w(body);
          await w(`)\r\n${tag} OK FETCH\r\n`);
        } else if (C === "UID" && /^STORE/i.test(arg)) {
          for (const u of arg.split(" ")[1].split(",")) (flags[Number(u)] ??= []).push("\\Seen");
          await w(`${tag} OK STORE\r\n`);
        } else if (C === "UID" && /^(MOVE|COPY)/i.test(arg)) await w(`${tag} OK done\r\n`);
        else if (C === "LOGOUT") { await w(`* BYE dag\r\n${tag} OK LOGOUT\r\n`); conn.close(); listener.close(); return { log, flags }; }
        else await w(`${tag} BAD onbekend\r\n`);
      }
    }
    try { conn.close(); } catch { /* */ }
    listener.close();
    return { log, flags };
  })();
  return { port, done, log };
}

Deno.test("IMAP-client tegen een nep-server: login met literal, list, select, search, fetch, store, move, logout", async () => {
  const mails = { 5: GMAIL_REPLY, 6: crlf("From: a@b.nl\nSubject: twee\n\nkort") };
  const srv = fakeServer({ mails, folders: ["INBOX.Bingr-verwerkt"], move: true });
  const c = await Imap.connect({ host: "127.0.0.1", port: srv.port, tls: false, timeoutMs: 3000 });
  await c.login("support@bingr.online", "geh\"eim\\wåchtwoord"); // 8-bit: als literal
  const folder = findFolder(await c.list());
  eq(folder, "INBOX.Bingr-verwerkt");
  const sel = await c.select("INBOX");
  eq(sel, { exists: 2, uidvalidity: 777, uidnext: 7 });
  eq(await c.uidSearch("UID 6:*"), [6]);
  eq(await c.uidSearch("UID 9:*"), [6]); // n:* geeft de laatste, de client filtert zelf
  const [it] = await c.uidFetch([5], "(UID RFC822.SIZE BODY.PEEK[]<0.2097152>)");
  eq(it.uid, 5);
  eq(it.size, new TextEncoder().encode(GMAIL_REPLY).length);
  ok(it.partial, "partial fetch");
  eq(parseMessage(it.body!).messageId, "<CAF=abc123@mail.gmail.com>");
  await c.uidStore([5, 6], "+FLAGS.SILENT (\\Seen)");
  eq(await c.uidSearch("UNSEEN"), []);
  eq(await c.uidMove([5], folder!), "moved");
  await c.logout();
  const { log } = await srv.done;
  ok(log.some((l) => l === 'B1 LOGIN "support@bingr.online" <geh"eim\\wåchtwoord>'), log.join(" | "));
  ok(log.some((l) => /UID MOVE 5 "INBOX.Bingr-verwerkt"/.test(l)), "move");
});

Deno.test("IMAP-client: verkeerd wachtwoord, COPY zonder MOVE, time-out", async () => {
  const s1 = fakeServer({ mails: { 1: "x" }, failLogin: true });
  const c1 = await Imap.connect({ host: "127.0.0.1", port: s1.port, tls: false, timeoutMs: 3000 });
  let err = "";
  try { await c1.login("a", "b"); } catch (e) { err = (e as Error).message; }
  ok(/inloggen mislukt/.test(err), err);
  await c1.logout(); await s1.done;

  const s2 = fakeServer({ mails: { 1: "x" } });
  const c2 = await Imap.connect({ host: "127.0.0.1", port: s2.port, tls: false, timeoutMs: 3000 });
  await c2.login("a", "b");
  eq(await c2.uidMove([1], "Bingr-verwerkt"), "copied");
  await c2.logout(); await s2.done;

  const s3 = fakeServer({ mails: { 1: "x" }, stall: true });
  const c3 = await Imap.connect({ host: "127.0.0.1", port: s3.port, tls: false, timeoutMs: 300 });
  const t0 = Date.now();
  try { await c3.login("a", "b"); err = ""; } catch (e) { err = (e as Error).message; }
  ok(/time-out/.test(err) && Date.now() - t0 < 2000, err);
  await s3.done;
});
