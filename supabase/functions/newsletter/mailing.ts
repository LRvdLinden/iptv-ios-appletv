// Bingr: eigen mailing vanuit het beheer (docs/NEWSLETTER.md, "Eigen mailing vanuit het beheer"). Pure logica zonder
// database of netwerk, zodat alles met `deno test` te controleren is (mailing_test.ts): invoer controleren, de eenvoudige
// opmaak (markdown-achtig) naar veilige HTML en platte tekst, de mail in de huisstijl (_shared/layout.ts), de doelgroep
// (zelfde regels als bingr_mailing_audience in schema.sql) en de verzendronde (wachtrij in batches, idempotent).
// Alles wat de beheerder typt gaat door esc(); links en afbeeldingen alleen via https.
import {
  button, esc, eyebrow, footerHtml, footerText, greeting, greetingText, layout, linkify, RED, title,
} from "../_shared/layout.ts";
import { langOf, type Lang } from "./logic.ts";

export type Audience = "newsletter" | "service";
export const AUDIENCES: readonly Audience[] = ["newsletter", "service"];
export const isAudience = (v: unknown): v is Audience => v === "newsletter" || v === "service";

export type LangContent = { subject: string; body: string; button: string };
export type MailingContent = { nl: LangContent; en: LangContent; image: string; button_url: string };

/** Grenzen van de invoer (tekens). De functie admin (bingr-beheer) gebruikt dezelfde (admin/mailing.ts). */
export const MAX = { subject: 150, body: 8000, button: 40, url: 500 } as const;

// ---------- invoer ----------

// stuurtekens (behalve tab en regeleinde in de tekst), zero-width en richtingtekens
const CTRL_LINE = /[\u0000-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2060-\u2064\ufeff]/g;
const CTRL_BODY = /[\u0000-\u0008\u000b-\u001f\u007f-\u009f\u200b-\u200f\u2028-\u202e\u2060-\u2064\ufeff]/g;
const len = (s: string) => Array.from(s).length;

/** Eén regel (onderwerp, knoptekst): stuurtekens weg, witruimte samengevoegd, getrimd. */
export const cleanLine = (v: unknown) => (typeof v === "string" ? v.replace(CTRL_LINE, " ").replace(/\s+/g, " ").trim() : "");
/** Tekst van de mail: regeleinden \n, stuurtekens weg, tabs als spatie, witruimte aan het eind van regels weg, getrimd. */
export const cleanBody = (v: unknown) =>
  typeof v === "string"
    ? v.replace(/\r\n?/g, "\n").replace(CTRL_BODY, "").replace(/\t/g, " ").replace(/[ \u00a0]+$/gm, "").replace(/\n{3,}/g, "\n\n").trim()
    : "";

