// Maakt de Bingr-accountmails (Supabase Auth) in de gedeelde huisstijl (../functions/_shared/layout.ts, dezelfde opbouw als de
// supportmails) en templates.json voor de Supabase Management API (workflow Backend). Draaien:
//   deno run --allow-read --allow-write supabase/templates/build.ts
// Taal: user_metadata.lang ("nl", "en", ...) die de app meestuurt bij het aanmaken van het account; NL voor "nl", anders EN.
// De Go-templatevariabelen ({{ .ConfirmationURL }}, {{ .Token }}, {{ .Email }}, {{ .NewEmail }}) vult Supabase bij het versturen.
// Accountmails zijn transactioneel: geen afmeldlink, wel waarom je de mail krijgt en wat je doet als jij het niet was.
import {
  button, codeBox, copyLink, detailRows, eyebrow, footerHtml, type Lang, layout, note, para, redBar, title,
} from "../functions/_shared/layout.ts";

const CONF_URL = "{{ .ConfirmationURL }}";
const v = (name: string) => `<span style="color:#ffffff">{{ .${name} }}</span>`;

type Text = {
  eyebrow: string; title: string; intro: string; button?: string; note: string; reason: string; details: [string, string][];
};
type Template = { subject: string; code?: boolean; nl: Text; en: Text };

const ACC = { nl: "Account", en: "Account" };

export const TEMPLATES: Record<string, Template> = {
  confirmation: {
    subject: "Welkom bij Bingr · Bevestig je e-mailadres / Confirm your email",
    nl: {
      eyebrow: "Nieuw account", title: "Bevestig je e-mailadres",
      intro: "Fijn dat je er bent! Bevestig je e-mailadres en log daarna in de Bingr-app in om te beginnen met kijken.",
      button: "E-mailadres bevestigen", note: "De link werkt één keer en is beperkt geldig.",
      details: [[ACC.nl, v("Email")]],
      reason: `Je ontvangt deze e-mail omdat iemand met dit e-mailadres (${"{{ .Email }}"}) een Bingr-account heeft aangemaakt. Was jij dit niet? Dan kun je deze e-mail negeren; er verandert niets en het account wordt niet geactiveerd.`,
    },
    en: {
      eyebrow: "New account", title: "Confirm your email address",
      intro: "Welcome to Bingr! Confirm your email address, then sign in to the Bingr app to start watching.",
      button: "Confirm email address", note: "This link works once and expires after a while.",
      details: [[ACC.en, v("Email")]],
      reason: `You're receiving this email because someone created a Bingr account with this email address (${"{{ .Email }}"}). If this wasn't you, you can ignore this email; nothing will change and the account won't be activated.`,
    },
  },
  recovery: {
    subject: "Bingr · Nieuw wachtwoord instellen / Reset your password",
    nl: {
      eyebrow: "Wachtwoord", title: "Nieuw wachtwoord instellen",
      intro: "We kregen een verzoek om het wachtwoord van je Bingr-account te wijzigen. Klik op de knop om een nieuw wachtwoord te kiezen.",
      button: "Nieuw wachtwoord kiezen", note: "De link werkt één keer en is beperkt geldig. Bingr vraagt je nooit om je wachtwoord per e-mail.",
      details: [[ACC.nl, v("Email")]],
      reason: `Je ontvangt deze e-mail omdat er voor het Bingr-account van dit e-mailadres (${"{{ .Email }}"}) een nieuw wachtwoord is aangevraagd. Was jij dit niet? Dan kun je deze e-mail negeren; er verandert niets en je wachtwoord blijft hetzelfde.`,
    },
    en: {
      eyebrow: "Password", title: "Reset your password",
      intro: "We received a request to reset the password for your Bingr account. Click the button to choose a new password.",
      button: "Choose a new password", note: "This link works once and expires after a while. Bingr will never ask for your password by email.",
      details: [[ACC.en, v("Email")]],
      reason: `You're receiving this email because a new password was requested for the Bingr account with this email address (${"{{ .Email }}"}). If this wasn't you, you can ignore this email; nothing will change and your password stays the same.`,
    },
  },
  invite: {
    subject: "Je bent uitgenodigd voor Bingr / You're invited to Bingr",
    nl: {
      eyebrow: "Uitnodiging", title: "Je bent uitgenodigd",
      intro: "Je bent uitgenodigd om een Bingr-account te maken. Klik op de knop om je account te activeren en een wachtwoord te kiezen.",
      button: "Uitnodiging accepteren", note: "De uitnodiging werkt één keer en is beperkt geldig.",
      details: [["E-mailadres", v("Email")]],
      reason: `Je ontvangt deze e-mail omdat dit e-mailadres (${"{{ .Email }}"}) is uitgenodigd voor een Bingr-account. Wil je geen account? Dan kun je deze e-mail negeren; er verandert niets en er wordt geen account geactiveerd.`,
    },
    en: {
      eyebrow: "Invitation", title: "You're invited",
      intro: "You've been invited to create a Bingr account. Click the button to activate your account and choose a password.",
      button: "Accept invitation", note: "This invitation works once and expires after a while.",
      details: [["Email address", v("Email")]],
      reason: `You're receiving this email because this email address (${"{{ .Email }}"}) was invited to a Bingr account. Don't want an account? You can ignore this email; nothing will change and no account will be activated.`,
    },
  },
  magic_link: {
    subject: "Inloggen bij Bingr / Sign in to Bingr",
    nl: {
      eyebrow: "Inloggen", title: "Inloggen bij Bingr",
      intro: "Klik op de knop om in te loggen bij Bingr.",
      button: "Inloggen", note: "Deze link werkt één keer en is kort geldig. Stuur hem niet door.",
      details: [[ACC.nl, v("Email")]],
      reason: `Je ontvangt deze e-mail omdat iemand met dit e-mailadres (${"{{ .Email }}"}) wil inloggen bij Bingr. Was jij dit niet? Dan kun je deze e-mail negeren; er verandert niets en er wordt niet ingelogd.`,
    },
    en: {
      eyebrow: "Sign in", title: "Sign in to Bingr",
      intro: "Click the button to sign in to Bingr.",
      button: "Sign in", note: "This link works once and expires soon. Don't forward it.",
      details: [[ACC.en, v("Email")]],
      reason: `You're receiving this email because someone wants to sign in to Bingr with this email address (${"{{ .Email }}"}). If this wasn't you, you can ignore this email; nothing will change and nobody is signed in.`,
    },
  },
  email_change: {
    subject: "Bingr · Bevestig je nieuwe e-mailadres / Confirm your new email",
    nl: {
      eyebrow: "E-mailadres", title: "Bevestig je nieuwe e-mailadres",
      intro: `Je wilt het e-mailadres van je Bingr-account wijzigen naar ${v("NewEmail")}. Bevestig dit met de knop hieronder.`,
      button: "Nieuw adres bevestigen", note: "Heb je dit niet aangevraagd? Wijzig dan voor de zekerheid je wachtwoord.",
      details: [["Huidig adres", v("Email")], ["Nieuw adres", v("NewEmail")]],
      reason: "Je ontvangt deze e-mail omdat is gevraagd het e-mailadres van een Bingr-account te wijzigen. Was jij dit niet? Dan kun je deze e-mail negeren; er verandert niets en je e-mailadres blijft hetzelfde.",
    },
    en: {
      eyebrow: "Email address", title: "Confirm your new email address",
      intro: `You asked to change the email address of your Bingr account to ${v("NewEmail")}. Confirm with the button below.`,
      button: "Confirm new address", note: "Didn't ask for this? Change your password to be safe.",
      details: [["Current address", v("Email")], ["New address", v("NewEmail")]],
      reason: "You're receiving this email because a change of email address was requested for a Bingr account. If this wasn't you, you can ignore this email; nothing will change and your email address stays the same.",
    },
  },
  reauthentication: {
    subject: "Bingr · Je verificatiecode / Your verification code",
    code: true,
    nl: {
      eyebrow: "Beveiliging", title: "Je verificatiecode",
      intro: "Gebruik deze code om te bevestigen dat jij het bent:",
      note: "De code is kort geldig. Deel hem met niemand; Bingr vraagt nooit om deze code.",
      details: [[ACC.nl, v("Email")]],
      reason: `Je ontvangt deze e-mail omdat er voor het Bingr-account van dit e-mailadres (${"{{ .Email }}"}) een verificatiecode is aangevraagd. Was jij dit niet? Dan kun je deze e-mail negeren; er verandert niets.`,
    },
    en: {
      eyebrow: "Security", title: "Your verification code",
      intro: "Use this code to confirm it's you:",
      note: "This code expires soon. Don't share it with anyone; Bingr will never ask you for it.",
      details: [[ACC.en, v("Email")]],
      reason: `You're receiving this email because a verification code was requested for the Bingr account with this email address (${"{{ .Email }}"}). If this wasn't you, you can ignore this email; nothing will change.`,
    },
  },
};

