// Supporttickets per e-mail: wat doen we met een binnengekomen mail in support@? Pure functies (geen database, geen
// netwerk), getest in inbox_test.ts. De functie support (index.ts, actie poll_inbox) haalt de mails op via IMAP,
// zoekt de tickets erbij en voert de beslissing uit.
//
//   1. eigen mail van het systeem (kopregel X-Bingr-Ticket, bv. de melding "Reactie van klant")  -> negeren, laten staan
//   2. automatisch (afwezigheidsmelding, bounce, nieuwsbrief, mailinglijst, spam)               -> negeren, laten staan
//   3. SPF/DKIM/DMARC afgekeurd door de ontvangende server (Authentication-Results)             -> weigeren, laten staan
//   4. afzender = support@ of een adres uit BINGR_SUPPORT_AGENTS:
//        build 95: alleen met een geldige DKIM-handtekening van het domein van de afzender, volgens de BOVENSTE
//        Authentication-Results (die zet onze eigen ontvangende server erboven; lagere kopregels kan de afzender zelf
//        meesturen). Zonder die controle (vervalste afzender): nooit als support, alleen als klant van een eigen ticket,
//        anders weigeren (agent_unverified).
//        ticket gevonden -> antwoord van support: in het ticket en als gebrande mail naar de klant
//        geen ticket     -> weigeren, laten staan
//   5. ticket gevonden (onderwerp "[#1007]", of In-Reply-To/References van een ticketmail):
//        afzender = e-mailadres van het ticket -> reactie van de klant (gesloten ticket: nieuw vervolgticket)
//        ander adres, maar antwoord op een van onze mails met een willekeurige Message-ID (niet te raden)
//                                              -> reactie in dat ticket (build 140)
//        ander adres, alleen nummer/root-ID    -> nieuw ticket met een verwijzing naar dat ticket (build 140; vroeger
//                                                 geweigerd en blijven liggen)
//   6. geen ticket: nieuw ticket uit de mail (met limieten), met bevestigingsmail aan de afzender.
// "Laten staan" = niet als gelezen gemarkeerd en niet verplaatst; verwerkte mails worden gelezen en (als die map bestaat)
// naar Bingr-verwerkt verplaatst.
// Build 140: elke ronde gaan ALLE mails in INBOX zonder het trefwoord $BingrDone langs (ook gelezen of oude mails; vroeger
// alleen mails boven de laatst geziene UID en ongelezen mails van de laatste 7 dagen, waardoor mails die al gelezen waren
// nooit een ticket werden). Na een definitieve beslissing krijgt de mail $BingrDone (en het logboek per UIDVALIDITY/UID
// als vangnet als de server geen trefwoorden toestaat); dubbel importeren is uitgesloten op Message-ID.
import { cleanText, LIMITS, type Lang, type Status } from "./logic.ts";
import { type ParsedMail, stripReply } from "./mime.ts";

export const DONE_FOLDER = "Bingr-verwerkt";
export const MAX_FETCH_BYTES = 2 * 1024 * 1024;

/** strong = gevonden via een opgeslagen Message-ID van ons met een willekeurig deel (<bingr-ticket-1007.xyz@…>, niet te raden). */
export type TicketLite = { number: number; email: string; status: Status; lang: Lang; strong?: boolean };
export type Decision =
  | { kind: "customer_reply"; ticket: TicketLite; otherSender?: boolean }
  | { kind: "agent_reply"; ticket: TicketLite }
  | { kind: "new_ticket"; followUp: number | null; related?: number }
  | { kind: "ignore"; reason: "own_system" | "auto" | "bulk" | "bounce" | "spam" }
  | { kind: "reject"; reason: "no_sender" | "auth_failed" | "agent_no_ticket" | "agent_unverified" };

const lc = (s: string) => s.trim().toLowerCase();

