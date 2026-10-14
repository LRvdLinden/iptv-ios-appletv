// Gedeelde e-mail via SMTP (admin: berichten; status: storingsmeldingen; support: supporttickets). Dit bestand staat
// in LRvdLinden/iptv-ios-appletv en als kopie in LRvdLinden/bingr-beheer (functie admin); houd ze gelijk. Instellingen als function-secrets
// BINGR_SMTP_HOST, BINGR_SMTP_PORT (465), BINGR_SMTP_USER, BINGR_SMTP_PASSWORD, BINGR_SMTP_FROM.
import nodemailer from "npm:nodemailer@7.0.13";

const env = (k: string) => Deno.env.get(k) ?? "";

export const smtpConfigured = () =>
  !!(env("BINGR_SMTP_HOST") && env("BINGR_SMTP_USER") && env("BINGR_SMTP_PASSWORD") && env("BINGR_SMTP_FROM"));

export function transport() {
  const port = Number(env("BINGR_SMTP_PORT") || 465);
  return nodemailer.createTransport({
    host: env("BINGR_SMTP_HOST"), port, secure: port !== 587 && port !== 25, // 465 = TLS (Supabase blokkeert 25 en 587)
    auth: { user: env("BINGR_SMTP_USER"), pass: env("BINGR_SMTP_PASSWORD") },
    connectionTimeout: 15000, greetingTimeout: 15000, socketTimeout: 30000,
  });
}

export const smtpFrom = () => env("BINGR_SMTP_FROM");