/** Eén taalversie (volledig HTML-document) van een accountmail. */
export function renderAuth(key: string, lang: Lang, year?: number) {
  const tpl = TEMPLATES[key], t = tpl[lang];
  const action = tpl.code ? codeBox("{{ .Token }}") : button(CONF_URL, t.button!);
  const content = `
${eyebrow(t.eyebrow)}
${redBar("12px 0 20px")}
${title(t.title)}
${para(t.intro, true)}
${action}
${note(t.note)}
${detailRows(t.details)}
${tpl.code ? "" : copyLink(lang, CONF_URL)}`;
  return layout({
    lang, docTitle: `Bingr · ${t.title}`, preheader: t.title, label: "Account",
    contentHtml: content, footerHtml: footerHtml({ lang, reasonHtml: t.reason, year }),
  });
}

/** De template voor Supabase: NL voor accounts met lang "nl", anders EN. */
export const renderTemplate = (key: string, year?: number) =>
  `{{ if and .Data.lang (eq .Data.lang "nl") }}${renderAuth(key, "nl", year)}{{ else }}${renderAuth(key, "en", year)}{{ end }}`;

if (import.meta.main) {
  const here = new URL(".", import.meta.url);
  const cfg: Record<string, string> = {};
  for (const [key, tpl] of Object.entries(TEMPLATES)) {
    const content = renderTemplate(key);
    await Deno.writeTextFile(new URL(`${key}.html`, here), content);
    cfg[`mailer_subjects_${key}`] = tpl.subject;
    cfg[`mailer_templates_${key}_content`] = content;
  }
  await Deno.writeTextFile(new URL("templates.json", here), JSON.stringify(cfg, null, 1) + "\n");
  console.log(`${Object.keys(TEMPLATES).length} templates`);
}
