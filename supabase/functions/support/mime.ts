// Supporttickets per e-mail: RFC 822/MIME-berichten lezen (pure functies, geen netwerk), getest in inbox_test.ts.
// Kopregels (ook encoded-words =?utf-8?B/Q?…?=), multipart (ook genest), quoted-printable en base64, tekensets
// (utf-8, iso-8859-1, windows-1252 … via TextDecoder), HTML naar tekst, bijlagen (alleen naam en grootte), en
// geciteerde tekst en handtekeningen uit een antwoord halen.

export type Address = { name: string; address: string };
export type Attachment = { filename: string; contentType: string; size: number };
export type ParsedMail = {
  headers: [string, string][]; // [naam in kleine letters, waarde (gedecodeerd, ontvouwen)] in volgorde
  header: (name: string) => string; // eerste waarde of ""
  from: Address | null;
  replyTo: Address | null;
  to: Address[];
  subject: string;
  messageId: string; // met <>, of "" als hij ontbreekt
  inReplyTo: string[];
  references: string[];
  date: string;
  contentType: string;
  text: string; // de leesbare tekst (text/plain, anders text/html omgezet), nog mét citaten
  fromHtml: boolean; // tekst kwam uit text/html
  attachments: Attachment[];
  truncated: boolean; // bericht was afgekapt (te groot) of multipart niet afgesloten
};

// ---- bytes en tekensets ----
/** Bytes als "binaire string" (elk teken = één byte), zodat we met gewone stringfuncties kunnen zoeken. */
export const bin = (b: Uint8Array) => {
  let s = "";
  for (let i = 0; i < b.length; i += 8192) s += String.fromCharCode(...b.subarray(i, i + 8192));
  return s;
};
const unbin = (s: string) => {
  const b = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) b[i] = s.charCodeAt(i) & 0xff;
  return b;
};

