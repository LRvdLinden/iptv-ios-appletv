// Build 167 (aanvulling 1): mail "Maak je Bingr-account" na een gastaankoop via Stripe (functie stripe-webhook). Met de
// claimlink https://bingr.online/upgrade/klaar/?claim=<token> (één keer, 30 dagen). Huisstijl van layout.ts; pure code
// (getest in lifetime_test.ts). Dit is een transactiemail bij een aankoop: geen afmeldlink, geen reclame.
import { button, copyLink, esc, eyebrow, footerHtml, footerText, layout, para, redBar, SITE, title, type Lang } from "./layout.ts";

export const claimUrl = (token: string) => `${SITE}/upgrade/klaar/?claim=${encodeURIComponent(token)}`;

const T: Record<Lang, { subject: string; pre: string; eye: string; title: string; body: string; email: string; cta: string; later: string; reason: string }> = {
  nl: {
    subject: "Je Bingr Lifetime staat klaar: maak je account",
    pre: "Je betaling is gelukt. Maak nu je account om Lifetime te gebruiken.",
    eye: "Betaling gelukt", title: "Maak je Bingr-account",
    body: "Bedankt voor je aankoop van Bingr Lifetime. Maak nu je account (of log in als je er al een hebt), dan staat Lifetime meteen aan op al je apparaten.",
    email: "Gebruik je hetzelfde e-mailadres als bij het betalen? Dan wordt je aankoop na het bevestigen van je e-mailadres ook vanzelf aan je account gekoppeld.",
    cta: "Account maken", later: "De knop werkt 30 dagen en één keer. Vragen? Kijk op support.bingr.online.",
    reason: "Je ontvangt deze e-mail omdat je Bingr Lifetime hebt gekocht op bingr.online.",
  },
  en: {
    subject: "Your Bingr Lifetime is ready: create your account",
    pre: "Your payment was successful. Create your account now to use Lifetime.",
    eye: "Payment successful", title: "Create your Bingr account",
    body: "Thanks for buying Bingr Lifetime. Create your account now (or sign in if you already have one) and Lifetime is active on all your devices right away.",
    email: "Using the same email address you paid with? Then your purchase is also linked to your account automatically once you've confirmed your email address.",
    cta: "Create account", later: "The button works for 30 days and only once. Questions? Visit support.bingr.online.",
    reason: "You're receiving this email because you bought Bingr Lifetime on bingr.online.",
  },
};

export function renderClaimMail(lang: Lang, token: string, year?: number) {
  const t = T[lang] ?? T.en, url = claimUrl(token);
  const content = [
    eyebrow(t.eye), redBar("12px 0 18px"), title(t.title, "0 0 14px"), para(t.body), `<div style="height:14px"></div>`, para(t.email),
    button(url, t.cta), copyLink(lang, url),
    `<p style="margin:22px 0 0;font-size:14px;line-height:21px;color:#b3b3b3">${esc(t.later)}</p>`,
  ].join("\n");
  return {
    subject: t.subject,
    html: layout({ lang, docTitle: t.subject, preheader: t.pre, label: "Lifetime", contentHtml: content, footerHtml: footerHtml({ lang, reasonHtml: esc(t.reason), year }) }),
    text: [t.title, "", t.body, "", t.email, "", `${t.cta}: ${url}`, "", t.later, "", footerText({ lang, reason: t.reason, year })].join("\n"),
  };
}
