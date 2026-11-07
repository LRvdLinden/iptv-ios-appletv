// Omzet: Apple-aankopen uit App Store Connect (Sales and Trends), voor de functie apple-sales en de tab Omzet in het beheer.
// Pure logica zonder database (getest in asc_test.ts): JWT voor de App Store Connect API, de URL van het dagrapport,
// gzip + TSV lezen, alleen de regels van onze in-app aankoop, samenvoegen per dag/land/valuta/prijs en omrekenen naar EUR.
// Contract in docs/ACCOUNT.md, "Omzet: Apple (App Store Connect)".
// Het rapport bevat geen persoonsgegevens (alleen aantallen per land en prijs). Nooit de sleutel, de JWT of het
// vendornummer in een log, een foutmelding of een antwoord: de URL van het rapport bevat het vendornummer.
import { APPLE_BUNDLE_ID, APPLE_PRODUCT_ID } from "./apple.ts";

export const ASC_API = "https://api.appstoreconnect.apple.com/v1/salesReports";
export const ASC_AUDIENCE = "appstoreconnect-v1";
/** Apple accepteert hoogstens 20 minuten; wij nemen 15. */
export const ASC_TTL_S = 15 * 60;
export const MAX_RANGE_DAYS = 365;
export const DAILY_DAYS = 7;

const enc = new TextEncoder();
const b64u = (b: Uint8Array) => btoa(String.fromCharCode(...b)).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
const b64uJson = (o: unknown) => b64u(enc.encode(JSON.stringify(o)));

// ---- configuratie (function-secrets ASC_ISSUER_ID, ASC_KEY_ID, ASC_VENDOR, ASC_PRIVATE_KEY) ----
export type AscConfig = { issuerId: string; keyId: string; vendor: string; privateKey: string; appSkus: string[] };
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
/** De sleutel als PEM (.p8), met echte of letterlijke \n, of alleen het base64-deel (zo zet de workflow hem). */
export function pemBody(v: string): string | null {
  const s = v.replace(/\\n/g, "\n").replace(/-----(BEGIN|END) [A-Z ]+-----/g, "").replace(/\s+/g, "");
  return /^[A-Za-z0-9+/]+={0,2}$/.test(s) && s.length >= 64 && s.length <= 4096 ? s : null;
}
/** null = niet (volledig) ingesteld. Geeft nooit door welke waarde fout is (zie de workflow voor de controle). */
export function ascConfig(get: (k: string) => string | undefined): AscConfig | null {
  const issuerId = (get("ASC_ISSUER_ID") ?? "").trim(), keyId = (get("ASC_KEY_ID") ?? "").trim();
  const vendor = (get("ASC_VENDOR") ?? "").trim(), key = pemBody(get("ASC_PRIVATE_KEY") ?? "");
  if (!UUID.test(issuerId) || !/^[A-Z0-9]{8,16}$/.test(keyId) || !/^[0-9]{5,12}$/.test(vendor) || !key) return null;
  // SKU van de app in App Store Connect (Parent Identifier van de in-app aankoop); standaard de bundle-id
  const appSkus = [APPLE_BUNDLE_ID, ...(get("ASC_APP_SKU") ?? "").split(",").map((x) => x.trim()).filter((x) => /^[A-Za-z0-9._-]{1,100}$/.test(x))];
  return { issuerId, keyId, vendor, privateKey: key, appSkus: [...new Set(appSkus)] };
}

// ---- JWT (ES256) ----
export async function importAscKey(pemOrBody: string): Promise<CryptoKey> {
  const body = pemBody(pemOrBody);
  if (!body) throw new Error("asc_key_invalid");
  const der = Uint8Array.from(atob(body), (c) => c.charCodeAt(0));
  try {
    return await crypto.subtle.importKey("pkcs8", der, { name: "ECDSA", namedCurve: "P-256" }, false, ["sign"]);
  } catch {
    throw new Error("asc_key_invalid");
  }
}
/** JWT voor de App Store Connect API: header {alg ES256, kid, typ JWT}, payload {iss, iat, exp (max. 20 min), aud}. */
export async function ascJwt(key: CryptoKey, keyId: string, issuerId: string, nowMs = Date.now(), ttlS = ASC_TTL_S): Promise<string> {
  const iat = Math.floor(nowMs / 1000), ttl = Math.min(Math.max(60, ttlS), 20 * 60);
  const input = `${b64uJson({ alg: "ES256", kid: keyId, typ: "JWT" })}.${b64uJson({ iss: issuerId, iat, exp: iat + ttl, aud: ASC_AUDIENCE })}`;
  // WebCrypto geeft r||s (IEEE P1363), precies wat JWS ES256 wil
  const sig = new Uint8Array(await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, key, enc.encode(input)));
  return `${input}.${b64u(sig)}`;
}

