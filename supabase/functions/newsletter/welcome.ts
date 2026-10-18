// Bingr welkomstmail (contract docs/NEWSLETTER.md, sectie Welkomstmail): nieuwe leden krijgen hem zodra ze hun
// e-mailadres hebben bevestigd (actie welcome_cron, pg_cron elke 5 minuten). Zelfde huisstijl als de nieuwsbrief
// (_shared/layout.ts): zwart, BINGR met rode streep, kaart #141414. Pure code (geen database, geen netwerk) zodat alles
// met `deno test` te controleren is. Bingr levert geen zenders en beveelt geen bronnen of aanbieders aan: nooit een naam
// of link van een aanbieder in deze mail.
import { esc, FONT, footerHtml, footerText, greeting, greetingText, layout, RED, SUPPORT_SITE } from "../_shared/layout.ts";
import type { Lang } from "./logic.ts";

/** Bevestigd binnen zoveel dagen: daarna geen welkomstmail meer (te laat om nog "welkom" te zeggen). */
export const WELCOME_DAYS = 7;
/** Max. mails per ronde (elke 5 minuten). */
export const WELCOME_BATCH = 50;
/** Voorbeeldnaam in de aanhef van voorbeeld en weergave in het beheer (geen echt account). */
export const SAMPLE_NAME = "Alex";

export const LINKS = {
  source: `${SUPPORT_SITE}/hulp/afspeellijst/`,
  web: "https://bingr.online/web/",
  pair: "https://bingr.online/koppelen/",
  testflight: "https://testflight.apple.com/join/JW915fdA",
  android: "https://bingr.online/apk",
  support: SUPPORT_SITE,
} as const;

type Step = { title: string; body: string; button?: { label: string; url: string } };
type App = { name: string; how: string; button?: { label: string; url: string } };
type T = {
  subject: string; preheader: string; eyebrow: string; title: string; intro: string; steps: Step[]; apps: App[];
  appsTitle: string; appsBody: string; newsletter: string; unsubQ: string; unsubA: string; honest: string; reason: string;
  sampleNote: string;
};

