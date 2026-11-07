// Unittests voor _shared/asc.ts (Apple-omzet uit App Store Connect). Alleen verzonnen rapportregels en een zelfgemaakte
// testsleutel; nooit een echte sleutel, JWT of vendornummer.
import {
  aggregate, ascConfig, ascJwt, cleanFxRates, dailyDays, fetchDay, gunzipText, importAscKey, isOurIap, parseTsv, pemBody, rangeDays,
  salesUrl, summarizeRun, syncDays, throughDate, toEur, unconverted, type AscConfig, type SalesRow,
} from "./asc.ts";

// zonder externe afhankelijkheden (zoals apple_test.ts)
const canon = (v: unknown): string => JSON.stringify(v, (_k, x) => (x && typeof x === "object" && !Array.isArray(x) ? Object.fromEntries(Object.entries(x).sort()) : x));
function assertEquals(a: unknown, b: unknown, msg = "") { if (canon(a) !== canon(b)) throw new Error(`${msg} verwacht ${canon(b)}, kreeg ${canon(a)}`); }
function assert(v: unknown, msg = ""): asserts v { if (!v) throw new Error(`niet waar: ${msg}`); }
async function assertRejects(f: () => Promise<unknown>, _t: unknown, text: string) {
  try { await f(); } catch (e) { if (e instanceof Error && e.message.includes(text)) return; throw new Error(`verkeerde fout: ${e}`); }
  throw new Error(`geen fout, verwacht ${text}`);
}

const HEAD = ["Provider", "Provider Country", "SKU", "Developer", "Title", "Version", "Product Type Identifier", "Units", "Developer Proceeds",
  "Begin Date", "End Date", "Customer Currency", "Country Code", "Currency of Proceeds", "Apple Identifier", "Customer Price", "Promo Code",
  "Parent Identifier", "Subscription", "Period", "Category", "CMB", "Device", "Supported Platforms", "Proceeds Reason", "Preserved Pricing",
  "Client", "Order Type"];
type R = Partial<Record<string, string>>;
const line = (r: R) => HEAD.map((h) => r[h] ?? "").join("\t");
const iap = (o: R): R => ({
  Provider: "APPLE", "Provider Country": "US", SKU: "nl.lrvdlinden.bingr.lifetime", Developer: "Test", Title: "Bingr Lifetime",
  "Product Type Identifier": "IA1", Units: "1", "Developer Proceeds": "3.48", "Begin Date": "11/05/2026", "End Date": "11/05/2026",
  "Customer Currency": "EUR", "Country Code": "NL", "Currency of Proceeds": "EUR", "Apple Identifier": "1234567890", "Customer Price": "4.99",
  "Parent Identifier": "nl.lrvdlinden.bingr", Category: "Entertainment", Device: "iPhone", ...o,
});
const REPORT = [HEAD.join("\t"),
  line(iap({})),
  line(iap({ Units: "2" })),                                                                   // zelfde sleutel: samen 3
  line(iap({ "Country Code": "BE" })),
  line(iap({ "Country Code": "US", "Customer Currency": "USD", "Currency of Proceeds": "USD", "Customer Price": "4.99", "Developer Proceeds": "4.24" })),
  line(iap({ Units: "-1" })),                                                                  // terugbetaling NL
  line(iap({ "Product Type Identifier": "IA1-M", Device: "Desktop" })),                        // Mac telt mee (zelfde sleutel als NL)
  line(iap({ SKU: "nl.lrvdlinden.bingr", "Product Type Identifier": "1F", "Parent Identifier": "", "Customer Price": "0", "Developer Proceeds": "0" })), // download app
  line(iap({ SKU: "com.ander.app.pro", "Parent Identifier": "com.ander.app" })),               // andere app
  line(iap({ SKU: "lifetime_ref", "Parent Identifier": "BINGR-SKU" })),                        // via de app-SKU
  line(iap({ "Country Code": "", Units: "1" })),                                               // onbruikbaar
].join("\n") + "\n";

