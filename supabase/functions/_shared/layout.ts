// Gedeelde huisstijl voor alle e-mails van Bingr: accountmails (supabase/templates, gebouwd door build.ts), supporttickets
// (functie support), berichten uit het beheer (functie admin in LRvdLinden/bingr-beheer). Dit bestand staat in
// LRvdLinden/iptv-ios-appletv en als kopie in LRvdLinden/bingr-beheer; houd ze gelijk (net als mail.ts).
// Opbouw: zwart, logo + BINGR met rode balk, kaart #141414 met rode rand, titel, rode knop, details, voettekst.
// Tabellen met inline stijlen (Gmail, Outlook, Apple Mail) en altijd een platte-tekstversie. Geen afhankelijkheden.
// Alles wat iemand typt (klant, beheer) gaat door esc(); de *Html-parameters zijn al veilige HTML.

export type Lang = "nl" | "en";

export const SITE = "https://bingr.online";
export const SUPPORT_SITE = "https://support.bingr.online";
export const PRIVACY_URL = `${SITE}/privacy.html`;
export const RED = "#E50914";
export const FONT = "-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,Helvetica,Arial,sans-serif";

export const esc = (s: unknown) =>
  String(s ?? "").replace(/[&<>"']/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[c]!));
// alleen https-links klikbaar maken, ná het escapen (dus nooit eigen HTML van de afzender)
export const linkify = (s: string) =>
  s.replace(/https:\/\/[^\s<"']+[^\s<"'.,;:!?)]/g, (u) => `<a href="${u}" style="color:#ffffff;text-decoration:underline">${u}</a>`);
export const unesc = (s: string) =>
  s.replace(/&lt;/g, "<").replace(/&gt;/g, ">").replace(/&quot;/g, '"').replace(/&#39;/g, "'").replace(/&amp;/g, "&");

/** Tekst van een bericht naar veilige HTML: escapen, links, alinea's en regeleinden. */
export function bodyHtml(text: string, color = "#e6e6e6", size = 15) {
  const lh = size >= 16 ? 25 : 23;
  return String(text ?? "").split(/\n{2,}/).map((p) =>
    `<p style="margin:0 0 14px;font-size:${size}px;line-height:${lh}px;color:${color};word-break:break-word">${linkify(esc(p)).replace(/\n/g, "<br>")}</p>`
  ).join("");
}

// ---- aanhef: "Hoi <voornaam>," / "Hi <first name>," ----
// De voornaam staat in user_metadata.first_name (apps en sites bij het aanmaken van een account, of het beheer).
// Zonder (bruikbare) naam geen aanhef: de mail blijft dan zoals hij was.

/** Max. lengte van voor- en achternaam (gelijk aan de apps, de sites en de trigger bingr_user_names in schema.sql). */
export const NAME_MAX = 50;
/** Voor- of achternaam opschonen zoals de apps en sites dat doen: stuurtekens en < > weg, witruimte samengevoegd,
 *  getrimd, max. NAME_MAX tekens. Een naam met een link of e-mailadres ("://", "www.", "@") telt niet: "". */
export function personName(s: unknown): string {
  if (typeof s !== "string") return "";
  const v = s.replace(/[\u0000-\u001f\u007f<>]/g, "").replace(/\s+/g, " ").trim();
  const n = Array.from(v).slice(0, NAME_MAX).join("").trim();
  return /:\/\/|www\.|@/i.test(n) ? "" : n;
}
/** Voornaam van een Supabase-gebruiker (user.user_metadata.first_name) of uit user_metadata zelf; "" als onbekend. */
export function firstNameOf(u: unknown): string {
  if (!u || typeof u !== "object") return "";
  const o = u as Record<string, unknown>;
  const meta = o.user_metadata ?? o.raw_user_meta_data ?? o;
  return meta && typeof meta === "object" ? personName((meta as Record<string, unknown>).first_name) : "";
}
/** "Hoi" / "Hi". */
export const GREETING: Record<Lang, string> = { nl: "Hoi", en: "Hi" };
/** Aanhef als platte tekst ("Hoi Léon,"); zonder naam "". */
export function greetingText(lang: Lang, firstName?: string) {
  const n = personName(firstName);
  return n ? `${GREETING[lang] ?? GREETING.en} ${n},` : "";
}
/** Alinea met de aanhef; inner is al veilige HTML (bv. met {{ .Data.first_name }} in een accountmail). */
export const greetingPara = (innerHtml: string) =>
  `<p style="margin:0 0 12px;font-size:15px;line-height:23px;font-weight:600;color:#ffffff">${innerHtml}</p>`;
/** Aanhef als HTML-alinea (ge-escaped); zonder naam "". */
export function greeting(lang: Lang, firstName?: string) {
  const g = greetingText(lang, firstName);
  return g ? greetingPara(esc(g)) : "";
}

// ---- bouwstenen voor de kaart ----

/** Kleine kopregel in hoofdletters boven de titel (bv. "Supportticket", "Account"). */
export const eyebrow = (text: string) =>
  `<div style="font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:#8c8c8c">${esc(text)}</div>`;
/** Korte rode balk onder de kop. */
export const redBar = (margin = "18px 0 22px") =>
  `<div style="height:4px;width:56px;background:${RED};border-radius:2px;margin:${margin};font-size:0;line-height:0">&nbsp;</div>`;
/** Grote titel van de mail. */
export const title = (text: string, margin = "0 0 10px") =>
  `<h1 style="margin:${margin};font-size:24px;line-height:30px;font-weight:800;color:#ffffff">${esc(text)}</h1>`;
/** Alinea; html = true als de tekst al veilige HTML is (bv. met een Go-templatevariabele). */
export const para = (text: string, html = false) =>
  `<p style="margin:0;font-size:15px;line-height:23px;color:#d6d6d6">${html ? text : esc(text)}</p>`;
/** Kleinere grijze opmerking onder de knop. */
export const note = (text: string, html = false) =>
  `<p style="margin:22px 0 0;font-size:14px;line-height:21px;color:#b3b3b3">${html ? text : esc(text)}</p>`;

/** Rode knop als tabel (werkt ook in Outlook: geen padding op <a>). */
export function button(url: string, label: string) {
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:26px 0 0"><tr><td align="center" bgcolor="${RED}" style="border-radius:6px;background:${RED}">
<a href="${esc(url)}" style="display:inline-block;padding:14px 30px;font-family:${FONT};font-size:16px;font-weight:700;line-height:20px;color:#ffffff;text-decoration:none;border-radius:6px">${esc(label)}</a></td></tr></table>`;
}

/** Code in een groot vak (verificatiecode). codeHtml is al veilige HTML (bv. {{ .Token }}). */
export const codeBox = (codeHtml: string) =>
  `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:24px 0 0"><tr>
<td align="center" bgcolor="#1f1f1f" style="background:#1f1f1f;border:1px solid #2a2a2a;border-radius:8px;padding:18px 10px 18px 18px;font-family:${FONT};font-size:34px;line-height:40px;font-weight:800;letter-spacing:8px;color:#ffffff">${codeHtml}</td></tr></table>`;

/** Detailblok met een grijze rand bovenaan; waarden zijn al veilige HTML, lege rijen vallen weg. */
export function detailRows(rows: [string, string][]) {
  const r = rows.filter(([, v]) => v).map(([k, v]) =>
    `<tr><td width="1%" style="width:1%;padding:5px 24px 5px 0;font-size:13px;line-height:19px;color:#8c8c8c;white-space:nowrap;vertical-align:top">${esc(k)}</td><td style="padding:5px 0;font-size:13px;line-height:19px;color:#ffffff;word-break:break-word">${v}</td></tr>`
  ).join("");
  return r ? `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:22px 0 0;border-top:1px solid #2a2a2a;padding-top:8px">${r}</table>` : "";
}

/** Bericht in een vak met gekleurde rand links en een label erboven. */
export function messageBox(label: string, text: string, accent = RED) {
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:24px 0 0"><tr>
<td bgcolor="#1f1f1f" style="background:#1f1f1f;border-left:3px solid ${accent};border-radius:8px;padding:18px 20px 6px">
${label ? `<div style="font-size:12px;line-height:16px;font-weight:700;letter-spacing:.6px;text-transform:uppercase;color:#a3a3a3;margin:0 0 10px">${esc(label)}</div>\n` : ""}${bodyHtml(text)}</td></tr></table>`;
}

const COPY: Record<Lang, string> = { nl: "Werkt de knop niet? Kopieer deze link:", en: "Button not working? Copy this link:" };
/** "Werkt de knop niet?" met de link uitgeschreven. */
export const copyLink = (lang: Lang, url: string) =>
  `<p style="margin:22px 0 0;font-size:12px;line-height:18px;color:#8c8c8c">${esc(COPY[lang])}<br><a href="${esc(url)}" style="color:#b3b3b3;word-break:break-all">${esc(url)}</a></p>`;

// ---- voettekst ----

export type FooterOpts = {
  lang: Lang;
  /** Waarom ontvang je deze mail (en wat te doen als jij het niet was); al veilige HTML. */
  reasonHtml: string;
  /** Afmeldlink (alleen bij berichten/nieuws, nooit bij account- of supportmails). */
  unsubscribeUrl?: string;
  /** Jaar voor ©; standaard het huidige jaar. */
  year?: number;
};
const UNSUB: Record<Lang, [string, string]> = {
  nl: ["Geen berichten meer per e-mail?", "Afmelden"],
  en: ["Don't want these emails?", "Unsubscribe"],
};

/** Voettekst onder de kaart: reden, eventueel afmelden, vaste links en ©. */
export function footerHtml(o: FooterOpts) {
  const unsub = o.unsubscribeUrl
    ? `<br>${esc(UNSUB[o.lang][0])} <a href="${esc(o.unsubscribeUrl)}" style="color:#b3b3b3;text-decoration:underline">${esc(UNSUB[o.lang][1])}</a>`
    : "";
  return `${o.reasonHtml}${unsub}<br><br>
<a href="${SITE}" style="color:#b3b3b3;text-decoration:none;font-weight:700">bingr.online</a> &nbsp;·&nbsp; <a href="${SUPPORT_SITE}" style="color:#b3b3b3;text-decoration:none;font-weight:700">support.bingr.online</a> &nbsp;·&nbsp; <a href="${PRIVACY_URL}" style="color:#737373">Privacy</a><br>
<span style="color:#5c5c5c">© ${o.year ?? new Date().getFullYear()} Bingr</span>`;
}

/** Dezelfde voettekst als platte tekst. */
export function footerText(o: { lang: Lang; reason: string; unsubscribeUrl?: string; year?: number }) {
  return [
    "—", o.reason,
    ...(o.unsubscribeUrl ? [`${UNSUB[o.lang][0]} ${UNSUB[o.lang][1]}: ${o.unsubscribeUrl}`] : []),
    `bingr.online · support.bingr.online · Privacy: ${PRIVACY_URL}`,
    `© ${o.year ?? new Date().getFullYear()} Bingr`,
  ].join("\n");
}

// ---- de hele mail ----

export type LayoutOpts = {
  lang: Lang;
  /** <title> en voorbeeldregel in de inbox (onzichtbaar in de mail zelf). */
  docTitle: string;
  preheader: string;
  /** Label rechts in de kop (bv. "Support", "Account"); leeg = geen label. */
  label?: string;
  /** Inhoud van de kaart (veilige HTML). */
  contentHtml: string;
  /** Inhoud van de voettekst, meestal footerHtml(…). */
  footerHtml: string;
  /** Regel helemaal bovenaan (bv. de markeringsregel voor antwoorden per mail). */
  markerText?: string;
};

/** De complete HTML-mail in de huisstijl van Bingr. */
export function layout(o: LayoutOpts) {
  const marker = o.markerText
    ? `<tr><td style="padding:0 4px 14px;font-size:11px;line-height:14px;color:#5c5c5c;font-family:${FONT}">${esc(o.markerText)}</td></tr>\n`
    : "";
  const label = o.label
    ? `<td align="right" style="vertical-align:middle;font-size:14px;font-weight:700;color:#bdbdbd;letter-spacing:.3px">${esc(o.label)}</td>`
    : "";
  return `<!doctype html>
<html lang="${o.lang}"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1"><meta name="color-scheme" content="dark"><meta name="supported-color-schemes" content="dark"><title>${esc(o.docTitle)}</title></head>
<body style="margin:0;padding:0;background:#000000">
<div style="display:none;max-height:0;overflow:hidden;opacity:0;color:#000000">${esc(o.preheader)}</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="#000000" style="background:#000000"><tr><td align="center" style="padding:32px 16px">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;font-family:${FONT}">
${marker}<tr><td style="padding:0 4px 24px"><table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0"><tr>
<td style="vertical-align:middle;width:56px"><img src="${SITE}/apple-touch-icon.png" width="44" height="44" alt="" style="display:block;border-radius:10px"></td>
<td style="vertical-align:middle"><div style="font-size:30px;font-weight:900;letter-spacing:1px;color:#ffffff;line-height:30px">BINGR</div><div style="height:4px;width:74px;background:${RED};border-radius:2px;margin-top:6px;font-size:0;line-height:0">&nbsp;</div></td>
${label}
</tr></table></td></tr>
<tr><td bgcolor="#141414" style="background:#141414;border-radius:12px;padding:32px 30px 30px;border-top:4px solid ${RED}">${o.contentHtml}
</td></tr>
<tr><td style="padding:24px 8px 0;font-size:12px;line-height:18px;color:#737373;text-align:center">${o.footerHtml}</td></tr>
</table></td></tr></table></body></html>`;
}