export const WELCOME: Record<Lang, T> = {
  nl: {
    subject: "Welkom bij Bingr: zo begin je",
    preheader: "Je account is klaar. In een paar stappen kijk je op al je schermen.",
    eyebrow: "Welkom bij Bingr",
    title: "Fijn dat je er bent!",
    intro: "Je e-mailadres is bevestigd en je account is klaar. Met Bingr kijk je de zenders, films en series uit je eigen bron in één overzichtelijke app, op je telefoon, tablet, computer en tv. Zo begin je:",
    steps: [
      {
        title: "Voeg je eigen bron toe",
        body: "Gebruik de afspeellijst van je eigen aanbieder: voeg hem toe met Xtream Codes (server, gebruikersnaam en wachtwoord) of met een M3U-link. In de hulp lees je stap voor stap hoe dat gaat.",
        button: { label: "Bron toevoegen", url: LINKS.source },
      },
      {
        title: "Kijk in je browser",
        body: "Geen app nodig: log in op de webspeler en kijk meteen op je computer.",
        button: { label: "Open de webspeler", url: LINKS.web },
      },
      {
        title: "Koppel je tv",
        body: "Open Bingr op je tv en scan de QR-code met je telefoon, of ga naar bingr.online/koppelen en vul de code van je tv in. Typen met de afstandsbediening is niet nodig.",
        button: { label: "Tv koppelen", url: LINKS.pair },
      },
    ],
    appsTitle: "Download de apps",
    appsBody: "Log in met hetzelfde account; je bron staat dan ook in de app.",
    apps: [
      { name: "iPhone, iPad, Apple TV en Mac", how: "via de bèta (TestFlight)", button: { label: "Naar de bèta", url: LINKS.testflight } },
      { name: "Android, Android TV en Fire TV", how: "download de app", button: { label: "Download voor Android", url: LINKS.android } },
      { name: "Samsung TV", how: "binnenkort" },
    ],
    newsletter: "Je ontvangt ook twee keer per week (zondag en woensdag) onze nieuwsbrief met nieuwe films en series. Uitschrijven kan met één klik onderaan elke nieuwsbrief.",
    unsubQ: "Liever geen nieuwsbrief?", unsubA: "Meteen uitschrijven",
    honest: "Bingr levert zelf geen zenders, films of series. Je kijkt wat je eigen bron aanbiedt.",
    reason: "Je ontvangt deze e-mail omdat je een Bingr-account hebt aangemaakt en je e-mailadres hebt bevestigd. Deze welkomstmail krijg je één keer.",
    sampleNote: "Voorbeeld uit het beheer: de uitschrijflink werkt hier niet.",
  },
  en: {
    subject: "Welcome to Bingr: here's how to start",
    preheader: "Your account is ready. A few steps and you're watching on all your screens.",
    eyebrow: "Welcome to Bingr",
    title: "Great to have you!",
    intro: "Your email address is confirmed and your account is ready. With Bingr you watch the channels, movies and series from your own source in one clear app, on your phone, tablet, computer and TV. Here's how to start:",
    steps: [
      {
        title: "Add your own source",
        body: "Use the playlist from your own provider: add it with Xtream Codes (server, username and password) or with an M3U link. The help pages walk you through it step by step.",
        button: { label: "Add a source", url: LINKS.source },
      },
      {
        title: "Watch in your browser",
        body: "No app needed: sign in to the web player and start watching on your computer.",
        button: { label: "Open the web player", url: LINKS.web },
      },
      {
        title: "Pair your TV",
        body: "Open Bingr on your TV and scan the QR code with your phone, or go to bingr.online/koppelen and enter the code from your TV. No typing with the remote.",
        button: { label: "Pair your TV", url: LINKS.pair },
      },
    ],
    appsTitle: "Get the apps",
    appsBody: "Sign in with the same account and your source is in the app too.",
    apps: [
      { name: "iPhone, iPad, Apple TV and Mac", how: "via the beta (TestFlight)", button: { label: "Join the beta", url: LINKS.testflight } },
      { name: "Android, Android TV and Fire TV", how: "download the app", button: { label: "Download for Android", url: LINKS.android } },
      { name: "Samsung TV", how: "coming soon" },
    ],
    newsletter: "You'll also receive our newsletter with new movies and series twice a week (Sunday and Wednesday). You can unsubscribe with one click at the bottom of every newsletter.",
    unsubQ: "Rather not get the newsletter?", unsubA: "Unsubscribe now",
    honest: "Bingr doesn't provide any channels, movies or series itself. You watch what your own source offers.",
    reason: "You're receiving this email because you created a Bingr account and confirmed your email address. You'll only get this welcome email once.",
    sampleNote: "Preview from the admin: the unsubscribe link doesn't work here.",
  },
};

/** Stap 4 en 5 (apps en hulp) horen bij de genummerde lijst, maar hebben een eigen opbouw. */
const HELP: Record<Lang, Step> = {
  nl: { title: "Hulp nodig?", body: "Op support.bingr.online vind je antwoorden op veelgestelde vragen en kun je ons een vraag stellen.", button: { label: "Naar support", url: LINKS.support } },
  en: { title: "Need help?", body: "On support.bingr.online you'll find answers to common questions and you can ask us anything.", button: { label: "Go to support", url: LINKS.support } },
};

// ---------- HTML ----------

function btn(label: string, url: string, primary: boolean) {
  const bg = primary ? RED : "#2a2a2a";
  return `<table role="presentation" cellpadding="0" cellspacing="0" border="0" style="margin:12px 0 0"><tr><td bgcolor="${bg}" style="border-radius:6px;background:${bg}">` +
    `<a href="${esc(url)}" style="display:inline-block;padding:10px 18px;font-family:${FONT};font-size:14px;font-weight:700;line-height:18px;color:#ffffff;text-decoration:none;border-radius:6px">${esc(label)}</a></td></tr></table>`;
}
function num(n: number) {
  return `<td width="30" valign="top" style="width:30px;padding:2px 14px 0 0"><table role="presentation" cellpadding="0" cellspacing="0" border="0"><tr>` +
    `<td width="30" height="30" align="center" valign="middle" bgcolor="${RED}" style="width:30px;height:30px;border-radius:15px;background:${RED};font-family:${FONT};font-size:15px;line-height:30px;font-weight:800;color:#ffffff">${n}</td></tr></table></td>`;
}
function stepRow(n: number, title: string, inner: string, last = false) {
  return `<tr>${num(n)}<td valign="top" style="padding:0 0 ${last ? 4 : 22}px;${last ? "" : "border-bottom:1px solid #222222;"}">` +
    `<div style="font-size:17px;line-height:23px;font-weight:800;color:#ffffff">${esc(title)}</div>${inner}</td></tr>` +
    (last ? "" : `<tr><td colspan="2" style="height:20px;font-size:0;line-height:0">&nbsp;</td></tr>`);
}
const p = (s: string) => `<p style="margin:6px 0 0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(s)}</p>`;

