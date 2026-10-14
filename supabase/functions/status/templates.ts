// Bingr-status: e-mails aan abonnees (bevestigen, storing/onderhoud, afgemeld) in de gedeelde huisstijl (../_shared/layout.ts).
// Puur: geeft {subject, html, text} terug; versturen gebeurt in index.ts. Alles wat het beheer typt gaat door esc().
import {
  bodyHtml, button, copyLink, detailRows, esc, eyebrow, footerHtml, footerText, layout, note, para, redBar, SITE, title,
} from "../_shared/layout.ts";
import { type CompImpact, LABELS, type Lang, type NoticeStatus, type PublicNotice } from "./notices.ts";

export const STATUS_URL = `${SITE}/status/`;
export const noticeUrl = (id: number) => `${SITE}/status/incident/?id=${id}`;
export const confirmUrl = (token: string) => `${SITE}/status/?confirm=${encodeURIComponent(token)}`;
export const unsubscribeUrl = (token: string) => `${SITE}/status/?unsubscribe=${encodeURIComponent(token)}`;

const COLOR: Record<string, string> = {
  investigating: "#E50914", identified: "#f5a524", monitoring: "#3b82f6", resolved: "#2e9e57",
  scheduled: "#3b82f6", in_progress: "#3b82f6", completed: "#2e9e57", cancelled: "#5a5a5a",
};
const COMP_COLOR: Record<CompImpact, string> = { degraded: "#f5a524", partial: "#ff7a1a", major: "#ff3b46", maintenance: "#3b82f6" };

function badge(status: NoticeStatus, lang: Lang) {
  return `<span style="display:inline-block;font-size:12px;line-height:18px;font-weight:700;letter-spacing:.3px;color:#ffffff;background:${COLOR[status] ?? "#5a5a5a"};border-radius:999px;padding:3px 11px;white-space:nowrap">${esc(LABELS[lang].status[status] ?? status)}</span>`;
}

function fmt(iso: string, lang: Lang) {
  return new Date(iso).toLocaleString(lang === "nl" ? "nl-NL" : "en-GB", {
    timeZone: "Europe/Amsterdam", weekday: "short", day: "numeric", month: "long", hour: "2-digit", minute: "2-digit", timeZoneName: "short",
  });
}

const T = {
  nl: {
    reason: `Je ontvangt deze e-mail omdat je je met dit adres hebt aangemeld voor statusupdates van Bingr op <a href="${STATUS_URL}" style="color:#b3b3b3">bingr.online/status</a>.`,
    reasonTxt: "Je ontvangt deze e-mail omdat je je met dit adres hebt aangemeld voor statusupdates van Bingr op bingr.online/status.",
    reasonConfirm: "Je ontvangt deze e-mail omdat iemand dit adres heeft opgegeven op bingr.online/status. Was jij dat niet? Dan hoef je niets te doen: zonder bevestiging sturen we niets.",
    confirmEyebrow: "Statusupdates", confirmTitle: "Bevestig je aanmelding",
    confirmText: "Bevestig dat je e-mails wilt ontvangen als er een storing is bij Bingr of als er onderhoud gepland staat. Je kunt je altijd weer afmelden.",
    confirmBtn: "Aanmelding bevestigen", confirmNote: "De link werkt 7 dagen.",
    view: "Bekijk op de statuspagina", latest: "Laatste update", comps: "Getroffen onderdelen", window: "Gepland", start: "Begonnen", end: "Opgelost",
    label: "Status",
  },
  en: {
    reason: `You're receiving this email because you subscribed to Bingr status updates at <a href="${STATUS_URL}" style="color:#b3b3b3">bingr.online/status</a>.`,
    reasonTxt: "You're receiving this email because you subscribed to Bingr status updates at bingr.online/status.",
    reasonConfirm: "You're receiving this email because someone entered this address at bingr.online/status. Wasn't you? No need to do anything: we won't send anything without confirmation.",
    confirmEyebrow: "Status updates", confirmTitle: "Confirm your subscription",
    confirmText: "Confirm that you'd like to receive emails when Bingr has an incident or when maintenance is scheduled. You can unsubscribe at any time.",
    confirmBtn: "Confirm subscription", confirmNote: "The link is valid for 7 days.",
    view: "View on the status page", latest: "Latest update", comps: "Affected components", window: "Scheduled", start: "Started", end: "Resolved",
    label: "Status",
  },
};

export interface Rendered { subject: string; html: string; text: string }

/** Bevestigingsmail (dubbele opt-in). */
export function renderConfirm(lang: Lang, token: string): Rendered {
  const t = T[lang], url = confirmUrl(token);
  const html = layout({
    lang, docTitle: `${t.confirmTitle} · Bingr`, preheader: t.confirmText, label: t.label,
    contentHtml: `${eyebrow(t.confirmEyebrow)}${redBar("14px 0 22px")}${title(t.confirmTitle)}${para(t.confirmText)}${button(url, t.confirmBtn)}${note(t.confirmNote)}${copyLink(lang, url)}`,
    footerHtml: footerHtml({ lang, reasonHtml: esc(t.reasonConfirm) }),
  });
  const text = ["BINGR Status", "", t.confirmTitle, "", t.confirmText, "", `${t.confirmBtn}: ${url}`, t.confirmNote, "", footerText({ lang, reason: t.reasonConfirm })].join("\n");
  return { subject: lang === "nl" ? "Bevestig je aanmelding voor statusupdates van Bingr" : "Confirm your Bingr status updates subscription", html, text };
}

