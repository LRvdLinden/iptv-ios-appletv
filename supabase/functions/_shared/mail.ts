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

// ---- mailtest (workflow Diagnose, invoer alle_mails; supabase/tests/all_mails_e2e.py in iptv-ios-appletv) ----
// De test zet via de Management-API in app_settings de rij 'mailtest' = {sha256: hex(SHA-256(sleutel)), until: ISO} (max. 30
// minuten) en stuurt de sleutel mee in de header x-bingr-mailtest. Daarmee mogen alleen voorbeeld- en testmails, en
// alleen naar testadressen support+ci-…@bingr.online (komen in de eigen supportmailbox). Na de test wordt de rij verwijderd.
export const MAILTEST_HEADER = "x-bingr-mailtest";
const MAILTEST_TO = /^support\+ci-[a-z0-9]{6,24}(-[a-z0-9]{1,12})?@bingr\.online$/i;
export const isMailtestAddress = (to: unknown): boolean => typeof to === "string" && MAILTEST_TO.test(to.trim());
async function sha256hex(s: string): Promise<string> {
  const d = new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s)));
  return Array.from(d, (x) => x.toString(16).padStart(2, "0")).join("");
}
/** true als `given` de geldige mailtest-sleutel is. `load` geeft app_settings.value van de rij 'mailtest' (of null). */
export async function mailtestOk(given: string | null | undefined, load: () => Promise<unknown>, now = Date.now()): Promise<boolean> {
  if (!given || given.length < 32 || given.length > 128) return false;
  let v: unknown;
  try { v = await load(); } catch { return false; }
  const want = v && typeof v === "object" ? String((v as Record<string, unknown>).sha256 ?? "") : "";
  const until = v && typeof v === "object" ? Date.parse(String((v as Record<string, unknown>).until ?? "")) : NaN;
  if (!/^[0-9a-f]{64}$/.test(want) || !Number.isFinite(until) || until < now || until > now + 30 * 60_000) return false;
  const got = await sha256hex(given);
  let d = 0;
  for (let i = 0; i < 64; i++) d |= got.charCodeAt(i) ^ want.charCodeAt(i);
  return d === 0;
}