// ---- dagen ----
const YMD = /^\d{4}-\d{2}-\d{2}$/;
export function isYmd(v: unknown): v is string {
  if (typeof v !== "string" || !YMD.test(v)) return false;
  const t = Date.parse(`${v}T00:00:00Z`);
  return Number.isFinite(t) && new Date(t).toISOString().slice(0, 10) === v;
}
export const ymd = (t: number) => new Date(t).toISOString().slice(0, 10);
const DAY = 86400_000;
export const addDays = (d: string, n: number) => ymd(Date.parse(`${d}T00:00:00Z`) + n * DAY);
/** Dagelijks: de laatste 7 dagen tot en met gisteren (UTC; de rapporten van Apple lopen ±1 dag achter). */
export function dailyDays(nowMs = Date.now(), n = DAILY_DAYS): string[] {
  const today = ymd(nowMs);
  return Array.from({ length: n }, (_, i) => addDays(today, -1 - i)).reverse();
}
/** Handmatig terugvullen: from..to (inclusief), niet in de toekomst, hoogstens 365 dagen. */
export function rangeDays(from: unknown, to: unknown, nowMs = Date.now()): string[] | { error: string } {
  if (!isYmd(from) || !isYmd(to)) return { error: "bad_range" };
  if (from > to) return { error: "bad_range" };
  if (to > ymd(nowMs)) return { error: "bad_range" };
  const n = Math.round((Date.parse(`${to}T00:00:00Z`) - Date.parse(`${from}T00:00:00Z`)) / DAY) + 1;
  if (n > MAX_RANGE_DAYS) return { error: "range_too_long" };
  return Array.from({ length: n }, (_, i) => addDays(from, i));
}

/** URL van het dagrapport (SALES, SUMMARY, versie 1_1). Bevat het vendornummer: nooit loggen. */
export function salesUrl(vendor: string, date: string): string {
  const q = new URLSearchParams({
    "filter[frequency]": "DAILY", "filter[reportType]": "SALES", "filter[reportSubType]": "SUMMARY",
    "filter[vendorNumber]": vendor, "filter[reportDate]": date, "filter[version]": "1_1",
  });
  return `${ASC_API}?${q}`;
}

// ---- gzip + TSV ----
/** Het rapport komt als gzip; een al uitgepakt antwoord (begint met tekst) wordt ook geaccepteerd. */
export async function gunzipText(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  if (bytes.length >= 2 && bytes[0] === 0x1f && bytes[1] === 0x8b) {
    const stream = new Blob([bytes]).stream().pipeThrough(new DecompressionStream("gzip"));
    return await new Response(stream).text();
  }
  return new TextDecoder().decode(bytes);
}
export type TsvRow = Record<string, string>;
/** Tab-gescheiden met een kopregel; sleutels zoals in de kopregel (getrimd). Lege regels vallen weg. */
export function parseTsv(text: string): TsvRow[] {
  const lines = text.replace(/^﻿/, "").split(/\r?\n/).filter((l) => l.trim() !== "");
  if (!lines.length) return [];
  const head = lines[0].split("\t").map((h) => h.trim());
  return lines.slice(1).map((l) => {
    const cells = l.split("\t");
    return Object.fromEntries(head.map((h, i) => [h, (cells[i] ?? "").trim()]));
  });
}

// ---- onze in-app aankoop ----
// Product Type Identifier van in-app aankopen (iOS en Mac: -M): IA1 (non-consumable), IA9, IAY, IAC, FI1
const IAP_TYPE = /^(IA1|IA9|IAY|IAC|FI1)(-M)?$/;
/**
 * Alleen de regels van Lifetime: in het salesrapport staat bij een in-app aankoop de Product ID in de kolom SKU en de
 * SKU van de app in Parent Identifier. Dus: SKU = nl.lrvdlinden.bingr.lifetime, of een in-app aankoop (Product Type
 * Identifier) met Parent Identifier = de app. Downloads van de app zelf (geen Parent Identifier) tellen nooit mee.
 */