const CHARSET_ALIAS: Record<string, string> = {
  "utf8": "utf-8", "latin1": "windows-1252", "latin-1": "windows-1252", "iso8859-1": "windows-1252", "iso-8859-1": "windows-1252",
  "us-ascii": "windows-1252", "ascii": "windows-1252", "cp1252": "windows-1252", "ansi_x3.4-1968": "windows-1252",
  "unicode-1-1-utf-7": "utf-7", "ks_c_5601-1987": "euc-kr",
};
/** Bytes naar tekst in de gegeven tekenset; onbekend of fout: utf-8 als dat geldig is, anders windows-1252. */
export function decodeBytes(b: Uint8Array, charset = ""): string {
  let cs = charset.trim().toLowerCase().replace(/^["']|["']$/g, "").replace(/\*.*$/, "");
  cs = CHARSET_ALIAS[cs] ?? cs;
  if (cs && cs !== "utf-8") {
    try { return new TextDecoder(cs).decode(b); } catch { /* onbekend: hieronder */ }
  }
  try { return new TextDecoder("utf-8", { fatal: true }).decode(b); } catch {
    return cs === "utf-8" ? new TextDecoder("utf-8").decode(b) : new TextDecoder("windows-1252").decode(b);
  }
}

/** quoted-printable naar bytes (zachte regeleinden "=\r\n" weg, "=XX" naar de byte). */
export function decodeQP(s: string): Uint8Array {
  const t = s.replace(/=[ \t]*\r?\n/g, "");
  const out: number[] = [];
  for (let i = 0; i < t.length; i++) {
    const c = t.charCodeAt(i);
    if (c === 61 /* = */ && /^[0-9A-Fa-f]{2}$/.test(t.slice(i + 1, i + 3))) { out.push(parseInt(t.slice(i + 1, i + 3), 16)); i += 2; }
    else out.push(c & 0xff);
  }
  return new Uint8Array(out);
}
/** base64 naar bytes, tolerant voor regeleinden, rommel en ontbrekende opvulling. */
export function decodeB64(s: string): Uint8Array {
  let t = s.replace(/[^A-Za-z0-9+/]/g, "");
  t = t.slice(0, t.length - (t.length % 4 === 1 ? 1 : 0));
  while (t.length % 4) t += "=";
  try { return unbin(atob(t)); } catch { return new Uint8Array(); }
}

// ---- kopregels ----
/** Encoded-words (RFC 2047) in een kopregel: =?utf-8?B?…?= en =?iso-8859-1?Q?…?=; aangrenzende woorden zonder spatie. */
export function decodeWords(v: string): string {
  const re = /=\?([^?\s]+)\?([BbQq])\?([^?]*)\?=/g;
  // witruimte tussen twee encoded-words telt niet mee
  const s = v.replace(/(=\?[^?\s]+\?[BbQq]\?[^?]*\?=)\s+(?==\?[^?\s]+\?[BbQq]\?[^?]*\?=)/g, "$1");
  // aangrenzende stukken in dezelfde tekenset eerst samenvoegen (een utf-8-teken kan over twee woorden verdeeld zijn)
  const parts: { cs: string; bytes: number[] }[] = [];
  let out = "", last = 0, m: RegExpExecArray | null;
  const flush = () => { for (const p of parts) out += decodeBytes(new Uint8Array(p.bytes), p.cs); parts.length = 0; };
  while ((m = re.exec(s))) {
    if (m.index > last) { flush(); out += s.slice(last, m.index); }
    const cs = m[1].toLowerCase().replace(/\*.*$/, "");
    const bytes = m[2].toUpperCase() === "B" ? decodeB64(m[3]) : decodeQP(m[3].replace(/_/g, " "));
    const prev = parts[parts.length - 1];
    if (prev && prev.cs === cs) prev.bytes.push(...bytes); else parts.push({ cs, bytes: [...bytes] });
    last = re.lastIndex;
  }
  flush();
  return out + s.slice(last);
}

function splitHead(raw: string): { head: string; body: string } {
  const m = /\r?\n\r?\n/.exec(raw);
  if (!m) return { head: raw, body: "" };
  return { head: raw.slice(0, m.index), body: raw.slice(m.index + m[0].length) };
}
/** Kopregels uit een (binair) kopblok: ontvouwen; ruwe 8-bit (utf-8 of latin-1) en encoded-words gedecodeerd. */
export function parseHeaders(head: string, decode = true): [string, string][] {
  const out: [string, string][] = [];
  const text = decodeBytes(unbin(head)); // RFC 6532: ruwe utf-8 in kopregels mag ook
  for (const line of text.replace(/\r?\n(?=[ \t])/g, "").split(/\r?\n/)) {
    const i = line.indexOf(":");
    if (i <= 0) continue;
    const name = line.slice(0, i).trim().toLowerCase();
    if (!/^[\x21-\x39\x3b-\x7e]+$/.test(name)) continue;
    const val = line.slice(i + 1).replace(/^[ \t]+/, "").replace(/\s+$/, "");
    out.push([name, decode ? decodeWords(val) : val]);
  }
  return out;
}

/** Content-Type/-Disposition: waarde en parameters (ook RFC 2231: name*=utf-8''…, name*0*=…, name*1*=…). */
export function parseParams(v: string): { value: string; params: Record<string, string> } {
  const parts: string[] = [];
  let cur = "", q = false;
  for (let i = 0; i < v.length; i++) {
    const c = v[i];
    if (c === '"' && v[i - 1] !== "\\") q = !q;
    if (c === ";" && !q) { parts.push(cur); cur = ""; } else cur += c;
  }
  parts.push(cur);
  const value = (parts.shift() ?? "").trim().toLowerCase();
  const raw: Record<string, { v: string; ext: boolean }[]> = {};
  const plain: Record<string, string> = {};
  for (const p of parts) {
    const i = p.indexOf("=");
    if (i < 0) continue;
    const key = p.slice(0, i).trim().toLowerCase();
    let val = p.slice(i + 1).trim();
    if (val.startsWith('"')) val = val.slice(1, val.endsWith('"') ? -1 : undefined).replace(/\\(.)/g, "$1");
    const m = /^([^*]+)\*(\d+)?(\*)?$/.exec(key);
    if (m) {
      (raw[m[1]] ??= [])[Number(m[2] ?? 0)] = { v: val, ext: !!m[3] || m[2] === undefined };
    } else plain[key] = val;
  }
  const params: Record<string, string> = { ...plain };
  for (const [k, segs] of Object.entries(raw)) {
    let cs = "utf-8", bytes: number[] = [], first = true;
    for (const s of segs) {
      if (!s) continue;
      let val = s.v;
      if (s.ext) {
        if (first) { const m = /^([^']*)'[^']*'(.*)$/.exec(val); if (m) { cs = m[1] || cs; val = m[2]; } }
        bytes = bytes.concat([...unbin(val.replace(/%([0-9A-Fa-f]{2})/g, (_, h) => String.fromCharCode(parseInt(h, 16))))]);
      } else bytes = bytes.concat([...new TextEncoder().encode(val)]);
      first = false;
    }
    params[k] = decodeBytes(new Uint8Array(bytes), cs);
  }
  return { value, params };
}

/** Adressen uit een From/To-waarde ("Naam" <a@b>, a@b, Naam <a@b>, a@b (Naam)), met komma's tussen aanhalingstekens. */
export function parseAddresses(v: string): Address[] {
  const out: Address[] = [];
  let cur = "", q = false, angle = 0;
  const items: string[] = [];
  for (const c of v) {
    if (c === '"') q = !q;
    if (!q && c === "<") angle++;
    if (!q && c === ">") angle = Math.max(0, angle - 1);
    if (c === "," && !q && !angle) { items.push(cur); cur = ""; } else cur += c;
  }
  items.push(cur);
  for (const it of items) {
    const s = it.trim();
    if (!s) continue;
    const m = /<\s*([^<>\s]+@[^<>\s]+)\s*>/.exec(s);
    let address = "", name = "";
    if (m) { address = m[1]; name = s.slice(0, m.index).trim(); }
    else {
      const a = /[^\s<>()"]+@[^\s<>()"]+/.exec(s);
      if (!a) continue;
      address = a[0];
      name = (/\(([^)]*)\)/.exec(s)?.[1] ?? "").trim();
    }
    name = name.replace(/^"(.*)"$/s, "$1").replace(/\\(.)/g, "$1").trim();
    out.push({ name, address: address.replace(/^mailto:/i, "").toLowerCase() });
  }
  return out;
}
/** Message-ID's (<…>) uit In-Reply-To/References. */
export const parseIds = (v: string) => (v.match(/<[^<>\s]+>/g) ?? []).slice(0, 50);

// ---- MIME-delen ----
type Part = { headers: [string, string][]; body: string; depth: number };
const hget = (h: [string, string][], n: string) => h.find(([k]) => k === n)?.[1] ?? "";

function transferDecode(body: string, cte: string): Uint8Array {
  const e = cte.trim().toLowerCase();
  if (e === "base64") return decodeB64(body);
  if (e === "quoted-printable") return decodeQP(body);
  return unbin(body);
}

const MAX_PARTS = 200;
export function parseMessage(input: Uint8Array | string, opts: { truncated?: boolean } = {}): ParsedMail {
  const raw = typeof input === "string" ? bin(new TextEncoder().encode(input)) : bin(input);
  const { head, body } = splitHead(raw);
  const headers = parseHeaders(head);
  const header = (n: string) => hget(headers, n.toLowerCase());
  const texts: string[] = [];
  const htmls: string[] = [];
  const attachments: Attachment[] = [];
  let truncated = !!opts.truncated, parts = 0;

  const walk = (p: Part) => {
    if (++parts > MAX_PARTS) { truncated = true; return; }
    const ct = parseParams(hget(p.headers, "content-type") || "text/plain");
    const cd = parseParams(hget(p.headers, "content-disposition"));
    const type = ct.value || "text/plain";
    const filename = (cd.params.filename || ct.params.name || "").replace(/[\r\n]+/g, " ").trim();
    if (type.startsWith("multipart/") && p.depth < 12) {
      const boundary = ct.params.boundary;
      if (!boundary) { texts.push(decodeBytes(unbin(p.body))); return; }
      const { children, closed } = splitMultipart(p.body, boundary);
      if (!closed) truncated = true;
      const kids = children.map((c) => { const s = splitHead(c); return { headers: parseHeaders(s.head), body: s.body, depth: p.depth + 1 }; });
      if (type === "multipart/alternative") {
        // voorkeur: text/plain, anders html, anders het laatste (meest uitgebreide) deel
        const typeOf = (k: Part) => parseParams(hget(k.headers, "content-type") || "text/plain").value || "text/plain";
        const pick = kids.find((k) => typeOf(k) === "text/plain" && hasText(k)) ?? kids.find((k) => typeOf(k) === "text/html")
          ?? kids.find((k) => typeOf(k).startsWith("multipart/")) ?? kids[kids.length - 1];
        if (pick) walk(pick);
        return;
      }
      for (const k of kids) walk(k);
      return;
    }
    const isBody = (type === "text/plain" || type === "text/html") && cd.value !== "attachment";
    if (!isBody) {
      // inline afbeeldingen met Content-ID (logo in een handtekening) tellen niet als bijlage
      if (cd.value !== "attachment" && hget(p.headers, "content-id") && type.startsWith("image/")) return;
      const size = transferDecode(p.body, hget(p.headers, "content-transfer-encoding")).length;
      const ext = (type.split("/")[1] ?? "").replace(/[^a-z0-9]/g, "").slice(0, 8);
      const name = filename || (type === "message/rfc822" ? "doorgestuurd-bericht.eml" : ext ? `bijlage.${ext}` : "bijlage");
      attachments.push({ filename: name.slice(0, 120), contentType: type, size });
      return;
    }
    const txt = decodeBytes(transferDecode(p.body, hget(p.headers, "content-transfer-encoding")), ct.params.charset ?? "");
    if (type === "text/html") htmls.push(txt);
    else texts.push(/^flowed$/i.test(ct.params.format ?? "") ? unflow(txt, /^yes$/i.test(ct.params.delsp ?? "")) : txt);
  };
  walk({ headers, body, depth: 0 });

  const plain = texts.join("\n\n").trim();
  const fromHtml = !plain && htmls.length > 0;
  // build 95: citaatblokken (<blockquote>) alleen weghalen in een antwoord (In-Reply-To/References of "[#1007]" in het
  // onderwerp); in een nieuwe mail is een blockquote gewoon inhoud
  const reply = isReplyMail(header("in-reply-to"), header("references"), header("subject"));
  const text = fromHtml ? htmls.map((h) => htmlToText(h, { reply })).join("\n\n") : plain;
  return {
    headers, header,
    from: parseAddresses(header("from"))[0] ?? null,
    replyTo: parseAddresses(header("reply-to"))[0] ?? null,
    to: [...parseAddresses(header("to")), ...parseAddresses(header("cc"))],
    subject: header("subject").replace(/\s+/g, " ").trim(),
    messageId: parseIds(header("message-id"))[0] ?? "",
    inReplyTo: parseIds(header("in-reply-to")),
    references: parseIds(header("references")),
    date: header("date"),
    contentType: parseParams(header("content-type") || "text/plain").value,
    text: text.replace(/\r\n?/g, "\n"), fromHtml, attachments, truncated,
  };
}
const hasText = (k: Part) => k.body.trim().length > 0;

/** Delen van een multipart-body; closed = afsluitende grens gevonden. */
export function splitMultipart(body: string, boundary: string): { children: string[]; closed: boolean } {
  const delim = "--" + boundary;
  const lines = body.split(/\r?\n/);
  const children: string[] = [];
  let cur: string[] | null = null, closed = false;
  for (const line of lines) {
    const l = line.replace(/[ \t]+$/, "");
    if (l === delim + "--") { if (cur) children.push(cur.join("\r\n")); cur = null; closed = true; break; }
    if (l === delim) { if (cur) children.push(cur.join("\r\n")); cur = []; continue; }
    if (cur) cur.push(line);
  }
  if (cur) children.push(cur.join("\r\n"));
  return { children, closed };
}

/** format=flowed (RFC 3676): zachte regeleinden (regel eindigt op een spatie) samenvoegen. */
function unflow(s: string, delsp: boolean): string {
  const out: string[] = [];
  let buf = "";
  for (const line of s.replace(/\r\n?/g, "\n").split("\n")) {
    const l = line === "-- " ? line : line.replace(/^ /, ""); // space-stuffing weg
    if (l.endsWith(" ") && l !== "-- " && !/^>/.test(l)) { buf += delsp ? l.slice(0, -1) : l; continue; }
    out.push(buf + l); buf = "";
  }
  if (buf) out.push(buf);
  return out.join("\n");
}

// ---- HTML naar tekst ----
const ENT: Record<string, string> = {
  amp: "&", lt: "<", gt: ">", quot: '"', apos: "'", nbsp: " ", euro: "€", copy: "©", reg: "®", hellip: "…", ndash: "–", mdash: "—",
  lsquo: "‘", rsquo: "’", ldquo: "“", rdquo: "”", bull: "•", middot: "·", eacute: "é", egrave: "è", euml: "ë", iuml: "ï", ouml: "ö",
  uuml: "ü", auml: "ä", aacute: "á", oacute: "ó", ccedil: "ç", szlig: "ß", Eacute: "É", zwnj: "", zwj: "", shy: "",
};
export const decodeEntities = (s: string) =>
  s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);?/gi, (m, e: string) => {
    if (e[0] === "#") {
      const n = e[1] === "x" || e[1] === "X" ? parseInt(e.slice(2), 16) : parseInt(e.slice(1), 10);
      return n > 0 && n < 0x110000 ? String.fromCodePoint(n) : "";
    }
    return ENT[e] ?? ENT[e.toLowerCase()] ?? m;
  });

/** build 95: antwoord op een eerdere mail: In-Reply-To/References, of een ticketnummer "[#1007]" in het onderwerp. */
export const isReplyMail = (inReplyTo: string, references: string, subject: string) =>
  parseIds(inReplyTo).length > 0 || parseIds(references).length > 0 || /\[#\d{1,12}\]/.test(subject);

/** build 95: elk buitenste <blockquote>…</blockquote>-blok (met geneste blokken) vervangen door één citaatregel ">",
 *  zodat stripReply alleen dat blok overslaat en de tekst erna (onderaan of tussendoor geantwoord) blijft staan.
 *  Een niet afgesloten blok loopt tot het einde. */
export function dropBlockquotes(html: string): string {
  const re = /<(\/?)blockquote\b[^>]*>/gi;
  let out = "", depth = 0, last = 0, m: RegExpExecArray | null;
  while ((m = re.exec(html))) {
    if (!m[1]) {
      if (depth === 0) out += html.slice(last, m.index);
      depth++;
    } else if (depth > 0) {
      depth--;
      if (depth === 0) { out += "\n>\n"; last = re.lastIndex; }
    }
  }
  if (depth > 0) return out + "\n>\n";
  return out + html.slice(last);
}

/** Regel waarop een geciteerd bericht begint (intern; komt nooit in een ticket). */
export const QUOTE_CUT = "⁣BINGR-QUOTE⁣";
/** HTML naar leesbare tekst. Citaatblokken (Gmail, Outlook, Apple Mail, Thunderbird) worden gemarkeerd met QUOTE_CUT.
 *  build 95: een gewone <blockquote> alleen in een antwoord (reply, standaard aan) en dan alleen dat blok (dropBlockquotes);
 *  in een nieuwe mail blijft de tekst erin gewoon staan. */
export function htmlToText(html: string, opts: { reply?: boolean } = {}): string {
  const reply = opts.reply !== false;
  let s = (reply ? dropBlockquotes(html) : html)
    .replace(/<!--[\s\S]*?-->/g, "")
    .replace(/<(head|style|script|title|xml)\b[\s\S]*?<\/\1\s*>/gi, "")
    // verborgen tekst (preheader van nieuwsbrieven en van onze eigen mails) telt niet mee
    .replace(/<(div|span|p)\b[^>]*\bstyle\s*=\s*["'][^"']*display\s*:\s*none[^"']*["'][^>]*>[^<]*<\/\1\s*>/gi, "")
    // begin van een citaat: daar knippen
    .replace(/<div\b[^>]*\bclass\s*=\s*["']?[^"'>]*\b(gmail_quote|gmail_attr|yahoo_quoted|moz-cite-prefix|protonmail_quote)\b[^>]*>/gi, `\n${QUOTE_CUT}\n`)
    .replace(/<(div|hr|span)\b[^>]*\bid\s*=\s*["']?(divRplyFwdMsg|appendonsend|x_divRplyFwdMsg|reply-intro|isForwardContent)\b[^>]*>/gi, `\n${QUOTE_CUT}\n`)
    // build 95: <blockquote> zelf knipt niet meer alles erna af (zie dropBlockquotes); hier alleen een regeleinde
    .replace(/<blockquote\b[^>]*>/gi, "\n")
    .replace(/<br\s*\/?>/gi, "\n")
    .replace(/<li\b[^>]*>/gi, "\n- ")
    .replace(/<\/(p|div|tr|li|h[1-6]|table|ul|ol|blockquote|pre|section|article|header|footer)\s*>/gi, "\n")
    .replace(/<(p|div|tr|h[1-6]|table|ul|ol|pre|hr)\b[^>]*>/gi, "\n")
    .replace(/<\/t[dh]\s*>/gi, " ")
    .replace(/<a\b[^>]*\bhref\s*=\s*["']?(https?:[^"'\s>]+)["']?[^>]*>([\s\S]*?)<\/a\s*>/gi, (_m, href: string, inner: string) => {
      const t = inner.replace(/<[^>]+>/g, "").trim();
      const h = decodeEntities(href);
      return !t || decodeEntities(t) === h || h.replace(/^https?:\/\//, "").startsWith(decodeEntities(t).replace(/^https?:\/\//, "")) ? h : `${t} (${h})`;
    })
    .replace(/<[^>]+>/g, "");
  s = decodeEntities(s).replace(/ /g, " ");
  return s.split(/\r?\n/).map((l) => l.replace(/[ \t]+/g, " ").trim()).join("\n").replace(/\n{3,}/g, "\n\n").trim();
}

// ---- antwoord zonder citaat ----
/** Regel bovenaan elke uitgaande supportmail: alles daaronder is citaat. */
export const REPLY_MARKER = "-- Antwoord boven deze lijn / Reply above this line --";
const MARKER_RE = /^[>\s]*-{2,}\s*antwoord boven deze lijn\s*\/\s*reply above this line\s*-{2,}\s*$/i;
// "Op ma 13 okt 2026 om 10:00 schreef X <x@y>:", "On Mon, … wrote:", "Am … schrieb …:", "Le … a écrit :", "El … escribió:"
const ATTRIB_START = /^(op|on|am|le|el|il|em|w dniu|den|på)\s.+/i;
const ATTRIB_END = /(schreef|wrote|schrieb|a écrit|escribió|ha scritto|escreveu|napisał|skrev)\s*[^:]{0,80}:\s*$/i;
const HARD_SEPARATORS = [
  /^-{2,}\s*(original message|oorspronkelijk bericht|origineel bericht|ursprüngliche nachricht|message d'origine|forwarded message|doorgestuurd bericht)\s*-{2,}\s*$/i,
  /^_{10,}\s*$/, // Outlook (web/mobiel)
  /^(begin forwarded message|begin doorgestuurd bericht)\s*:\s*$/i, // Apple Mail
];
// Outlook: "Van: …" / "From: …" gevolgd door "Verzonden:/Sent:/Datum:/Date:" binnen een paar regels
const OUTLOOK_FROM = /^\*?(van|from|von|de)\s*:\*?\s+\S/i;
const OUTLOOK_NEXT = /^\*?(verzonden|sent|gesendet|envoyé|datum|date|aan|to|onderwerp|subject)\s*:/i;
const MOBILE_SIG = /^(sent from my|verzonden (vanaf|met|via) mijn|verstuurd (vanaf|met|via) mijn|gesendet von meinem|envoyé de mon|get outlook for|download outlook (voor|for)|outlook voor (ios|android)|sent from (outlook|mail for windows|yahoo mail)|verzonden vanuit (outlook|mail voor windows))/i;

/** De nieuwe tekst van een antwoord: zonder citaat (bovenaan of onderaan geantwoord), handtekening en "Verzonden vanaf mijn iPhone". */
export function stripReply(text: string): string {
  const lines = text.replace(/\r\n?/g, "\n").split("\n");
  const out: string[] = [];
  let afterQuote = false; // build 95: na een overgeslagen citaat geen dubbele lege regel
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    const t = l.trim();
    if (t === QUOTE_CUT.trim() || l.includes(QUOTE_CUT) || MARKER_RE.test(t)) break;
    if (HARD_SEPARATORS.some((r) => r.test(t))) break;
    if (OUTLOOK_FROM.test(t) && lines.slice(i + 1, i + 5).some((x) => OUTLOOK_NEXT.test(x.trim()))) break;
    // toeschrijving ("Op … schreef …:"), eventueel over meerdere regels verdeeld
    if (ATTRIB_START.test(t)) {
      let joined = t, j = i;
      while (!ATTRIB_END.test(joined) && j < i + 3 && j + 1 < lines.length) { j++; joined += " " + lines[j].trim(); }
      if (ATTRIB_END.test(joined)) {
        // gevolgd door een citaat met ">": overslaan en verder (onderaan geantwoord); anders hier stoppen
        let k = j + 1;
        while (k < lines.length && !lines[k].trim()) k++;
        if (k < lines.length && /^\s*>/.test(lines[k])) { i = j; continue; }
        break;
      }
    }
    if (/^\s*>/.test(l)) { afterQuote = true; continue; } // geciteerde regel
    if (l === "-- " || t === "--") break; // handtekening
    if (!t && afterQuote && out.length && !out[out.length - 1].trim()) continue;
    if (t) afterQuote = false;
    out.push(l.replace(/\s+$/, ""));
  }
  // onderaan: lege regels en "Verzonden vanaf mijn iPhone" weg
  while (out.length && !out[out.length - 1].trim()) out.pop();
  for (let k = out.length - 1; k >= Math.max(0, out.length - 3); k--) {
    if (MOBILE_SIG.test(out[k].trim())) { out.splice(k); break; }
  }
  while (out.length && !out[out.length - 1].trim()) out.pop();
  while (out.length && !out[0].trim()) out.shift();
  return out.join("\n").replace(/\n{4,}/g, "\n\n\n").trim();
}