/** Ticketnummer uit het onderwerp: eerst "[#1007]", anders "#1007" (los, minstens 3 cijfers). */
export function numberFromSubject(subject: string): number | null {
  const m = /\[#(\d{1,12})\]/.exec(subject) ?? /(?:^|[\s(:\[])#(\d{3,12})\b/.exec(subject);
  return m ? Number(m[1]) : null;
}
/** Ticketnummers uit In-Reply-To/References (onze Message-ID's: <bingr-ticket-1007…@bingr.online>). */
export function numbersFromIds(ids: string[]): number[] {
  const out: number[] = [];
  for (const id of ids) {
    const m = /^<bingr-ticket-(\d{1,12})[.@]/i.exec(id);
    if (m && !out.includes(Number(m[1]))) out.push(Number(m[1]));
  }
  return out;
}
/** Kandidaat-ticketnummers in volgorde van zekerheid: kopregels (antwoord op onze mail), dan het onderwerp. */
export function candidateNumbers(mail: ParsedMail): number[] {
  const out = numbersFromIds([...mail.inReplyTo, ...[...mail.references].reverse()]);
  const s = numberFromSubject(mail.subject);
  if (s && !out.includes(s)) out.push(s);
  return out.slice(0, 5);
}
/** Message-ID's waarnaar de mail verwijst (om ook op opgeslagen Message-ID's te zoeken). */
export const referencedIds = (mail: ParsedMail) => [...new Set([...mail.inReplyTo, ...mail.references])].slice(-20);

/** Door ons verstuurd (melding aan support@, of een kopie): kopregel X-Bingr-Ticket. */
export const isOwnSystem = (mail: ParsedMail) => !!mail.header("x-bingr-ticket");

const AUTO_SUBJECT = /^(automatisch antwoord|automatic reply|auto(matic)?[- ]?reply|autoreply|auto:|out of (the )?office|afwezig|abwesenheit|r[ée]ponse automatique|respuesta autom[áa]tica|risposta automatica|undeliverable|onbestelbaar|niet bezorgd|delivery status notification|mail delivery (failed|failure|system)|returned mail|delivery failure|failure notice|undelivered mail)/i;
const AUTO_SENDER = /^(mailer-daemon|postmaster|no-?reply|do-?not-?reply|donotreply|noreply-[^@]*|bounces?(\+[^@]*)?|mail-?daemon)@/i;
/** Automatische mail (afwezig, bounce, nieuwsbrief) of spam: reden, anders null. */
export function automatedReason(mail: ParsedMail): "auto" | "bulk" | "bounce" | "spam" | null {
  const h = mail.header;
  const as = lc(h("auto-submitted"));
  if (as && as !== "no") return "auto";
  if (/^(bulk|junk|list|auto_reply)$/.test(lc(h("precedence")))) return lc(h("precedence")) === "auto_reply" ? "auto" : "bulk";
  if (h("x-autoreply") || h("x-autorespond") || h("x-autogenerated") || lc(h("x-auto-response")) === "yes") return "auto";
  if (/autoreply|oof/i.test(h("x-ms-exchange-generated-message-source"))) return "auto";
  if (mail.contentType === "multipart/report" || /^<\s*>$/.test(h("return-path").trim())) return "bounce";
  if (mail.from && AUTO_SENDER.test(mail.from.address)) return mail.from.address.startsWith("mailer") || mail.from.address.startsWith("postmaster") ? "bounce" : "auto";
  if (AUTO_SUBJECT.test(mail.subject.replace(/^\s*(re|fw|fwd|aw|wg|antw)\s*:\s*/i, ""))) return "auto";
  if (h("list-id") || h("list-unsubscribe")) return "bulk";
  if (/^yes\b/i.test(h("x-spam-flag")) || /^yes\b/i.test(h("x-spam-status"))) return "spam";
  return null;
}

/** De ontvangende mailserver heeft de afzender afgekeurd (bovenste Authentication-Results: dmarc=fail, of spf=fail zonder dkim=pass). */
export function authFailed(mail: ParsedMail): boolean {
  const ar = lc(mail.header("authentication-results"));
  if (!ar) return false;
  if (/\bdmarc=fail\b/.test(ar)) return true;
  return /\bspf=fail\b/.test(ar) && !/\bdkim=pass\b/.test(ar);
}

// ---- build 95: DKIM van de afzender, volgens onze eigen ontvangende server ----
/** Bovenste Authentication-Results (RFC 8601): authserv-id en de resultaten (zonder commentaar tussen haakjes). */
export function topAuthResults(mail: ParsedMail): { authserv: string; results: string[] } | null {
  const first = mail.headers.find(([k]) => k === "authentication-results");
  if (!first) return null;
  let v = first[1], prev = "";
  while (v !== prev) { prev = v; v = v.replace(/\([^()]*\)/g, " "); } // commentaar (ook genest) weg
  const parts = v.split(";").map((x) => x.trim()).filter(Boolean);
  const authserv = lc((parts.shift() ?? "").split(/\s+/)[0] ?? "");
  return authserv ? { authserv, results: parts.map(lc) } : null;
}
/** Domeinen waarvoor de bovenste Authentication-Results dkim=pass meldt (header.d, of het domein van header.i). */
export function dkimPassDomains(mail: ParsedMail): string[] {
  const ar = topAuthResults(mail);
  if (!ar) return [];
  const out: string[] = [];
  for (const r of ar.results) {
    if (!/^dkim\s*=\s*pass\b/.test(r)) continue;
    const d = /\bheader\.d\s*=\s*"?([a-z0-9.-]+)/.exec(r)?.[1] ?? /\bheader\.i\s*=\s*"?[^@\s;"]*@([a-z0-9.-]+)/.exec(r)?.[1];
    if (d) out.push(d.replace(/\.$/, ""));
  }
  return [...new Set(out)];
}
/** Namen waaronder onze ontvangende server zijn Authentication-Results schrijft: BINGR_SUPPORT_AUTHSERV (komma's) als dat
 *  gezet is, anders afgeleid van de IMAP-host (de host zelf en zijn bovenliggende domein: imap.hoster.nl -> hoster.nl, dan
 *  telt ook mx2.hoster.nl). Leeg = onbekend: dan geldt alleen dat het de bovenste kopregel is. */
export function authservNames(imapHost: string, configured = ""): string[] {
  const list = configured.split(/[\s,;]+/).map(lc).filter(Boolean);
  if (list.length) return [...new Set(list)];
  const h = lc(imapHost).replace(/\.$/, "");
  if (!h || !h.includes(".") || /^[\d.]+$/.test(h)) return [];
  const labels = h.split(".");
  return [...new Set([h, labels.length > 2 ? labels.slice(1).join(".") : h])];
}
const authservOk = (id: string, names: string[]) => !names.length || names.some((n) => id === n || id.endsWith("." + n));
/** Afzender echt van zijn domein: de bovenste Authentication-Results komt van onze server (authserv-id) en meldt
 *  dkim=pass met header.d (of header.i) gelijk aan het domein van From. */
export function senderVerified(mail: ParsedMail, authserv: string[] = []): boolean {
  const from = mail.from?.address ? lc(mail.from.address) : "";
  const domain = from.includes("@") ? from.slice(from.lastIndexOf("@") + 1) : "";
  if (!domain) return false;
  const ar = topAuthResults(mail);
  if (!ar || !authservOk(ar.authserv, authserv)) return false;
  return dkimPassDomains(mail).includes(domain);
}

/** Adressen die als support mogen antwoorden: support@ zelf (en de IMAP-login) plus BINGR_SUPPORT_AGENTS (komma's/spaties). */
export function agentList(own: string[], agentsSecret: string): string[] {
  const list = [...own, ...agentsSecret.split(/[\s,;]+/)].map(lc).filter((a) => /^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(a));
  return [...new Set(list)];
}

/** Beslissing voor één mail. `tickets` = de gevonden tickets bij candidateNumbers/referencedIds, in volgorde.
 *  `authserv` = namen van onze ontvangende server (authservNames); leeg = alleen de bovenste kopregel telt. */
export function decide(mail: ParsedMail, tickets: TicketLite[], agents: string[], authserv: string[] = []): Decision {
  if (isOwnSystem(mail)) return { kind: "ignore", reason: "own_system" };
  const auto = automatedReason(mail);
  if (auto) return { kind: "ignore", reason: auto };
  const from = mail.from?.address ? lc(mail.from.address) : "";
  if (!from || !from.includes("@")) return { kind: "reject", reason: "no_sender" };
  if (authFailed(mail)) return { kind: "reject", reason: "auth_failed" };
  if (agents.includes(from)) {
    // een agent die zelf ook klant is van een ticket: als klant (zijn eigen ticket), anders als support
    const own = tickets.find((t) => lc(t.email) === from);
    if (own && own.status !== "closed") return { kind: "customer_reply", ticket: own };
    // build 95: als support alleen met DKIM van het eigen domein (anders kon iedereen met een vervalste afzender
    // support@ namens Bingr een gebrande mail naar een klant laten sturen)
    if (!senderVerified(mail, authserv)) return { kind: "reject", reason: "agent_unverified" };
    return tickets[0] ? { kind: "agent_reply", ticket: tickets[0] } : { kind: "reject", reason: "agent_no_ticket" };
  }
  const mine = tickets.find((t) => lc(t.email) === from);
  if (mine) return mine.status === "closed" ? { kind: "new_ticket", followUp: mine.number } : { kind: "customer_reply", ticket: mine };
  // build 140: ander adres (bv. een alias of doorgestuurd). Antwoord op een van onze mails met een niet te raden Message-ID:
  // in dat ticket; anders (alleen een nummer in het onderwerp, dat kan iedereen typen) een nieuw ticket met een verwijzing.
  const strong = tickets.find((t) => t.strong && t.status !== "closed");
  if (strong) return { kind: "customer_reply", ticket: strong, otherSender: true };
  if (tickets.length) return { kind: "new_ticket", followUp: null, related: tickets[0].number };
  return { kind: "new_ticket", followUp: null };
}

const NOTE: Record<Lang, (n: string) => string> = {
  nl: (n) => `(bijlage niet overgenomen: ${n})`,
  en: (n) => `(attachment not included: ${n})`,
};
const CUT: Record<Lang, string> = { nl: "… (ingekort)", en: "… (shortened)" };
/** Tekst voor het ticket: nieuw deel van de mail, met een regel per bijlage; null = niets bruikbaars. */
export function messageBody(mail: ParsedMail, lang: Lang): string | null {
  let text = cleanText(stripReply(mail.text), 100000, true);
  const notes = mail.attachments.slice(0, 20).map((a) => NOTE[lang](a.filename));
  if (mail.attachments.length > 20) notes.push(NOTE[lang](`+${mail.attachments.length - 20}`));
  if (!text && !notes.length) return null;
  const tail = notes.length ? (text ? "\n\n" : "") + notes.join("\n") : "";
  const room = LIMITS.message - tail.length;
  if (text.length > room) text = text.slice(0, Math.max(0, room - CUT[lang].length - 1)).replace(/\s+\S*$/, "") + "\n" + CUT[lang];
  return (text + tail).slice(0, LIMITS.message);
}

/** Onderwerp zonder Re:/Fwd:/[#1007]-voorvoegsels, voor een nieuw ticket uit een mail. */
export function cleanSubject(subject: string, lang: Lang): string {
  let s = subject;
  for (let i = 0; i < 5; i++) {
    const t = s.replace(/^\s*((re|fw|fwd|aw|wg|antw|tr|sv|vs|rif|doorst)(\[\d+\])?\s*:|\[#?\d+\])\s*/i, "");
    if (t === s) break;
    s = t;
  }
  s = cleanText(s, LIMITS.subject);
  return s.length >= LIMITS.minSubject ? s : lang === "en" ? "(no subject)" : "(geen onderwerp)";
}

/** Naam van de afzender, anders het deel voor de @. */
export function senderName(mail: ParsedMail): string {
  const n = cleanText(mail.from?.name ?? "", LIMITS.name);
  return n && !n.includes("@") ? n : cleanText((mail.from?.address ?? "").split("@")[0], LIMITS.name);
}

const NL_WORDS = new Set("de het een ik je jij niet en van is wat hoe mijn werkt bij voor met op dat dit er naar kan geen ook maar wel hallo hoi groet groeten bedankt alvast graag".split(" "));
const EN_WORDS = new Set("the a an i you not and of is what how my works work with for on that this there to can no also but hello hi regards thanks thank please doesn't does".split(" "));
/** Taal van een nieuwe mail: Content-Language, anders een simpele woordtelling (gelijk: Nederlands). */
export function guessLang(mail: ParsedMail, text: string): Lang {
  const cl = lc(mail.header("content-language"));
  if (cl.startsWith("en")) return "en";
  if (cl.startsWith("nl")) return "nl";
  let nl = 0, en = 0;
  for (const w of `${mail.subject} ${text}`.toLowerCase().split(/[^a-z']+/).slice(0, 400)) {
    if (NL_WORDS.has(w)) nl++;
    if (EN_WORDS.has(w)) en++;
  }
  return en > nl * 1.3 && en >= 3 ? "en" : "nl";
}

export const FOLLOW_UP: Record<Lang, (n: number) => string> = {
  nl: (n) => `(Vervolg op gesloten ticket #${n})`,
  en: (n) => `(Follow-up to closed ticket #${n})`,
};
export const RELATED: Record<Lang, (n: number) => string> = {
  nl: (n) => `(Verwijst naar ticket #${n}, maar komt van een ander e-mailadres)`,
  en: (n) => `(Refers to ticket #${n}, but comes from a different email address)`,
};
export const OTHER_SENDER: Record<Lang, string> = {
  nl: "(Via e-mail vanaf een ander adres dan dat van het ticket)",
  en: "(By email from a different address than the ticket's)",
};

// ---- build 140: welke mails komen aan de beurt ----
/** IMAP-trefwoord voor mails waarover een definitieve beslissing is genomen (verwerkt, genegeerd of geweigerd). */
export const DONE_KEYWORD = "$BingrDone";
/** Mag dit trefwoord gezet worden (PERMANENTFLAGS met \* of het trefwoord zelf)? Zonder PERMANENTFLAGS: nee. */
export const keywordAllowed = (permanentFlags: string[] | null) =>
  !!permanentFlags && permanentFlags.some((f) => f === "\\*" || f.toLowerCase() === DONE_KEYWORD.toLowerCase());
/** Definitief = niet opnieuw proberen. Opnieuw: fouten (behalve na 3 pogingen) en de limiet per afzender (na een uur). */
export const isFinal = (result: string) => !(result === "error" || result.startsWith("error:retry") || result === "rejected:rate_limited");
/** Wachtrij: kandidaten (UID's zonder $BingrDone) min de UID's die volgens het logboek al definitief zijn, oudste eerst. */
export function pickQueue(candidates: number[], doneInLog: Iterable<number>, max: number): { queue: number[]; pending: number } {
  const done = new Set(doneInLog);
  const todo = [...new Set(candidates)].filter((u) => u > 0 && !done.has(u)).sort((a, b) => a - b);
  return { queue: todo.slice(0, Math.max(0, max)), pending: todo.length };
}
/** Plusmap van de mailtest (support+ci-…@ komt bij de hoster in INBOX.ci-…): alleen een geldig ci-label. */
export const CI_TAG = /^ci-[a-z0-9]{6,24}$/;
export function findCiFolder(list: { name: string; delim: string | null; flags: string[] }[], tag: string): string | null {
  if (!CI_TAG.test(tag)) return null;
  return list.find((b) => !b.flags.some((f) => /\\noselect|\\nonexistent/i.test(f)) &&
    lc(b.delim ? b.name.split(b.delim).pop() ?? "" : b.name) === tag)?.name ?? null;
}

/** Datum voor IMAP SEARCH SINCE: 7-Oct-2026. */
export function imapDate(d: Date): string {
  const M = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];
  return `${d.getUTCDate()}-${M[d.getUTCMonth()]}-${d.getUTCFullYear()}`;
}

/** De map voor verwerkte mails (ook als INBOX.Bingr-verwerkt of INBOX/Bingr-verwerkt), of null als hij niet bestaat. */
export function findFolder(list: { name: string; delim: string | null; flags: string[] }[], wanted = DONE_FOLDER): string | null {
  const w = lc(wanted);
  const hit = list.find((b) => !b.flags.some((f) => /\\noselect|\\nonexistent/i.test(f)) &&
    (lc(b.name) === w || (b.delim ? lc(b.name.split(b.delim).pop() ?? "") === w : false)));
  return hit?.name ?? null;
}
