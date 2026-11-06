// Build 167: mail "Bingr wordt Lifetime" en de herinnering 7 dagen vóór de overgang (contract in docs/ACCOUNT.md,
// "Build 167: alleen Lifetime" → "Mail"). Huisstijl van _shared/layout.ts. Pure code (getest in lifetime_test.ts).
// Dienstmelding over een wijziging van de voorwaarden: geen reclame, geen afmeldlink, ook zonder nieuwsbrief-opt-in.
// Noemt nooit Apple of de App Store (de code is korting op de website).
import {
  button, copyLink, esc, eyebrow, footerHtml, footerText, greeting, greetingText, layout, para, RED, redBar, SITE, SUPPORT_SITE, title,
} from "../_shared/layout.ts";
import { formatAmount } from "../_shared/billing.ts";
import { PRICE_CENTS, PRICE_CURRENCY } from "../_shared/plans.ts";
import { priceAfter } from "../_shared/lifetime.ts";

export type Lang = "nl" | "en";
export type MailKind = "notice" | "remind";
export type MailInput = {
  kind: MailKind; lang: Lang; code: string; validUntil: string; cutoverAt: string; discountPct: number;
  firstName?: string; year?: number; test?: boolean;
};
export const SAMPLE_CODE = "BINGR-ABCD-EFGH";
export const upgradeUrl = (code: string) => `${SITE}/upgrade/?code=${encodeURIComponent(code)}`;

const TZ = "Europe/Amsterdam";
/** "7 december 2026" / "7 December 2026" (Amsterdamse tijd). */
export function dateText(isoTime: string, lang: Lang, minusMs = 0): string {
  const d = new Date(Date.parse(isoTime) - minusMs);
  return new Intl.DateTimeFormat(lang === "nl" ? "nl-NL" : "en-GB", { day: "numeric", month: "long", year: "numeric", timeZone: TZ }).format(d);
}
/** Laatste dag waarop de code werkt: geldig tot (exclusief) validUntil, dus 1 ms ervoor (00:00 → de dag ervoor). */
export const lastValidDay = (validUntil: string, lang: Lang) => dateText(validUntil, lang, 1);

type Copy = {
  subject: string; preheader: string; eyebrow: string; title: string; why: string; what: string; data: string;
  codeLabel: string; codeValid: string; price: string; cta: string; support: string; reason: string; testNote: string;
};
function copy(i: MailInput): Copy {
  const cut = dateText(i.cutoverAt, i.lang), last = lastValidDay(i.validUntil, i.lang), pct = `${i.discountPct}%`;
  const full = formatAmount(PRICE_CENTS, PRICE_CURRENCY, i.lang), after = formatAmount(priceAfter(PRICE_CENTS, i.discountPct), PRICE_CURRENCY, i.lang);
  if (i.lang === "nl") {
    const remind = i.kind === "remind";
    return {
      subject: remind ? `Nog 7 dagen: Bingr wordt Lifetime op ${cut}` : `Bingr wordt Lifetime – met ${pct} korting voor jou`,
      preheader: remind
        ? `Vanaf ${cut} heb je Lifetime nodig om Bingr te gebruiken. Je code met ${pct} korting werkt nog t/m ${last}.`
        : `Vanaf ${cut} is Bingr alleen nog Lifetime. Met jouw persoonlijke code krijg je ${pct} korting.`,
      eyebrow: remind ? "Herinnering" : "Belangrijk over je account",
      title: remind ? `Nog 7 dagen tot Bingr Lifetime wordt` : "Bingr wordt Lifetime",
      why: "Bingr wordt gemaakt door één ontwikkelaar. De servers, de synchronisatie tussen je apparaten en de ontwikkeling van alle apps kosten geld, en Bingr wil geen reclame tonen. Daarom stoppen we met het gratis abonnement.",
      what: `Vanaf ${cut} is Bingr alleen nog te gebruiken met Lifetime: één keer betalen (${full}) en daarna voor altijd alle functies op al je apparaten. Je gratis account blijft bestaan, maar tot je Lifetime hebt zie je na die datum alleen het scherm om Lifetime te activeren.`,
      data: "Je gegevens blijven bewaard: je servers, lijsten, profielen en instellingen staan klaar zodra je Lifetime hebt. Wil je Bingr niet meer gebruiken? Dan kun je je account altijd verwijderen.",
      codeLabel: `Jouw persoonlijke code: ${pct} korting`,
      codeValid: `Geldig t/m ${last}, één keer te gebruiken en alleen met jouw account.`,
      price: `Met deze code betaal je ${after} in plaats van ${full}.`,
      cta: "Lifetime activeren",
      support: `Vragen? Kijk op ${SUPPORT_SITE.replace("https://", "")} of stel je vraag daar.`,
      reason: "Je ontvangt deze e-mail omdat je een gratis Bingr-account hebt. Dit is een dienstmelding over een wijziging van het abonnement, daarom krijg je hem ook als je geen nieuws per e-mail ontvangt.",
      testNote: "Testmail uit het beheer: de code hierboven is een voorbeeld en werkt niet.",
    };
  }
  const remind = i.kind === "remind";
  return {
    subject: remind ? `7 days left: Bingr goes Lifetime on ${cut}` : `Bingr is going Lifetime – ${pct} off for you`,
    preheader: remind
      ? `From ${cut} you'll need Lifetime to use Bingr. Your ${pct} off code works until ${last}.`
      : `From ${cut} Bingr is Lifetime only. Your personal code gives you ${pct} off.`,
    eyebrow: remind ? "Reminder" : "Important about your account",
    title: remind ? "7 days until Bingr goes Lifetime" : "Bingr is going Lifetime",
    why: "Bingr is made by a single developer. The servers, the sync between your devices and the development of every app cost money, and Bingr doesn't want to show ads. That's why we're ending the free plan.",
    what: `From ${cut}, Bingr can only be used with Lifetime: pay once (${full}) and get every feature on all your devices, forever. Your free account stays, but until you have Lifetime you'll only see the screen to activate Lifetime after that date.`,
    data: "Your data is kept: your servers, lists, profiles and settings will be ready as soon as you have Lifetime. Don't want to use Bingr anymore? You can always delete your account.",
    codeLabel: `Your personal code: ${pct} off`,
    codeValid: `Valid until ${last}, can be used once and only with your account.`,
    price: `With this code you pay ${after} instead of ${full}.`,
    cta: "Activate Lifetime",
    support: `Questions? Visit ${SUPPORT_SITE.replace("https://", "")} and ask us there.`,
    reason: "You're receiving this email because you have a free Bingr account. This is a service message about a change to the plan, so you get it even if you don't receive news by email.",
    testNote: "Test email from the admin: the code above is an example and doesn't work.",
  };
}