function appsHtml(lang: Lang) {
  const t = WELCOME[lang];
  const rows = t.apps.map((a) => `<tr><td valign="middle" style="padding:10px 12px 10px 0;border-top:1px solid #222222">` +
    `<div style="font-size:14px;line-height:20px;font-weight:700;color:#ffffff">${esc(a.name)}</div>` +
    `<div style="font-size:13px;line-height:18px;color:${a.button ? "#8c8c8c" : RED};font-weight:${a.button ? 400 : 700}">${esc(a.how)}</div></td>` +
    `<td align="right" valign="middle" style="padding:10px 0;border-top:1px solid #222222">${a.button
      ? `<a href="${esc(a.button.url)}" style="display:inline-block;padding:8px 14px;background:#2a2a2a;border-radius:6px;font-family:${FONT};font-size:13px;font-weight:700;line-height:17px;color:#ffffff;text-decoration:none;white-space:nowrap">${esc(a.button.label)}</a>`
      : ""}</td></tr>`).join("");
  return `${p(t.appsBody)}<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:12px 0 0">${rows}</table>`;
}

export type WelcomeOpts = {
  lang: Lang;
  firstName?: string;
  /** Uitschrijflink voor de nieuwsbrief (bingr.online/unsubscribe/?k=news&t=…). */
  unsubscribeUrl: string;
  /** Alinea over de nieuwsbrief tonen (alleen als de nieuwsbrief aan staat en het lid ingeschreven is). */
  newsletter?: boolean;
  year?: number;
  preview?: boolean;
};

export const welcomeSubject = (lang: Lang, preview = false) => (preview ? "[Voorbeeld] " : "") + WELCOME[lang].subject;

/** De hele welkomstmail: {subject, html, text}. */
export function renderWelcome(o: WelcomeOpts): { subject: string; html: string; text: string } {
  const t = WELCOME[o.lang], help = HELP[o.lang];
  const rows = [
    ...t.steps.map((s, i) => stepRow(i + 1, s.title, p(s.body) + (s.button ? btn(s.button.label, s.button.url, i === 0) : ""))),
    stepRow(t.steps.length + 1, t.appsTitle, appsHtml(o.lang)),
    stepRow(t.steps.length + 2, help.title, p(help.body) + btn(help.button!.label, help.button!.url, false), true),
  ];
  const news = o.newsletter === false ? "" :
    `<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:26px 0 0"><tr>` +
    `<td bgcolor="#1f1f1f" style="background:#1f1f1f;border-left:3px solid ${RED};border-radius:8px;padding:16px 18px">` +
    `<div style="font-size:14px;line-height:21px;color:#e6e6e6">${esc(t.newsletter)}</div>` +
    `<div style="margin:8px 0 0;font-size:13px;line-height:19px;color:#b3b3b3">${esc(t.unsubQ)} <a href="${esc(o.unsubscribeUrl)}" style="color:#ffffff;text-decoration:underline">${esc(t.unsubA)}</a></div>` +
    `</td></tr></table>`;
  const content = `${greeting(o.lang, o.firstName)}<div style="font-size:12px;line-height:16px;font-weight:700;letter-spacing:1.2px;text-transform:uppercase;color:#8c8c8c">${esc(t.eyebrow)}</div>
<h1 style="margin:8px 0 10px;font-size:24px;line-height:30px;font-weight:800;color:#ffffff">${esc(t.title)}</h1>
<p style="margin:0;font-size:15px;line-height:23px;color:#d6d6d6">${esc(t.intro)}</p>
<div style="height:4px;width:56px;background:${RED};border-radius:2px;margin:20px 0 24px;font-size:0;line-height:0">&nbsp;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0">${rows.join("\n")}</table>
${news}
<p style="margin:20px 0 0;padding:14px 16px;background:#1f1f1f;border-radius:8px;font-size:13px;line-height:19px;color:#b3b3b3">${esc(t.honest)}</p>`;
  const reasonHtml = esc(t.reason) + (o.preview ? `<br><span style="color:#5c5c5c">${esc(t.sampleNote)}</span>` : "");
  const subject = welcomeSubject(o.lang, o.preview);
  const html = layout({ lang: o.lang, docTitle: subject, preheader: t.preheader, label: "", contentHtml: content, footerHtml: footerHtml({ lang: o.lang, reasonHtml, year: o.year }) });
  return { subject, html, text: welcomeText(o) };
}

