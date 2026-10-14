// Supporttickets: e-mails in de huisstijl van Bingr (gedeelde opbouw in ../_shared/layout.ts, net als de accountmails uit
// supabase/templates en de berichten uit het beheer: zwart, logo met rode balk, kaart #141414 met rode rand). Tabellen met
// inline stijlen voor Gmail, Outlook en Apple Mail, plus een platte-tekstversie. Alles wat de klant of het beheer typt gaat door esc().
import { REPLY_MARKER } from "./mime.ts";
import {
  bodyHtml, button, copyLink, detailRows, esc, eyebrow, footerHtml, footerText, layout, messageBox, redBar, title, unesc,
} from "../_shared/layout.ts";
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
  deviceName?: string | null;
  osVersion?: string | null;
  hasAccount?: boolean;
  createdAt?: string;
  // antwoorden per e-mail komen in het ticket (IMAP-import staat aan): markeringsregel bovenaan en andere voettekst
  replyByMail?: boolean;
};

export { bodyHtml, esc };

type T = Record<string, string>;
const TXT: Record<Lang, T> = {
  nl: {
    ticket: "Supportticket", status: "Status", category: "Categorie", platform: "Platform", version: "App-versie",
    yourMsg: "Jouw bericht", reply: "Antwoord van Bingr Support", view: "Bekijk je ticket", viewReply: "Bekijk en beantwoord",
    foot: "Je ontvangt deze e-mail omdat je een supportticket hebt aangemaakt bij Bingr.",
    footReply: "Reageren? Gebruik de knop hierboven, dan komt je antwoord direct bij je ticket.",
    footMail: "Reageren? Beantwoord deze e-mail of gebruik de knop hierboven; je antwoord komt direct bij je ticket.",
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
    foot: "You're receiving this email because you created a support ticket with Bingr.",
    footReply: "Want to reply? Use the button above so your answer goes straight to your ticket.",
    footMail: "Want to reply? Just reply to this email or use the button above; your answer goes straight to your ticket.",
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
      ["Categorie", esc(cat)], ["Platform", esc(plat)], ["Apparaat", esc([d.deviceName, d.osVersion].filter(Boolean).join(" · "))],
      ["App-versie", esc(d.appVersion ?? "")],
      ["Taal", d.lang === "en" ? "Engels" : "Nederlands"],
    ]
    : [[t.category, esc(cat)], [t.platform, esc(plat)], [t.version, esc(d.appVersion ?? "")]];

  const card = `
${eyebrow(t.ticket)}
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:6px 0 0"><tr>
<td style="font-size:34px;line-height:40px;font-weight:900;letter-spacing:-.5px;color:#ffffff;vertical-align:middle">${esc(num)}</td>
<td align="right" style="vertical-align:middle">${badge(d.status, statusLabel)}</td></tr></table>
<div style="font-size:17px;line-height:24px;font-weight:700;color:#ffffff;margin:6px 0 0;word-break:break-word">${esc(d.subject)}</div>
${redBar()}
${title(heading)}
<p style="margin:0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(intro)}</p>
${d.body ? messageBox(boxLabel, d.body, accent) : ""}
${button(d.url, btn)}
${detailRows(meta)}
${copyLink(lang, d.url)}
${toSupport && d.customerUrl ? `<p style="margin:10px 0 0;font-size:12px;line-height:18px;color:#8c8c8c">Klantweergave: <a href="${esc(d.customerUrl)}" style="color:#b3b3b3;word-break:break-all">${esc(d.customerUrl)}</a></p>` : ""}`;

  const footReply = d.replyByMail ? t.footMail : t.footReply;
  const supportFoot = d.replyByMail
    ? `Melding van het supportsysteem van Bingr. Antwoord je met "Beantwoorden" (vanaf support@ of een adres uit BINGR_SUPPORT_AGENTS), dan komt je antwoord in het ticket en mailt het systeem het naar de klant. Schrijf boven de lijn bovenaan.`
    : `Melding van het supportsysteem van Bingr. Antwoord je met "Beantwoorden", dan gaat je mail naar de klant maar komt hij niet in het ticket; antwoord liever in het beheer.`;
  const foot = toSupport ? supportFoot : `${t.foot} ${footReply}`;

  const html = layout({
    lang, docTitle: `${num} · Bingr Support`, preheader: `${num} · ${heading}`, label: "Support",
    // markeringsregel: alles daaronder is citaat (zo knipt de inbox-import een antwoord betrouwbaar af)
    markerText: d.replyByMail ? REPLY_MARKER : undefined,
    contentHtml: card, footerHtml: footerHtml({ lang, reasonHtml: esc(foot) }),
  });

  const lines: string[] = [...(d.replyByMail ? [REPLY_MARKER, ""] : []), "BINGR Support", "", `${t.ticket} ${num} · ${statusLabel}`, d.subject, "", heading, intro];
  if (d.body) lines.push("", `--- ${boxLabel} ---`, d.body, "---");
  lines.push("", `${btn}: ${d.url}`);
  if (toSupport && d.customerUrl) lines.push(`Klantweergave: ${d.customerUrl}`);
  const metaText = meta.filter(([, v]) => v).map(([k, v]) => `${k}: ${unesc(v.replace(/<[^>]+>/g, ""))}`);
  if (metaText.length) lines.push("", ...metaText);
  lines.push("", footerText({ lang, reason: foot }));
  return { subject: subjectFor(d), html, text: lines.join("\n") };
}