async function gzip(text: string): Promise<Uint8Array<ArrayBuffer>> {
  const s = new Blob([new TextEncoder().encode(text)]).stream().pipeThrough(new CompressionStream("gzip"));
  return new Uint8Array(await new Response(s).arrayBuffer());
}
async function testKey() {
  const kp = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]) as CryptoKeyPair;
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", kp.privateKey));
  const b64 = btoa(String.fromCharCode(...der));
  const pem = `-----BEGIN PRIVATE KEY-----\n${b64.match(/.{1,64}/g)!.join("\n")}\n-----END PRIVATE KEY-----\n`;
  return { pem, pub: kp.publicKey };
}
const dec = (s: string) => JSON.parse(new TextDecoder().decode(Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0))));
const CFG: AscConfig = { issuerId: "00000000-0000-4000-8000-000000000000", keyId: "TESTKEY123", vendor: "80000000", privateKey: "x", appSkus: ["nl.lrvdlinden.bingr", "BINGR-SKU"] };

Deno.test("JWT: ES256 met kid, iss, aud en hoogstens 20 minuten, te controleren met de publieke sleutel", async () => {
  const { pem, pub } = await testKey();
  const key = await importAscKey(pem);
  const now = Date.UTC(2026, 10, 7, 12, 0, 0);
  const jwt = await ascJwt(key, "TESTKEY123", CFG.issuerId, now);
  const [h, p, s] = jwt.split(".");
  assertEquals(dec(h), { alg: "ES256", kid: "TESTKEY123", typ: "JWT" });
  const pl = dec(p);
  assertEquals(pl.iss, CFG.issuerId);
  assertEquals(pl.aud, "appstoreconnect-v1");
  assertEquals(pl.iat, now / 1000);
  assert(pl.exp - pl.iat <= 20 * 60 && pl.exp > pl.iat);
  const sig = Uint8Array.from(atob(s.replace(/-/g, "+").replace(/_/g, "/")), (c) => c.charCodeAt(0));
  assertEquals(sig.length, 64); // r||s, geen DER
  assert(await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, pub, sig, new TextEncoder().encode(`${h}.${p}`)));
  // langer dan 20 minuten kan niet
  const long = dec((await ascJwt(key, "TESTKEY123", CFG.issuerId, now, 3600)).split(".")[1]);
  assertEquals(long.exp - long.iat, 1200);
});

Deno.test("sleutel: PEM, letterlijke \\n en alleen het base64-deel; ongeldig = asc_key_invalid", async () => {
  const { pem } = await testKey();
  const body = pemBody(pem)!;
  assert(body && !body.includes("-") && !/\s/.test(body));
  assertEquals(pemBody(pem.replace(/\n/g, "\\n")), body);
  await importAscKey(body);
  await assertRejects(() => importAscKey("geen sleutel"), Error, "asc_key_invalid");
  await assertRejects(() => importAscKey("A".repeat(100)), Error, "asc_key_invalid");
});

Deno.test("configuratie: alle vier nodig en in de juiste vorm; ASC_APP_SKU optioneel", () => {
  const ok: Record<string, string> = { ASC_ISSUER_ID: CFG.issuerId, ASC_KEY_ID: "ABCD123456", ASC_VENDOR: "80000000", ASC_PRIVATE_KEY: "A".repeat(80) };
  const c = ascConfig((k) => ok[k])!;
  assertEquals(c.appSkus, ["nl.lrvdlinden.bingr"]);
  assertEquals(ascConfig((k) => ({ ...ok, ASC_APP_SKU: "BINGR-SKU, nl.lrvdlinden.bingr" })[k])!.appSkus, ["nl.lrvdlinden.bingr", "BINGR-SKU"]);
  for (const k of Object.keys(ok)) assertEquals(ascConfig((x) => (x === k ? "" : ok[x])), null, k);
  assertEquals(ascConfig((k) => ({ ...ok, ASC_VENDOR: "abc" })[k]), null);
  assertEquals(ascConfig((k) => ({ ...ok, ASC_ISSUER_ID: "geen-uuid" })[k]), null);
});

Deno.test("URL van het dagrapport", () => {
  const u = new URL(salesUrl("80000000", "2026-11-05"));
  assertEquals(u.origin + u.pathname, "https://api.appstoreconnect.apple.com/v1/salesReports");
  assertEquals(u.searchParams.get("filter[frequency]"), "DAILY");
  assertEquals(u.searchParams.get("filter[reportType]"), "SALES");
  assertEquals(u.searchParams.get("filter[reportSubType]"), "SUMMARY");
  assertEquals(u.searchParams.get("filter[vendorNumber]"), "80000000");
  assertEquals(u.searchParams.get("filter[reportDate]"), "2026-11-05");
  assertEquals(u.searchParams.get("filter[version]"), "1_1");
});

