// Supporttickets: e-mails in de huisstijl van Bingr (zelfde opbouw als supabase/templates en de berichten uit het
// beheer: zwart, logo met rode balk, kaart #141414 met rode rand). Tabellen met inline stijlen voor Gmail, Outlook en
// Apple Mail, plus een platte-tekstversie. Alles wat de klant of het beheer typt gaat door esc().
import {
  CATEGORY_LABEL, type Lang, PLATFORM_LABEL, STATUS_ADMIN, STATUS_COLOR, STATUS_LABEL, type Status, ticketLabel,
} from "./logic.ts";

export type MailKind =
  | "customer_created" // klant: we hebben je vraag ontvangen
  | "customer_reply" // klant: nieuw antwoord van support
  | "customer_status" // klant: opgelost / gesloten
  | "support_created" // support@: nieuw ticket
  | "support_reply" // support@: klant heeft gereageerd
  | "support_closed"; // support@: klant heeft het ticket gesloten

export type MailData = {
  kind: MailKind;
  lang: Lang; // taal van de klant (support@-mails zijn altijd Nederlands)
  number: number;
  subject: string;
  status: Status;
  body?: string; // het bericht (van klant of support)
  url: string; // knop: ticket op support.bingr.online (klant) of in het beheer (support@)
  customerUrl?: string; // support@: link naar de klantweergave
  name?: string;
  email?: string;
  category?: string;
  platform?: string | null;
  appVersion?: string | null;
  hasAccount?: boolean;
  createdAt?: string;
};

const SITE = "https://bingr.online";
const SUPPORT_SITE = "https://support.bingr.online";
const FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";

