// Land van de bezoeker voor het beheer (overzicht "Landen", kolom Land bij Gebruikers): ALLEEN de landcode (ISO 3166-1
// alpha-2). Nooit het IP-adres opslaan of loggen, en ook de landcode niet loggen. XX (onbekend) en T1 (Tor) tellen niet.
// device-auth zet het bij register_device en heartbeat via bingr_set_country (schema.sql: account_country en
// account_devices.country; hoogstens één schrijfactie per uur per account als het land gelijk blijft).
// Oktober 2026 (diagnose): de header cf-ipcountry staat wel in de gatewaylogs van Supabase, maar komt NIET tot in de functie
// (Supabase zet er een eigen Cloudflare Worker tussen). Daarom bepaalt de functie het land zelf uit het IP-adres van de
// aanvraag met de eigen land-IP-tabel (_shared/geoip.ts, DB-IP Lite); het IP gaat naar geen enkele derde partij.
import { validIp } from "./ip.ts";
import { type GeoTable, lookup } from "./geoip.ts";

const valid = (v: string) => /^[A-Z]{2}$/.test(v) && v !== "XX" && v !== "T1";

export function countryOf(req: Request): string | null {
  const v = (req.headers.get("cf-ipcountry") ?? "").trim().toUpperCase();
  return valid(v) ? v : null;
}

// IP van de bezoeker voor de landbepaling: cf-connecting-ip (zet Cloudflare zelf, een meegestuurde waarde wordt
// overschreven), anders de laatste waarde van X-Forwarded-For (zie _shared/ip.ts). Alleen in het geheugen.
export function visitorIp(req: Request): string | null {
  const cf = (req.headers.get("cf-connecting-ip") ?? "").trim();
  if (cf && validIp(cf)) return cf;
  const list = (req.headers.get("x-forwarded-for") ?? "").split(",").map((s) => s.trim()).filter(Boolean);
  const last = list[list.length - 1] ?? "";
  return validIp(last) ? last : null;
}

// Eerst cf-ipcountry (als Supabase hem ooit wel doorgeeft), anders de eigen tabel. null = onbekend.
export async function countryFor(req: Request, table: () => Promise<GeoTable | null>): Promise<string | null> {
  const h = countryOf(req);
  if (h) return h;
  const ip = visitorIp(req);
  if (!ip) return null;
  const t = await table();
  if (!t) return null;
  const cc = lookup(t, ip);
  return cc && valid(cc) ? cc : null;
}