/**
 * Melding aan een abonnee: storing of onderhoud met de nieuwste update bovenaan, de status, getroffen onderdelen en
 * het tijdvak. `n.updates` is nieuwste eerst (zoals publicNotice).
 */
export function renderNotice(n: PublicNotice, lang: Lang, names: Map<string, { nl: string; en: string }>, token: string): Rendered {
  const t = T[lang], L = LABELS[lang];
  const ttl = n.title[lang] || n.title.nl;
  const latest = n.updates[0];
  const st = latest?.status ?? n.status;
  const url = noticeUrl(n.id), unsub = unsubscribeUrl(token);
  const comps = n.components.map((c) => {
    const nm = names.get(c.id)?.[lang] ?? c.id;
    const imp = n.kind === "maintenance" ? "maintenance" : c.impact;
    return `<span style="display:inline-block;margin:0 6px 6px 0;padding:3px 10px;border-radius:999px;background:#1f1f1f;border:1px solid #2a2a2a;font-size:12px;line-height:18px;color:#ffffff;white-space:nowrap"><span style="display:inline-block;width:8px;height:8px;border-radius:4px;background:${COMP_COLOR[imp as CompImpact]};margin-right:6px"></span>${esc(nm)}</span>`;
  }).join("");
  const rows: [string, string][] = [];
  if (n.kind === "maintenance" && n.window_start && n.window_end) rows.push([t.window, `${esc(fmt(n.window_start, lang))} –<br>${esc(fmt(n.window_end, lang))}`]);
  else {
    rows.push([t.start, esc(fmt(n.started_at, lang))]);
    if (n.resolved_at && n.status === "resolved") rows.push([t.end, esc(fmt(n.resolved_at, lang))]);
  }
  if (comps) rows.push([t.comps, comps]);
  const older = n.updates.slice(1, 4).map((u) =>
    `<tr><td style="padding:10px 0 0;border-top:1px solid #2a2a2a;font-size:13px;line-height:19px;color:#b3b3b3"><b style="color:#ffffff">${esc(L.status[u.status] ?? u.status)}</b> · ${esc(fmt(u.at, lang))}<br>${esc(u.body[lang] || u.body.nl)}</td></tr>`
  ).join("");
  const accent = COLOR[st] ?? "#E50914";
  const content = `${eyebrow(L.kind[n.kind])}
<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:8px 0 0"><tr>
<td style="font-size:22px;line-height:29px;font-weight:800;color:#ffffff;vertical-align:top;word-break:break-word">${esc(ttl)}</td>
<td align="right" style="vertical-align:top;padding-left:12px">${badge(st, lang)}</td></tr></table>
${redBar("16px 0 4px")}
${latest ? `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:20px 0 0"><tr>
<td bgcolor="#1f1f1f" style="background:#1f1f1f;border-left:3px solid ${accent};border-radius:8px;padding:16px 20px 4px">
<div style="font-size:12px;line-height:16px;font-weight:700;letter-spacing:.6px;text-transform:uppercase;color:#a3a3a3;margin:0 0 10px">${esc(t.latest)} · ${esc(fmt(latest.at, lang))}</div>
${bodyHtml(latest.body[lang] || latest.body.nl)}</td></tr></table>` : ""}
${older ? `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:16px 0 0">${older}</table>` : ""}
${button(url, t.view)}
${detailRows(rows)}`;
  const html = layout({
    lang, docTitle: `${ttl} · Bingr Status`, preheader: `${L.status[st] ?? st}: ${latest?.body[lang] ?? ttl}`.slice(0, 140), label: t.label,
    contentHtml: content, footerHtml: footerHtml({ lang, reasonHtml: t.reason, unsubscribeUrl: unsub }),
  });
  const text = [
    "BINGR Status", "", `${L.kind[n.kind]}: ${ttl}`, `${L.status[st] ?? st}`, "",
    ...(latest ? [`${t.latest} (${fmt(latest.at, lang)}):`, latest.body[lang] || latest.body.nl, ""] : []),
    ...n.updates.slice(1, 4).map((u) => `${L.status[u.status] ?? u.status} (${fmt(u.at, lang)}): ${u.body[lang] || u.body.nl}`),
    ...(n.components.length ? ["", `${t.comps}: ${n.components.map((c) => names.get(c.id)?.[lang] ?? c.id).join(", ")}`] : []),
    "", `${t.view}: ${url}`, "", footerText({ lang, reason: t.reasonTxt, unsubscribeUrl: unsub }),
  ].join("\n");
  const prefix = n.kind === "maintenance" ? (lang === "nl" ? "Onderhoud" : "Maintenance") : (lang === "nl" ? "Storing" : "Incident");
  return { subject: `[Bingr ${prefix}] ${L.status[st] ?? st}: ${ttl}`.slice(0, 160), html, text };
}