/** Platte-tekstversie. */
export function welcomeText(o: WelcomeOpts): string {
  const t = WELCOME[o.lang], help = HELP[o.lang], out: string[] = [];
  const g = greetingText(o.lang, o.firstName);
  if (g) out.push(g, "");
  out.push(t.title, "", t.intro, "");
  t.steps.forEach((s, i) => out.push(`${i + 1}. ${s.title}`, s.body, ...(s.button ? [`${s.button.label}: ${s.button.url}`] : []), ""));
  out.push(`${t.steps.length + 1}. ${t.appsTitle}`, t.appsBody, ...t.apps.map((a) => `- ${a.name}: ${a.how}${a.button ? ` (${a.button.url})` : ""}`), "");
  out.push(`${t.steps.length + 2}. ${help.title}`, help.body, `${help.button!.label}: ${help.button!.url}`, "");
  if (o.newsletter !== false) out.push(t.newsletter, `${t.unsubQ} ${t.unsubA}: ${o.unsubscribeUrl}`, "");
  out.push(t.honest, "", footerText({ lang: o.lang, reason: t.reason, year: o.year }));
  if (o.preview) out.push(t.sampleNote);
  return out.join("\n");
}

// ---------- selectie (zelfde regels als bingr_welcome_take in supabase/schema.sql) ----------

export type WelcomeCandidate = {
  email: string | null;
  email_confirmed_at: string | null;
  banned_until?: string | null;
  deleted_at?: string | null;
  /** Er is al een rij in account_welcome (verstuurd, mislukt, bezig of bij de eerste uitrol als "bestaand" gemarkeerd). */
  has_row: boolean;
};

/** Krijgt dit account (nu) een welkomstmail? Bevestigd binnen WELCOME_DAYS dagen, niet geblokkeerd/verwijderd, nog geen rij. */
export function welcomeEligible(u: WelcomeCandidate, nowMs: number): boolean {
  if (u.has_row || !u.email || u.deleted_at) return false;
  const c = u.email_confirmed_at ? Date.parse(u.email_confirmed_at) : NaN;
  if (!Number.isFinite(c) || c > nowMs || c <= nowMs - WELCOME_DAYS * 86400_000) return false;
  const b = u.banned_until ? Date.parse(u.banned_until) : NaN;
  return !(Number.isFinite(b) && b > nowMs);
}

/**
 * Eerste uitrol: welke accounts worden als "al verstuurd" gemarkeerd (error = 'existing', sent_at leeg)? Alle accounts met
 * een bevestigd adres op dat moment, ook die van de laatste 7 dagen: oude leden krijgen nooit een welkomstmail.
 */
export function initialMarks(users: { id: string; email_confirmed_at: string | null }[]): string[] {
  return users.filter((u) => !!u.email_confirmed_at).map((u) => u.id);
}

/** Nieuwsbriefalinea in de welkomstmail alleen als de nieuwsbrief aan staat en het lid ingeschreven is. */
export const showNewsletter = (enabled: boolean, subscribed: boolean) => enabled && subscribed;