/** https-URL zonder inloggegevens, spaties of aanhalingstekens; "" = leeg; null = ongeldig. */
export function cleanUrl(v: unknown): string | null {
  if (v === undefined || v === null || v === "") return "";
  if (typeof v !== "string") return null;
  const s = v.trim();
  if (!s) return "";
  if (s.length > MAX.url || !/^https:\/\/[^\s"'<>\\`]+$/i.test(s)) return null;
  let u: URL;
  try { u = new URL(s); } catch { return null; }
  if (u.protocol !== "https:" || u.username || u.password || !u.hostname.includes(".") || /^[\d.]+$/.test(u.hostname)) return null;
  if (u.hostname === "localhost" || u.hostname.endsWith(".localhost") || u.hostname.endsWith(".local") || u.hostname.endsWith(".internal")) return null;
  return s;
}

export type CleanResult = { ok: true; content: MailingContent } | { ok: false; error: string };
/**
 * Inhoud controleren. `need` = talen waarvoor onderwerp en tekst verplicht zijn (versturen: beide; voorbeeld: alleen de
 * getoonde taal). Een knop vraagt om een URL én een tekst in elke verplichte taal.
 */
export function cleanContent(v: unknown, need: readonly Lang[] = ["nl", "en"]): CleanResult {
  const o = v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
  if (!o) return { ok: false, error: "bad_content" };
  const image = cleanUrl(o.image), button_url = cleanUrl(o.button_url);
  if (image === null) return { ok: false, error: "bad_image_url" };
  if (button_url === null) return { ok: false, error: "bad_button_url" };
  const out = { image, button_url } as MailingContent;
  for (const l of ["nl", "en"] as const) {
    const x = o[l] && typeof o[l] === "object" && !Array.isArray(o[l]) ? o[l] as Record<string, unknown> : {};
    const subject = cleanLine(x.subject), body = cleanBody(x.body), btn = cleanLine(x.button);
    if (len(subject) > MAX.subject || (need.includes(l) && !subject)) return { ok: false, error: `bad_subject_${l}` };
    if (len(body) > MAX.body || (need.includes(l) && !body)) return { ok: false, error: `bad_body_${l}` };
    if (len(btn) > MAX.button) return { ok: false, error: `bad_button_text_${l}` };
    if (button_url && need.includes(l) && !btn) return { ok: false, error: `bad_button_text_${l}` };
    out[l] = { subject, body, button: btn };
  }
  if (!button_url && (out.nl.button || out.en.button)) return { ok: false, error: "bad_button_url" };
  return { ok: true, content: out };
}

// ---------- opmaak ----------
// Blokken worden gescheiden door een lege regel. "# Kop" / "## Kleinere kop", "- punt" of "* punt" (opsomming),
// "1. punt" (genummerd); verder alinea's (een enkel regeleinde blijft een regeleinde). In de tekst: **vet**,
// [linktekst](https://…) en losse https-links.

export type Block =
  | { t: "h"; level: 2 | 3; text: string }
  | { t: "p"; lines: string[] }
  | { t: "ul" | "ol"; items: string[] };

const H = /^(#{1,3})\s+(.+)$/;
const UL = /^\s*[-*•]\s+(.+)$/;
const OL = /^\s*\d{1,3}[.)]\s+(.+)$/;

/** Tekst in blokken. */
export function parseBlocks(src: string): Block[] {
  const out: Block[] = [];
  let cur: Block | null = null;
  const flush = () => { if (cur) out.push(cur); cur = null; };
  for (const raw of src.replace(/\r\n?/g, "\n").split("\n")) {
    const line = raw.trimEnd();
    if (!line.trim()) { flush(); continue; }
    let m: RegExpMatchArray | null;
    if ((m = line.match(H))) { flush(); out.push({ t: "h", level: m[1].length === 1 ? 2 : 3, text: m[2].trim() }); continue; }
    const ul = line.match(UL), ol = ul ? null : line.match(OL);
    if (ul || ol) {
      const t = ul ? "ul" : "ol", text = (ul ?? ol)![1].trim();
      const c = cur as Block | null;
      if (c && c.t === t) c.items.push(text);
      else { flush(); cur = { t, items: [text] }; }
      continue;
    }
    const c = cur as Block | null;
    if (c && (c.t === "ul" || c.t === "ol")) { c.items[c.items.length - 1] += "\n" + line.trim(); continue; }
    if (c && c.t === "p") c.lines.push(line.trim());
    else { flush(); cur = { t: "p", lines: [line.trim()] }; }
  }
  flush();
  return out;
}

const LINK = /\[([^\]\n]{1,200})\]\((https:\/\/[^\s()<>"'\\`]{1,500})\)/g;
const BOLD = /\*\*(?=\S)([^*\n]{1,500}?)\*\*/g;
const A_STYLE = "color:#ffffff;text-decoration:underline";

/** Eén regel tekst naar veilige HTML: escapen, **vet**, [tekst](https://…) en losse https-links. */
export function inlineHtml(raw: string): string {
  const bold = (h: string) => h.replace(BOLD, "<strong>$1</strong>");
  let out = "", last = 0;
  // [tekst](url) apart; de stukken ertussen: escapen, losse links, vet (vet om een link heen werkt dus niet, in de linktekst wel)
  for (const m of raw.matchAll(LINK)) {
    out += bold(linkify(esc(raw.slice(last, m.index))));
    out += `<a href="${esc(m[2])}" style="${A_STYLE}">${bold(esc(m[1]))}</a>`;
    last = m.index! + m[0].length;
  }
  return out + bold(linkify(esc(raw.slice(last))));
}
/** Eén regel tekst als platte tekst: **vet** zonder sterretjes, [tekst](url) als "tekst (url)". */
export const inlineText = (raw: string) => raw.replace(LINK, "$1 ($2)").replace(BOLD, "$1");

const P = "margin:0 0 14px;font-size:15px;line-height:23px;color:#d6d6d6;word-break:break-word";
/** Tekst van de mail naar HTML (alinea's, koppen, opsommingen). */
export function bodyToHtml(src: string): string {
  return parseBlocks(src).map((b) => {
    if (b.t === "h") {
      return b.level === 2
        ? `<h2 style="margin:24px 0 10px;font-size:20px;line-height:26px;font-weight:800;color:#ffffff">${inlineHtml(b.text)}</h2>`
        : `<h3 style="margin:20px 0 8px;font-size:17px;line-height:23px;font-weight:800;color:#ffffff">${inlineHtml(b.text)}</h3>`;
    }
    if (b.t === "p") return `<p style="${P}">${b.lines.map(inlineHtml).join("<br>")}</p>`;
    const items = b.items.map((i) =>
      `<li style="margin:0 0 6px;font-size:15px;line-height:23px;color:#d6d6d6">${i.split("\n").map(inlineHtml).join("<br>")}</li>`
    ).join("");
    return `<${b.t} style="margin:0 0 14px;padding:0 0 0 22px;color:#d6d6d6">${items}</${b.t}>`;
  }).join("\n");
}
/** Tekst van de mail als platte tekst. */
export function bodyToText(src: string): string {
  return parseBlocks(src).map((b) => {
    if (b.t === "h") return inlineText(b.text).toUpperCase();
    if (b.t === "p") return b.lines.map(inlineText).join("\n");
    return b.items.map((i, n) => `${b.t === "ol" ? `${n + 1}.` : "-"} ${i.split("\n").map(inlineText).join("\n  ")}`).join("\n");
  }).join("\n\n");
}

// ---------- de mail ----------

type T = { label: string; reasonNews: string; unsub: [string, string]; reasonService: string; test: string };
export const TEXT: Record<Lang, T> = {
  nl: {
    label: "Servicebericht",
    reasonNews: "Je krijgt deze mail omdat je bent ingeschreven voor de nieuwsbrief van Bingr.",
    unsub: ["Geen nieuwsbrief meer?", "Afmelden"],
    reasonService: "Je krijgt dit servicebericht omdat je een Bingr-account hebt. Het bevat belangrijke informatie over je account of de dienst en wordt daarom ook verstuurd als je je voor de nieuwsbrief hebt afgemeld.",
    test: "[Test] ",
  },
  en: {
    label: "Service message",
    reasonNews: "You're receiving this email because you're subscribed to the Bingr newsletter.",
    unsub: ["Don't want the newsletter?", "Unsubscribe"],
    reasonService: "You're receiving this service message because you have a Bingr account. It contains important information about your account or the service, so it's sent even if you unsubscribed from the newsletter.",
    test: "[Test] ",
  },
};

export type RenderOpts = {
  lang: Lang; content: MailingContent; audience: Audience; firstName?: string;
  /** Afmeldpagina (alleen bij de doelgroep newsletter). */
  unsubscribeUrl?: string; year?: number; test?: boolean;
};

const preheaderOf = (text: string) => {
  const s = text.replace(/\s+/g, " ").trim();
  return Array.from(s).length > 140 ? Array.from(s).slice(0, 139).join("").trimEnd() + "…" : s;
};

/** De hele mail: {subject, html, text}. */
export function renderMailing(o: RenderOpts): { subject: string; html: string; text: string } {
  const t = TEXT[o.lang], c = o.content[o.lang], img = o.content.image, url = o.content.button_url;
  const subject = (o.test ? t.test : "") + c.subject;
  const service = o.audience === "service";
  const imgTag = img
    ? `<img src="${esc(img)}" width="500" alt="${esc(c.subject)}" style="display:block;width:100%;max-width:500px;height:auto;border:0;border-radius:8px;background:#1f1f1f">`
    : "";
  const content = [
    greeting(o.lang, o.firstName),
    service ? `${eyebrow(t.label)}<div style="height:8px;font-size:0;line-height:0">&nbsp;</div>` : "",
    img ? `<div style="margin:0 0 22px">${url ? `<a href="${esc(url)}" style="text-decoration:none">${imgTag}</a>` : imgTag}</div>` : "",
    title(c.subject, "0 0 6px"),
    `<div style="height:4px;width:56px;background:${RED};border-radius:2px;margin:12px 0 22px;font-size:0;line-height:0">&nbsp;</div>`,
    bodyToHtml(c.body),
    url && c.button ? button(url, c.button) : "",
  ].join("\n");
  const news = !service && o.unsubscribeUrl;
  const reasonHtml = service
    ? esc(t.reasonService)
    : esc(t.reasonNews) + (news ? `<br>${esc(t.unsub[0])} <a href="${esc(o.unsubscribeUrl)}" style="color:#b3b3b3;text-decoration:underline">${esc(t.unsub[1])}</a>` : "");
  const bodyText = bodyToText(c.body);
  const html = layout({
    lang: o.lang, docTitle: subject, preheader: preheaderOf(bodyText), label: service ? t.label : "",
    contentHtml: content, footerHtml: footerHtml({ lang: o.lang, reasonHtml, year: o.year }),
  });
  const text: string[] = [];
  const g = greetingText(o.lang, o.firstName);
  if (g) text.push(g, "");
  if (service) text.push(t.label.toUpperCase(), "");
  text.push(c.subject, "", bodyText, "");
  if (url && c.button) text.push(`${c.button}: ${url}`, "");
  text.push(footerText({ lang: o.lang, reason: service ? t.reasonService : t.reasonNews, year: o.year }));
  if (news) text.push(`${t.unsub[0]} ${t.unsub[1]}: ${o.unsubscribeUrl}`);
  return { subject, html, text: text.join("\n") };
}

// ---------- doelgroep ----------
// Zelfde regels als bingr_mailing_audience / bingr_mailing_eligible in supabase/schema.sql (getest in
// supabase/tests/mailing_test.sql); hier voor de unittests en als beschrijving.

export type AccountRow = {
  email: string | null; email_confirmed_at: string | null; deleted_at?: string | null; banned_until?: string | null;
  lang?: string | null; email_opt_out?: boolean; newsletter_opt_out?: boolean;
};
/** Hoort dit account bij de doelgroep? Nooit: geen of onbevestigd adres, verwijderd of (nu) geblokkeerd. */
export function eligible(u: AccountRow, audience: Audience, nowMs = Date.now()): boolean {
  if (!u.email || !u.email_confirmed_at || u.deleted_at) return false;
  if (u.banned_until && Date.parse(u.banned_until) > nowMs) return false;
  if (audience === "service") return true;
  return !u.email_opt_out && !u.newsletter_opt_out;
}
/** Taal van de ontvanger: nl (of leeg) -> NL-versie, al het andere -> EN (logic.ts langOf). */
export const recipientLang = (lang: unknown): Lang => langOf(lang);
/** Aantallen per taal van een lijst accounts. */
export function countAudience(rows: AccountRow[], audience: Audience, nowMs = Date.now()) {
  const r = { nl: 0, en: 0, total: 0 };
  for (const u of rows) if (eligible(u, audience, nowMs)) { r[recipientLang(u.lang)]++; r.total++; }
  return r;
}

// ---------- versturen ----------

export type Recipient = { id: string; email: string; lang: string | null; first_name: string | null };
export type Take = { items: Recipient[]; done: boolean; busy?: boolean };
export type Marks = { sent: string[]; failed: string[]; retry: string[]; release: string[] };
export type RunDeps = {
  take: (batch: number) => Promise<Take>;
  mark: (m: Marks) => Promise<void>;
  send: (u: Recipient, lang: Lang) => Promise<void>;
  now: () => number;
  temporary: (e: unknown) => boolean;
  code: (e: unknown) => string;
  pause?: () => Promise<unknown>;
};
export type RunResult = { sent: number; failed: number; retry: number; done: boolean; errors: Record<string, number> };

/** Hoeveel mails deze ronde nog mogen: per uur (`perHour` min wat het laatste uur al ging) en per ronde (`batch`). */
export function budgetOf(perHour: number, sentLastHour: number, batch: number): number {
  return Math.max(0, Math.min(batch, Math.floor(perHour) - Math.max(0, Math.floor(sentLastHour))));
}

/**
 * Eén verzendronde: batches uit de wachtrij (take claimt ze: state 'sending'), versturen, en het resultaat vastleggen
 * (mark). Een tijdelijke SMTP-fout stopt de ronde (die ontvanger later opnieuw); wat niet aan de beurt kwam gaat terug in
 * de wachtrij zonder dat het als poging telt. Nooit meer dan `budget` mails. Dubbel versturen voorkomt de database
 * (één rij per mailing en account; take geeft alleen rijen die nog 'queued' zijn).
 */
export async function runMailing(d: RunDeps, o: { budget: number; until: number; batch: number }): Promise<RunResult> {
  const r: RunResult = { sent: 0, failed: 0, retry: 0, done: false, errors: {} };
  let empty = 0;
  while (r.sent + r.failed < o.budget && d.now() < o.until) {
    const t = await d.take(Math.max(1, Math.min(o.batch, o.budget - r.sent - r.failed)));
    if (t.done) { r.done = true; return r; }
    if (!t.items.length) { if (t.busy || ++empty > 5) return r; continue; }
    const m: Marks = { sent: [], failed: [], retry: [], release: [] };
    let stop = false;
    for (const u of t.items) {
      if (stop || d.now() >= o.until || r.sent + r.failed >= o.budget) { m.release.push(u.id); stop = true; continue; }
      try {
        await d.send(u, recipientLang(u.lang));
        m.sent.push(u.id); r.sent++;
      } catch (e) {
        const c = d.code(e);
        r.errors[c] = (r.errors[c] ?? 0) + 1;
        if (d.temporary(e)) { m.retry.push(u.id); r.retry++; stop = true; } else { m.failed.push(u.id); r.failed++; }
      }
      if (d.pause) await d.pause();
    }
    await d.mark(m);
    if (stop) return r;
  }
  return r;
}

// ---------- weergave voor het beheer ----------

export type MailingRow = {
  id: number; created_at: string; finished_at: string | null; audience: string; status: string; content: Partial<MailingContent> | null;
  recipients: number; recipients_nl: number; recipients_en: number; sent: number; failed: number; skipped: number; cancelled: number;
};
const n0 = (v: unknown) => (typeof v === "number" && Number.isFinite(v) && v > 0 ? Math.floor(v) : 0);
/** Eén mailing voor het beheer: onderwerpen, doelgroep, status en aantallen (nooit adressen). */
export function mailingView(m: MailingRow, open?: number) {
  const done = n0(m.sent) + n0(m.failed) + n0(m.skipped) + n0(m.cancelled);
  return {
    id: m.id, created_at: m.created_at, finished_at: m.finished_at,
    audience: isAudience(m.audience) ? m.audience : "newsletter",
    status: ["sending", "done", "cancelled"].includes(m.status) ? m.status : "done",
    subject: { nl: String(m.content?.nl?.subject ?? ""), en: String(m.content?.en?.subject ?? "") },
    recipients: { nl: n0(m.recipients_nl), en: n0(m.recipients_en), total: n0(m.recipients) },
    sent: n0(m.sent), failed: n0(m.failed), skipped: n0(m.skipped), cancelled: n0(m.cancelled),
    left: open ?? (m.status === "sending" ? Math.max(0, n0(m.recipients) - done) : 0),
  };
}