/** De code groot in een vak (kleiner dan de verificatiecode, zodat BINGR-XXXX-XXXX ook op een telefoon op één regel past). */
const codeHtml = (code: string) =>
  `<table role="presentation" cellpadding="0" cellspacing="0" border="0" width="100%" style="margin:12px 0 0"><tr>
<td align="center" bgcolor="#1f1f1f" style="background:#1f1f1f;border:2px dashed ${RED};border-radius:8px;padding:16px 8px;font-family:${MONO};font-size:24px;line-height:30px;font-weight:800;letter-spacing:2px;color:#ffffff;white-space:nowrap">${esc(code)}</td></tr></table>`;
const MONO = "ui-monospace,SFMono-Regular,Menlo,Consolas,'Liberation Mono',monospace";

export function renderLifetimeMail(i: MailInput): { subject: string; html: string; text: string } {
  const c = copy(i), url = upgradeUrl(i.code);
  const subject = i.test ? `[Test] ${c.subject}` : c.subject;
  const small = (t: string) => `<p style="margin:10px 0 0;font-size:13px;line-height:19px;color:#b3b3b3;text-align:center">${esc(t)}</p>`;
  const content = [
    eyebrow(c.eyebrow), redBar("12px 0 18px"), title(c.title, "0 0 14px"),
    greeting(i.lang, i.firstName),
    para(c.what), `<div style="height:14px"></div>`, para(c.why), `<div style="height:14px"></div>`, para(c.data),
    `<p style="margin:26px 0 0;font-size:13px;line-height:18px;font-weight:700;letter-spacing:.6px;text-transform:uppercase;color:#a3a3a3;text-align:center">${esc(c.codeLabel)}</p>`,
    codeHtml(i.code), small(c.codeValid), small(c.price),
    button(url, c.cta), copyLink(i.lang, url),
    `<p style="margin:22px 0 0;font-size:14px;line-height:21px;color:#b3b3b3">${esc(c.support)}</p>`,
    i.test ? `<p style="margin:18px 0 0;font-size:12px;line-height:18px;color:#8c8c8c">${esc(c.testNote)}</p>` : "",
  ].join("\n");
  const html = layout({
    lang: i.lang, docTitle: subject, preheader: c.preheader, label: "Lifetime", contentHtml: content,
    footerHtml: footerHtml({ lang: i.lang, reasonHtml: esc(c.reason), year: i.year }),
  });
  const g = greetingText(i.lang, i.firstName);
  const text = [
    c.title, "", ...(g ? [g, ""] : []), c.what, "", c.why, "", c.data, "",
    `${c.codeLabel}: ${i.code}`, c.codeValid, c.price, "", `${c.cta}: ${url}`, "", c.support,
    ...(i.test ? ["", c.testNote] : []), "", footerText({ lang: i.lang, reason: c.reason, year: i.year }),
  ].join("\n");
  return { subject, html, text };
}