Deno.test("gzip en TSV: uitpakken, kopregel, lege regels; niet-gzip wordt ook gelezen", async () => {
  const gz = await gzip(REPORT);
  assertEquals(gz[0], 0x1f);
  assertEquals(await gunzipText(gz), REPORT);
  assertEquals(await gunzipText(new TextEncoder().encode(REPORT)), REPORT);
  const rows = parseTsv(REPORT + "\n\n");
  assertEquals(rows.length, 10);
  assertEquals(rows[0]["SKU"], "nl.lrvdlinden.bingr.lifetime");
  assertEquals(rows[0]["Customer Price"], "4.99");
  assertEquals(parseTsv(""), []);
});

Deno.test("filter op het product: SKU = product-id, of een in-app aankoop van de app (Parent Identifier); nooit de app-download", () => {
  const rows = parseTsv(REPORT);
  assert(isOurIap(rows[0], CFG.appSkus));
  assert(isOurIap(rows[5], CFG.appSkus), "Mac");
  assert(!isOurIap(rows[6], CFG.appSkus), "download van de app");
  assert(!isOurIap(rows[7], CFG.appSkus), "andere app");
  assert(isOurIap(rows[8], CFG.appSkus), "via de SKU van de app");
  assert(!isOurIap(rows[8], ["nl.lrvdlinden.bingr"]), "zonder die SKU niet");
});

Deno.test("samenvoegen per soort, land, valuta's, product en prijs; terugbetalingen apart", () => {
  const { rows, matched, skipped } = aggregate("2026-11-05", parseTsv(REPORT), CFG.appSkus);
  assertEquals(matched, 8);
  assertEquals(skipped, 1);
  const nl = rows.find((r) => r.kind === "sale" && r.country === "NL" && r.product_id === "nl.lrvdlinden.bingr.lifetime")!;
  assertEquals(nl.units, 4); // 1 + 2 + Mac 1
  assertEquals(nl.customer_price, 4.99);
  assertEquals(nl.developer_proceeds, 3.48);
  const ref = rows.find((r) => r.kind === "refund")!;
  assertEquals([ref.country, ref.units, ref.customer_price], ["NL", 1, 4.99]);
  const us = rows.find((r) => r.country === "US")!;
  assertEquals([us.customer_currency, us.proceeds_currency, us.developer_proceeds], ["USD", "USD", 4.24]);
  assertEquals(rows.find((r) => r.product_id === "lifetime_ref")?.units, 1);
  assertEquals(rows.length, 5);
  for (const r of rows) assertEquals(r.date, "2026-11-05");
});

Deno.test("samenvoegen: gewogen gemiddelde opbrengst bij verschil binnen één sleutel", () => {
  const t = [HEAD.join("\t"), line(iap({ Units: "1", "Developer Proceeds": "3.00" })), line(iap({ Units: "3", "Developer Proceeds": "4.00" }))].join("\n");
  const { rows } = aggregate("2026-11-05", parseTsv(t), CFG.appSkus);
  assertEquals(rows.length, 1);
  assertEquals(rows[0].units, 4);
  assertEquals(rows[0].developer_proceeds, 3.75);
});

Deno.test("valuta: EUR blijft gelijk, anders de vaste koers, zonder koers null en apart gemeld", () => {
  const rates = cleanFxRates({ USD: 0.92, GBP: "1.15", EUR: 2, xx: 1, JPY: -1, CHF: "abc" });
  assertEquals(rates, { USD: 0.92, GBP: 1.15 });
  assertEquals(toEur(4.99, "EUR", rates), 4.99);
  assertEquals(Math.round(toEur(10, "usd", rates)! * 100), 920);
  assertEquals(toEur(10, "JPY", rates), null);
  const rows: SalesRow[] = [
    { date: "2026-11-05", kind: "sale", product_id: "p", country: "JP", customer_currency: "JPY", proceeds_currency: "JPY", units: 1, customer_price: 800, developer_proceeds: 600 },
    { date: "2026-11-05", kind: "sale", product_id: "p", country: "US", customer_currency: "USD", proceeds_currency: "USD", units: 1, customer_price: 4.99, developer_proceeds: 4.24 },
    { date: "2026-11-05", kind: "sale", product_id: "p", country: "CH", customer_currency: "CHF", proceeds_currency: "EUR", units: 1, customer_price: 5, developer_proceeds: 3.5 },
  ];
  assertEquals(unconverted(rows, rates), ["CHF", "JPY"]);
  assertEquals(cleanFxRates(null), {});
});