export function isOurIap(r: TsvRow, appSkus: string[], productId = APPLE_PRODUCT_ID): boolean {
  const sku = r["SKU"] ?? "", parent = r["Parent Identifier"] ?? "", type = r["Product Type Identifier"] ?? "";
  if (sku === productId) return true;
  return parent !== "" && appSkus.includes(parent) && IAP_TYPE.test(type);
}

export type SalesKind = "sale" | "refund";
export type SalesRow = {
  date: string; kind: SalesKind; product_id: string; country: string; customer_currency: string; proceeds_currency: string;
  units: number; customer_price: number; developer_proceeds: number;
};
const num = (v: string | undefined) => {
  const n = Number(String(v ?? "").replace(/,/g, ""));
  return Number.isFinite(n) ? n : NaN;
};
const r4 = (n: number) => Math.round(n * 10000) / 10000;

/**
 * Regels van één dag samenvoegen per soort (verkoop of terugbetaling: negatieve units), land, valuta's, product en
 * klantprijs. units altijd positief; customer_price en developer_proceeds per stuk (positief; de opbrengst is het
 * gewogen gemiddelde als die binnen één sleutel verschilt). Onbruikbare regels (geen land, valuta of getal) vallen weg
 * en worden geteld in `skipped`.
 */
export function aggregate(date: string, rows: TsvRow[], appSkus: string[], productId = APPLE_PRODUCT_ID): { rows: SalesRow[]; matched: number; skipped: number } {
  const map = new Map<string, SalesRow & { _p: number }>();
  let matched = 0, skipped = 0;
  for (const r of rows) {
    if (!isOurIap(r, appSkus, productId)) continue;
    matched++;
    const units = num(r["Units"]), price = num(r["Customer Price"]), proceeds = num(r["Developer Proceeds"]);
    const country = (r["Country Code"] ?? "").toUpperCase(), cc = (r["Customer Currency"] ?? "").toUpperCase();
    const pc = (r["Currency of Proceeds"] ?? "").toUpperCase();
    const pid = r["SKU"] === productId ? productId : (r["SKU"] || productId);
    if (!Number.isFinite(units) || units === 0 || !Number.isFinite(price) || !Number.isFinite(proceeds) || !/^[A-Z]{2}$/.test(country) ||
      !/^[A-Z]{3}$/.test(cc) || !/^[A-Z]{3}$/.test(pc) || !/^[A-Za-z0-9._-]{1,100}$/.test(pid)) { skipped++; continue; }
    const kind: SalesKind = units < 0 || price < 0 ? "refund" : "sale";
    const u = Math.abs(Math.round(units)), cp = r4(Math.abs(price)), dp = Math.abs(proceeds);
    const key = [kind, country, cc, pc, pid, cp.toFixed(4)].join("|");
    const cur = map.get(key);
    if (cur) { cur.units += u; cur._p += u * dp; }
    else map.set(key, { date, kind, product_id: pid, country, customer_currency: cc, proceeds_currency: pc, units: u, customer_price: cp, developer_proceeds: 0, _p: u * dp });
  }
  const out = [...map.values()].map(({ _p, ...x }) => ({ ...x, developer_proceeds: x.units ? r4(_p / x.units) : 0 }));
  out.sort((a, b) => (a.kind + a.country + a.customer_currency + a.customer_price).localeCompare(b.kind + b.country + b.customer_currency + b.customer_price));
  return { rows: out, matched, skipped };
}