export const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
// alleen https-links klikbaar maken, ná het escapen (dus nooit eigen HTML van de afzender)
const linkify = (s: string) =>
  s.replace(/https:\/\/[^\s<"']+[^\s<"'.,;:!?)]/g, (u) => `<a href="${u}" style="color:#ffffff;text-decoration:underline">${u}</a>`);
const unesc = (s: string) => s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&");
/** Tekst van een bericht naar veilige HTML: escapen, links, alinea's en regeleinden. */
export function bodyHtml(text: string, color = "#e6e6e6") {
  return String(text ?? "").split(/\n{2,}/).map((p) =>
    `<p style="margin:0 0 14px;font-size:15px;line-height:23px;color:${color};word-break:break-word">${linkify(esc(p)).replace(/\n/g, "<br>")}</p>`
  ).join("");
}

type T = Record<string, string>;
const TXT: Record<Lang, T> = {
  nl: {
    ticket: "Supportticket", status: "Status", category: "Categorie", platform: "Platform", version: "App-versie",
    yourMsg: "Jouw bericht", reply: "Antwoord van Bingr Support", view: "Bekijk je ticket", viewReply: "Bekijk en beantwoord",
    copy: "Werkt de knop niet? Kopieer deze link:",
    foot: "Je ontvangt deze e-mail omdat je een supportticket hebt aangemaakt bij Bingr.",
    footReply: "Reageren? Gebruik de knop hierboven, dan komt je antwoord direct bij je ticket.",
    created_h: "We hebben je vraag ontvangen",
    created_p: "Bedankt voor je bericht. Je ticket is aangemaakt en we reageren zo snel mogelijk, meestal binnen één werkdag. Bewaar deze e-mail: met de knop hieronder bekijk je je ticket en kun je reageren.",
    reply_h: "Nieuw antwoord op je ticket",
    reply_p: "Bingr Support heeft gereageerd op je ticket.",
    resolved_h: "Je ticket is opgelost",
    resolved_p: "We hebben je ticket als opgelost gemarkeerd. Is je vraag toch nog niet beantwoord? Reageer dan via de knop hieronder; je ticket gaat dan weer open.",
    closed_h: "Je ticket is gesloten",
    closed_p: "Je ticket is gesloten. Heb je een nieuwe vraag? Maak dan een nieuw ticket aan op support.bingr.online.",
    open_h: "De status van je ticket is gewijzigd", open_p: "De status van je ticket is bijgewerkt.",
  },
  en: {
    ticket: "Support ticket", status: "Status", category: "Category", platform: "Platform", version: "App version",
    yourMsg: "Your message", reply: "Reply from Bingr Support", view: "View your ticket", viewReply: "View and reply",
    copy: "Button not working? Copy this link:",
    foot: "You're receiving this email because you created a support ticket with Bingr.",
    footReply: "Want to reply? Use the button above so your answer goes straight to your ticket.",
    created_h: "We've received your request",
    created_p: "Thanks for your message. Your ticket has been created and we'll get back to you as soon as possible, usually within one business day. Keep this email: use the button below to view your ticket and reply.",
    reply_h: "New reply to your ticket",
    reply_p: "Bingr Support has replied to your ticket.",
    resolved_h: "Your ticket has been resolved",
    resolved_p: "We've marked your ticket as resolved. Still need help? Reply using the button below and your ticket will reopen.",
    closed_h: "Your ticket has been closed",
    closed_p: "Your ticket has been closed. Got a new question? Create a new ticket at support.bingr.online.",
    open_h: "Your ticket status has changed", open_p: "The status of your ticket has been updated.",
  },
};

export function subjectFor(d: MailData): string {
  const n = `[${ticketLabel(d.number)}]`;
  const s = d.subject.replace(/[\r\n]+/g, " ").slice(0, 120);
  const nl = d.lang === "nl";
  switch (d.kind) {
    case "customer_created": return `${n} ${nl ? "We hebben je vraag ontvangen" : "We've received your request"}: ${s}`;
    case "customer_reply": return `${n} ${nl ? "Nieuw antwoord" : "New reply"}: ${s}`;
    case "customer_status": return `${n} ${STATUS_LABEL[d.lang][d.status]}: ${s}`;
    case "support_created": return `${n} Nieuw ticket: ${s}`;
    case "support_reply": return `${n} Reactie van klant: ${s}`;
    case "support_closed": return `${n} Gesloten door klant: ${s}`;
  }
}

function badge(status: Status, label: string) {
  const c = STATUS_COLOR[status];
  return `<span style="display:inline-block;font-size:12px;line-height:18px;font-weight:700;letter-spacing:.3px;color:#ffffff;background:${c};border-radius:999px;padding:3px 11px;white-space:nowrap">${esc(label)}</span>`;
}
function button(url: string, label: string) {
  // tabel-knop: werkt ook in Outlook (geen padding op <a>)
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:26px 0 0"><tr><td align="center" bgcolor="#E50914" style="border-radius:6px;background:#E50914">
<a href="${esc(url)}" style="display:inline-block;padding:14px 30px;font-family:${FONT};font-size:16px;font-weight:700;line-height:20px;color:#ffffff;text-decoration:none;border-radius:6px">${esc(label)}</a></td></tr></table>`;
}
function metaRows(rows: [string, string][]) {
  const r = rows.filter(([, v]) => v).map(([k, v]) =>
    `<tr><td style="padding:5px 16px 5px 0;font-size:13px;line-height:19px;color:#8c8c8c;white-space:nowrap;vertical-align:top">${esc(k)}</td><td style="padding:5px 0;font-size:13px;line-height:19px;color:#ffffff;word-break:break-word">${v}</td></tr>`
  ).join("");
  return r ? `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:18px 0 0;border-top:1px solid #2a2a2a;padding-top:8px">${r}</table>` : "";
}
function messageBox(label: string, text: string, accent: string) {
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:24px 0 0"><tr>
<td style="background:#1f1f1f;border-left:3px solid ${accent};border-radius:8px;padding:18px 20px 6px">
<div style="font-size:12px;line-height:16px;font-weight:700;letter-spacing:.6px;text-transform:uppercase;color:#a3a3a3;margin:0 0 10px">${esc(label)}</div>
${bodyHtml(text)}</td></tr></table>`;
}

/** De complete e-mail: {subject, html, text}. */
export function renderMail(d: MailData): { subject: string; html: string; text: string } {
  const toSupport = d.kind.startsWith("support_");
  const lang: Lang = toSupport ? "nl" : d.lang;
  const t = TXT[lang];
  const num = ticketLabel(d.number);
  const statusLabel = toSupport ? STATUS_ADMIN[d.status] : STATUS_LABEL[lang][d.status];
  const cat = d.category ? (CATEGORY_LABEL[lang][d.category] ?? d.category) : "";
  const plat = d.platform ? (PLATFORM_LABEL[d.platform] ?? d.platform) : "";

  let heading = "", intro = "", boxLabel = "", accent = "#E50914", btn = t.view;
  switch (d.kind) {
    case "customer_created": heading = t.created_h; intro = t.created_p; boxLabel = t.yourMsg; accent = "#5a5a5a"; break;
    case "customer_reply": heading = t.reply_h; intro = t.reply_p; boxLabel = t.reply; btn = t.viewReply; break;
    case "customer_status":
      heading = d.status === "resolved" ? t.resolved_h : d.status === "closed" ? t.closed_h : t.open_h;
      intro = d.status === "resolved" ? t.resolved_p : d.status === "closed" ? t.closed_p : t.open_p;
      break;
    case "support_created": heading = "Nieuw supportticket"; intro = `${d.name || d.email || "Een klant"} heeft een ticket aangemaakt.`; boxLabel = "Bericht van de klant"; accent = "#5a5a5a"; btn = "Openen in beheer"; break;
    case "support_reply": heading = "Nieuwe reactie van de klant"; intro = `${d.name || d.email || "De klant"} heeft gereageerd op het ticket.`; boxLabel = "Reactie van de klant"; accent = "#5a5a5a"; btn = "Openen in beheer"; break;
    case "support_closed": heading = "Ticket gesloten door de klant"; intro = `${d.name || d.email || "De klant"} heeft het ticket zelf gesloten.`; btn = "Openen in beheer"; break;
  }

  const meta: [string, string][] = toSupport
    ? [
      ["Klant", `${esc(d.name || "—")} &lt;<a href="mailto:${esc(d.email)}" style="color:#ffffff">${esc(d.email)}</a>&gt;`],
      ["Bingr-account", d.hasAccount ? "Ja (ingelogd)" : "Nee / niet ingelogd"],
      ["Categorie", esc(cat)], ["Platform", esc(plat)], ["App-versie", esc(d.appVersion ?? "")],
      ["Taal", d.lang === "en" ? "Engels" : "Nederlands"],
    ]
    : [[t.category, esc(cat)], [t.platform, esc(plat)], [t.version, esc(d.appVersion ?? "")]];

  const card = `
<div style="font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:#8c8c8c">${esc(t.ticket)}</div>
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:6px 0 0"><tr>
<td style="font-size:34px;line-height:40px;font-weight:900;letter-spacing:-.5px;color:#ffffff;vertical-align:middle">${esc(num)}</td>
<td align="right" style="vertical-align:middle">${badge(d.status, statusLabel)}</td></tr></table>
<div style="font-size:17px;line-height:24px;font-weight:700;color:#ffffff;margin:6px 0 0;word-break:break-word">${esc(d.subject)}</div>
<div style="height:4px;width:56px;background:#E50914;border-radius:2px;margin:18px 0 22px;font-size:0;line-height:0">&nbsp;</div>
<h1 style="margin:0 0 10px;font-size:24px;line-height:30px;font-weight:800;color:#ffffff">${esc(heading)}</h1>
<p style="margin:0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(intro)}</p>
${d.body ? messageBox(boxLabel, d.body, accent) : ""}
${button(d.url, btn)}
${metaRows(meta)}
<p style="margin:22px 0 0;font-size:12px;line-height:18px;color:#8c8c8c">${esc(t.copy)}<br><a href="${esc(d.url)}" style="color:#b3b3b3;word-break:break-all">${esc(d.url)}</a></p>
${toSupport && d.customerUrl ? `<p style="margin:10px 0 0;font-size:12px;line-height:18px;color:#8c8c8c">Klantweergave: <a href="${esc(d.customerUrl)}" style="color:#b3b3b3;word-break:break-all">${esc(d.customerUrl)}</a></p>` : ""}`;

  const foot = toSupport
    ? `Melding van het supportsysteem van Bingr. Antwoord je met "Beantwoorden", dan gaat je mail naar de klant maar komt hij niet in het ticket; antwoord liever in het beheer.`
    : `${esc(t.foot)} ${esc(t.footReply)}`;

  const html = `<!doctype html>
<html lang="${lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><meta name="supported-color-schemes" content="dark"><title>${esc(num)} · Bingr Support</title></head>
<body style="margin:0;padding:0;background:#000000">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:#000000">${esc(num)} · ${esc(heading)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="background:#000000"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;font-family:${FONT}">
<tr><td style="padding:0 4px 24px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
<td style="vertical-align:middle;width:56px"><img src="${SITE}/apple-touch-icon.png" width="44" height="44" alt="" style="display:block;border-radius:10px"></td>
<td style="vertical-align:middle"><div style="font-size:30px;font-weight:900;letter-spacing:1px;color:#ffffff;line-height:30px">BINGR</div><div style="height:4px;width:74px;background:#E50914;border-radius:2px;margin-top:6px;font-size:0;line-height:0">&nbsp;</div></td>
<td align="right" style="vertical-align:middle;font-size:14px;font-weight:700;color:#bdbdbd;letter-spacing:.3px">Support</td>
</tr></table></td></tr>
<tr><td style="background:#141414;border-radius:12px;padding:32px 30px 30px;border-top:4px solid #E50914">${card}
</td></tr>
<tr><td style="padding:24px 8px 0;font-size:12px;line-height:18px;color:#737373;text-align:center">${foot}<br><br>
<a href="${SITE}" style="color:#b3b3b3;text-decoration:none;font-weight:700">bingr.online</a> &nbsp;·&nbsp; <a href="${SUPPORT_SITE}" style="color:#b3b3b3;text-decoration:none;font-weight:700">support.bingr.online</a> &nbsp;·&nbsp; <a href="${SITE}/privacy.html" style="color:#737373">Privacy</a><br>
<span style="color:#5c5c5c">© Bingr</span></td></tr>
</table></td></tr></table></body></html>`;

  const lines: string[] = ["BINGR Support", "", `${t.ticket} ${num} · ${statusLabel}`, d.subject, "", heading, intro];
  if (d.body) lines.push("", `--- ${boxLabel} ---`, d.body, "---");
  lines.push("", `${btn}: ${d.url}`);
  if (toSupport && d.customerUrl) lines.push(`Klantweergave: ${d.customerUrl}`);
  const metaText = meta.filter(([, v]) => v).map(([k, v]) => `${k}: ${unesc(v.replace(/<[^>]+>/g, ""))}`);
  if (metaText.length) lines.push("", ...metaText);
  lines.push("", "—", toSupport ? "Melding van het supportsysteem van Bingr." : `${t.foot} ${t.footReply}`, "bingr.online · support.bingr.online");
  return { subject: subjectFor(d), html, text: lines.join("\n") };
}