Deno.test("dagen: dagelijks de 7 dagen t/m gisteren; bereik inclusief, niet in de toekomst, max. 365", () => {
  const now = Date.UTC(2026, 10, 7, 3, 0, 0);
  assertEquals(dailyDays(now), ["2026-10-31", "2026-11-01", "2026-11-02", "2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"]);
  assertEquals(rangeDays("2026-02-27", "2026-03-01", now), ["2026-02-27", "2026-02-28", "2026-03-01"]);
  assertEquals(rangeDays("2026-11-08", "2026-11-08", now), { error: "bad_range" });
  assertEquals(rangeDays("2026-11-05", "2026-11-01", now), { error: "bad_range" });
  assertEquals(rangeDays("2026-02-30", "2026-03-01", now), { error: "bad_range" });
  assertEquals((rangeDays("2025-11-08", "2026-11-07", now) as string[]).length, 365);
  assertEquals(rangeDays("2025-11-07", "2026-11-07", now), { error: "range_too_long" });
});

Deno.test("ophalen: 200 gzip = rijen, 404 = geen fout (geen verkopen of nog niet klaar), 401/500 = fout; nooit de URL in het resultaat", async () => {
  const gz = await gzip(REPORT);
  const seen: string[] = [];
  const fake = (status: number, body: BodyInit | null) => (url: string, init: RequestInit) => {
    seen.push(url);
    assertEquals((init.headers as Record<string, string>).Authorization, "Bearer jwt-test");
    return Promise.resolve(new Response(body, { status }));
  };
  const ok = await fetchDay(fake(200, gz), CFG, "jwt-test", "2026-11-05");
  assertEquals(ok.result, { date: "2026-11-05", status: "ok", rows: 5, http: 200 });
  assertEquals(ok.rows?.length, 5);
  assert(seen[0].includes("filter%5BreportDate%5D=2026-11-05"));
  const none = await fetchDay(fake(404, JSON.stringify({ errors: [{ code: "NOT_FOUND", detail: "There were no sales for the date specified." }] })), CFG, "jwt-test", "2026-11-06");
  assertEquals(none.result.status, "empty");
  const later = await fetchDay(fake(404, JSON.stringify({ errors: [{ code: "NOT_FOUND", detail: "Report is not available yet." }] })), CFG, "jwt-test", "2026-11-06");
  assertEquals(later.result.status, "not_ready");
  assertEquals((await fetchDay(fake(401, "{}"), CFG, "jwt-test", "2026-11-06")).result, { date: "2026-11-06", status: "error", rows: 0, http: 401 });
  assertEquals((await fetchDay(fake(200, new Uint8Array([0x1f, 0x8b, 1, 2, 3])), CFG, "jwt-test", "2026-11-06")).result.status, "error");
  const thrown = await fetchDay(() => Promise.reject(new Error(salesUrl(CFG.vendor, "2026-11-06"))), CFG, "jwt-test", "2026-11-06");
  assertEquals(thrown.result, { date: "2026-11-06", status: "error", rows: 0 });
  assert(!JSON.stringify([ok.result, none.result, thrown.result]).includes(CFG.vendor));
});

Deno.test("synchroniseren: alleen geslaagde dagen opslaan (idempotent per dag), opslagfout = error; bijgewerkt t/m", async () => {
  const stored: Record<string, number> = {};
  const res = await syncDays(["2026-11-03", "2026-11-04", "2026-11-05", "2026-11-06"], (d) => Promise.resolve(
    d === "2026-11-03" ? { result: { date: d, status: "ok" as const, rows: 2 }, rows: [{} as SalesRow, {} as SalesRow] }
      : d === "2026-11-04" ? { result: { date: d, status: "empty" as const, rows: 0 } }
      : d === "2026-11-05" ? { result: { date: d, status: "ok" as const, rows: 1 }, rows: [{} as SalesRow] }
      : { result: { date: d, status: "not_ready" as const, rows: 0 } }),
    (d, rows) => { if (d === "2026-11-05") return Promise.reject(new Error("db")); stored[d] = rows.length; return Promise.resolve(); }, 2);
  assertEquals(res.map((r) => r.status), ["ok", "empty", "error", "not_ready"]);
  assertEquals(stored, { "2026-11-03": 2 });
  assertEquals(throughDate(res, null), "2026-11-04");
  assertEquals(throughDate(res, "2026-11-10"), "2026-11-10");
  assertEquals(throughDate([], null), null);
  assertEquals(summarizeRun(res), { ok: 1, empty: 1, not_ready: 1, failed: 1, rows: 3 });
});