// ---- valuta ----
/** app_settings.fx_rates: {"USD": 0.92, …} = EUR per 1 eenheid van die valuta. EUR is altijd 1. */
export type FxRates = Record<string, number>;
export function cleanFxRates(v: unknown): FxRates {
  const o = v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {};
  const out: FxRates = {};
  for (const [k, x] of Object.entries(o).slice(0, 200)) {
    const n = typeof x === "number" ? x : Number(x);
    if (/^[A-Z]{3}$/.test(k) && k !== "EUR" && Number.isFinite(n) && n > 0 && n < 100000) out[k] = n;
  }
  return out;
}
/** Bedrag naar EUR: EUR blijft gelijk, anders met de vaste koers; zonder koers null (apart tonen, niet meetellen). */
export function toEur(amount: number, currency: string, rates: FxRates): number | null {
  const c = currency.toUpperCase();
  if (c === "EUR") return amount;
  const r = rates[c];
  return typeof r === "number" && r > 0 ? amount * r : null;
}
/** Welke valuta van deze regels niet om te rekenen zijn (klantprijs of opbrengst). */
export function unconverted(rows: SalesRow[], rates: FxRates): string[] {
  const s = new Set<string>();
  for (const r of rows) {
    for (const c of [r.customer_currency, r.proceeds_currency]) if (toEur(1, c, rates) === null) s.add(c);
  }
  return [...s].sort();
}

// ---- ophalen (met een nep-fetch te testen) ----
export type DayResult = { date: string; status: "ok" | "empty" | "not_ready" | "error"; rows: number; http?: number };
export type FetchLike = (url: string, init: RequestInit) => Promise<Response>;
/**
 * Eén dag ophalen. 200 = rapport (gzip TSV), 404 = (nog) geen rapport voor die dag: geen fout. "There were no sales"
 * in het antwoord = geen verkopen (status empty), anders not_ready. De URL en het antwoord komen nooit in een fout of log.
 */
export async function fetchDay(fetcher: FetchLike, cfg: AscConfig, jwt: string, date: string): Promise<{ result: DayResult; rows?: SalesRow[] }> {
  let res: Response;
  try {
    res = await fetcher(salesUrl(cfg.vendor, date), {
      headers: { Authorization: `Bearer ${jwt}`, Accept: "application/a-gzip" }, signal: AbortSignal.timeout(25000),
    });
  } catch {
    return { result: { date, status: "error", rows: 0 } };
  }
  if (res.status === 404) {
    const t = (await res.text().catch(() => "")).toLowerCase();
    return { result: { date, status: /no sales/.test(t) ? "empty" : "not_ready", rows: 0, http: 404 } };
  }
  if (!res.ok) {
    await res.body?.cancel().catch(() => {});
    return { result: { date, status: "error", rows: 0, http: res.status } };
  }
  try {
    const text = await gunzipText(new Uint8Array(await res.arrayBuffer()));
    const { rows } = aggregate(date, parseTsv(text), cfg.appSkus);
    return { result: { date, status: "ok", rows: rows.length, http: 200 }, rows };
  } catch {
    return { result: { date, status: "error", rows: 0, http: 200 } };
  }
}
/** Dagen ophalen met hoogstens `parallel` tegelijk; `store` schrijft de rijen van een geslaagde dag (overschrijft die dag). */
export async function syncDays(dates: string[], fetchOne: (d: string) => Promise<{ result: DayResult; rows?: SalesRow[] }>,
  store: (d: string, rows: SalesRow[]) => Promise<void>, parallel = 6): Promise<DayResult[]> {
  const out: DayResult[] = new Array(dates.length);
  let next = 0;
  const worker = async () => {
    while (next < dates.length) {
      const i = next++;
      const { result, rows } = await fetchOne(dates[i]);
      if (result.status === "ok" && rows) {
        try { await store(dates[i], rows); } catch { result.status = "error"; }
      }
      out[i] = result;
    }
  };
  await Promise.all(Array.from({ length: Math.max(1, Math.min(parallel, dates.length)) }, worker));
  return out;
}
/** Tot en met welke dag Apple bijgewerkt is: de laatste dag met een rapport (ok) of zonder verkopen (empty). */
export function throughDate(results: DayResult[], previous: string | null): string | null {
  let t = previous && isYmd(previous) ? previous : null;
  for (const r of results) if ((r.status === "ok" || r.status === "empty") && (!t || r.date > t)) t = r.date;
  return t;
}
/** Aantallen van een ronde: dagen met rapport (ok), zonder verkopen (empty), nog niet klaar, mislukt (failed) en rijen. */
export function summarizeRun(results: DayResult[]) {
  const c = { ok: 0, empty: 0, not_ready: 0, failed: 0, rows: 0 };
  for (const r of results) { if (r.status === "error") c.failed++; else c[r.status]++; c.rows += r.rows; }
  return c;
}
