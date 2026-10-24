// Land van de bezoeker voor het beheer (overzicht "Landen", kolom Land bij Gebruikers): ALLEEN de landcode (ISO 3166-1
// alpha-2) die Cloudflare vóór de Edge Functions zelf zet (header cf-ipcountry, uit het netwerk van de bezoeker). Nooit het
// IP-adres opslaan of loggen, en ook de landcode niet loggen. XX (onbekend) en T1 (Tor) tellen niet.
// device-auth zet het bij register_device en heartbeat via bingr_set_country (schema.sql: account_country en
// account_devices.country; hoogstens één schrijfactie per uur per account als het land gelijk blijft).
export function countryOf(req: Request): string | null {
  const v = (req.headers.get("cf-ipcountry") ?? "").trim().toUpperCase();
  return /^[A-Z]{2}$/.test(v) && v !== "XX" && v !== "T1" ? v : null;
}
