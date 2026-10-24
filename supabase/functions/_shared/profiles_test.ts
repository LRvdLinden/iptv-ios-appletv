// Tests voor de versleutelde profielen (build 146): samenvoegen, opschonen, overgangsstand en de opslag (met een nep-database).
//   deno test --allow-env supabase/functions/_shared/profiles_test.ts
import { buildOf, cleanProfiles, legacyMode, liveCount, mergeProfiles, needsMirror, TOMBSTONE_MS } from "./profiles.ts";
import { readProfiles, resetModeCache, syncProfiles } from "./profiles_store.ts";
import { openField, sealField, unseal } from "./sealed.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }
Deno.env.set("BINGR_SOURCES_KEY", btoa(String.fromCharCode(...new Uint8Array(32).fill(9))));

const NOW = Date.parse("2026-10-24T12:00:00Z");
const t = (d: string) => `2026-10-${d}T00:00:00Z`;

Deno.test("samenvoegen: nieuwste wint, alleen-server blijft, tombstones, hoofdprofiel", () => {
  const stored = [
    { id: "A", name: "Léon", isMain: true, order: 0, updatedAt: t("01"), accentColor: "gold" },
    { id: "B", name: "Kids", kids: true, order: 1, updatedAt: t("10") },
    { id: "C", name: "Oud", order: 2, updatedAt: t("01") },
  ];
  const incoming = [
    { id: "a", name: "Leon", isMain: true, order: 0, updatedAt: t("05") },          // nieuwer, andere schrijfwijze id
    { id: "B", name: "Kids oud", kids: true, order: 1, updatedAt: t("02") },       // ouder: server blijft
    { id: "C", deleted: true, deletedAt: t("20"), updatedAt: t("20") },            // tombstone wint
    { id: "D", name: "Nieuw", order: 3, updatedAt: t("21") },
  ];
  const m = mergeProfiles(stored, incoming, NOW);
  eq(m.map((p) => p.id), ["a", "B", "D", "C"], "volgorde op order, tombstone zonder order achteraan");
  eq(m[0].name, "Leon"); eq(m[0].accentColor, "gold", "veld dat alleen in de oude versie stond blijft");
  eq(m[1].name, "Kids");
  eq(m[3].deleted, true);
  eq(liveCount(m), 3);
  // tombstone verwijdert het hoofdprofiel nooit
  const keep = mergeProfiles([{ id: "A", name: "Léon", isMain: true, updatedAt: t("01") }], [{ id: "A", deleted: true, deletedAt: t("22") }], NOW);
  eq(keep, [{ id: "A", name: "Léon", isMain: true, updatedAt: t("01") }]);
  // bij gelijke tijd de binnenkomende
  eq(mergeProfiles([{ id: "X", name: "1", updatedAt: t("01") }], [{ id: "X", name: "2", updatedAt: t("01") }], NOW)[0].name, "2");
  // oude tombstones weg; formaat zonder updatedAt = epoch (verliest altijd)
  const old = new Date(NOW - TOMBSTONE_MS - 864e5).toISOString();
  eq(mergeProfiles([{ id: "Z", deleted: true, deletedAt: old }], [], NOW), []);
  eq(mergeProfiles([{ id: "Y", name: "met tijd", updatedAt: t("01") }], [{ id: "Y", name: "zonder tijd" }], NOW)[0].name, "met tijd");
  // een tombstone die het profiel daarna opnieuw aanmaakt (nieuwer) wint, zonder deleted mee te nemen
  const back = mergeProfiles([{ id: "Q", deleted: true, deletedAt: t("01") }], [{ id: "Q", name: "terug", updatedAt: t("02") }], NOW);
  eq(back, [{ id: "Q", name: "terug", updatedAt: t("02") }]);
});

Deno.test("opschonen: geen pincodes, id verplicht, max. 100", () => {
  eq(cleanProfiles("x"), null);
  eq(cleanProfiles([{ id: " P1 ", name: "a", pin: "1234", pinHash: {} }, { name: "zonder id" }, 5, { id: "x".repeat(81) }]), [{ id: "P1", name: "a" }]);
  eq(cleanProfiles(Array.from({ length: 150 }, (_, i) => ({ id: `p${i}` })))!.length, 100);
});

Deno.test("overgangsstand en builds", () => {
  eq(legacyMode(undefined), "mirror"); eq(legacyMode("auto"), "auto"); eq(legacyMode("off"), "off"); eq(legacyMode("x"), "mirror");
  eq(buildOf("1.0.1 (146)"), 146); eq(buildOf("1.0.0 (62)"), 62); eq(buildOf("web"), 0); eq(buildOf(null), 0);
  ok(needsMirror("mirror", [], null, NOW), "mirror altijd");
  ok(!needsMirror("off", [{ app_version: "1.0 (12)" }], null, NOW), "off nooit");
  ok(needsMirror("auto", [{ app_version: "1.0.1 (146)" }, { app_version: "1.0.1 (145)" }], null, NOW), "auto: oud apparaat");
  ok(needsMirror("auto", [{ app_version: null }], null, NOW), "auto: apparaat zonder versie telt als oud");
  ok(!needsMirror("auto", [{ app_version: "1.0.1 (146)" }], null, NOW), "auto: alles nieuw");
  ok(needsMirror("auto", [], new Date(NOW - 5 * 864e5).toISOString(), NOW), "auto: oude pagina schreef kort geleden");
  ok(!needsMirror("auto", [], new Date(NOW - 40 * 864e5).toISOString(), NOW), "auto: lang geleden");
});

// ---- nep-database (alleen wat profiles_store gebruikt) ----
// deno-lint-ignore no-explicit-any
type Row = Record<string, any>;
function fakeDb(tables: Record<string, Row[]>, hooks: { beforeUpdate?: () => void } = {}) {
  const q = (name: string) => {
    const st: { op: string; patch?: Row; filters: [string, unknown][] } = { op: "select", filters: [] };
    const rows = () => (tables[name] ??= []).filter((r) => st.filters.every(([k, v]) => r[k] === v));
    const api: Row = {
      select() { return api; },
      eq(k: string, v: unknown) { st.filters.push([k, v]); return api; },
      maybeSingle() { const r = rows(); return Promise.resolve({ data: r[0] ? { ...r[0] } : null, error: null }); },
      insert(row: Row) {
        const tbl = (tables[name] ??= []);
        if (tbl.some((r) => r.user_id === row.user_id)) return Promise.resolve({ error: { code: "23505", message: "dup" } });
        tbl.push({ ...row }); return Promise.resolve({ error: null });
      },
      update(patch: Row) { st.op = "update"; st.patch = patch; return api; },
      then(res: (v: unknown) => void) {
        if (st.op === "update") {
          hooks.beforeUpdate?.();
          const r = rows(); for (const x of r) Object.assign(x, st.patch);
          return Promise.resolve({ data: r.map((x) => ({ user_id: x.user_id })), error: null }).then(res);
        }
        return Promise.resolve({ data: rows().map((x) => ({ ...x })), error: null }).then(res);
      },
    };
    return api;
  };
  return { from: q };
}
const U = "00000000-0000-4000-8000-000000000001";

Deno.test("migratie: leesbare rij wordt versleuteld; stand mirror houdt de kopie", async () => {
  resetModeCache();
  const plain = [{ id: "A", name: "Léon", isMain: true, order: 0, updatedAt: t("01") }, { id: "B", name: "Kids", order: 1, updatedAt: t("02") }];
  const tables: Record<string, Row[]> = {
    account_data: [{ user_id: U, profiles: plain, sealed: null, updated_at: t("02"), legacy_at: t("02"), plain_cleared: false }],
    account_devices: [{ user_id: U, app_version: "1.0.1 (145)" }], app_settings: [],
  };
  const db = fakeDb(tables);
  const r = await syncProfiles(db, U, null, { nowMs: NOW });
  if ("error" in r) throw new Error(r.error);
  ok(r.wrote, "geschreven");
  const row = tables.account_data[0];
  eq((await unseal(row.sealed)).profiles, plain, "versleuteld gelijk");
  eq(row.profiles, plain, "kopie blijft in mirror");
  eq(row.profile_count, 2); eq(row.plain_cleared, false);
  // nogmaals: niets te doen
  const again = await syncProfiles(db, U, null, { nowMs: NOW });
  ok(!("error" in again) && !again.wrote, "idempotent");
});

Deno.test("stand auto: kopie leeg als alle apparaten nieuw zijn, en terug bij een oud apparaat of directe schrijfactie", async () => {
  resetModeCache();
  const tables: Record<string, Row[]> = {
    account_data: [{ user_id: U, profiles: [{ id: "A", name: "Léon", isMain: true, updatedAt: t("01") }], sealed: null, updated_at: t("01"), legacy_at: null, plain_cleared: false }],
    account_devices: [{ user_id: U, app_version: "1.0.1 (146)" }], app_settings: [{ key: "profiles_legacy", value: "auto" }],
  };
  const db = fakeDb(tables);
  let r = await syncProfiles(db, U, null, { nowMs: NOW });
  if ("error" in r) throw new Error(r.error);
  eq(tables.account_data[0].profiles, [], "kopie leeg"); eq(tables.account_data[0].plain_cleared, true);
  eq(r.list.length, 1, "lijst zelf blijft");
  // nieuwe app wijzigt de naam
  r = await syncProfiles(db, U, [{ id: "A", name: "Leon", isMain: true, updatedAt: t("05") }], { nowMs: NOW });
  if ("error" in r) throw new Error(r.error);
  eq((await readProfiles(db, U)).list[0].name, "Leon");
  eq(tables.account_data[0].profiles, [], "nog steeds geen kopie");
  // oud apparaat meldt zich: kopie terug (zoals legacyMirror in device-auth)
  tables.account_devices.push({ user_id: U, app_version: "1.0.0 (140)" });
  r = await syncProfiles(db, U, null, { nowMs: NOW });
  if ("error" in r) throw new Error(r.error);
  eq(tables.account_data[0].profiles[0].name, "Leon", "kopie terug voor de oude app"); eq(tables.account_data[0].plain_cleared, false);
  // oude app schrijft rechtstreeks (zoals na de trigger: legacy_at, plain_cleared false); de volgende sync neemt het over
  Object.assign(tables.account_data[0], {
    profiles: [{ id: "A", name: "Leon", isMain: true, updatedAt: t("05") }, { id: "K", name: "Van oude app", updatedAt: t("06") }],
    legacy_at: new Date(NOW).toISOString(), updated_at: t("06"),
  });
  r = await syncProfiles(db, U, null, { nowMs: NOW });
  if ("error" in r) throw new Error(r.error);
  eq(r.list.map((p) => p.id), ["A", "K"]);
  eq((await unseal(tables.account_data[0].sealed)).profiles.length, 2, "ook versleuteld");
});

Deno.test("stand off: nergens een kopie; botsing met een gelijktijdige schrijfactie = opnieuw", async () => {
  resetModeCache();
  let bump = 1;
  const tables: Record<string, Row[]> = {
    account_data: [{ user_id: U, profiles: [{ id: "A", name: "x", updatedAt: t("01") }], sealed: null, updated_at: t("01"), legacy_at: null, plain_cleared: false }],
    account_devices: [{ user_id: U, app_version: "1.0.0 (100)" }], app_settings: [{ key: "profiles_legacy", value: "off" }],
  };
  // de eerste update botst: iemand anders verandert updated_at net ervoor
  const db = fakeDb(tables, { beforeUpdate: () => { if (bump-- > 0) tables.account_data[0].updated_at = t("03"); } });
  const r = await syncProfiles(db, U, null, { nowMs: NOW });
  if ("error" in r) throw new Error(r.error);
  eq(tables.account_data[0].profiles, []); eq(tables.account_data[0].plain_cleared, true);
});

Deno.test("nieuw account zonder rij: insert; te groot: too_large", async () => {
  resetModeCache();
  const tables: Record<string, Row[]> = { account_data: [], account_devices: [], app_settings: [] };
  const db = fakeDb(tables);
  const r = await syncProfiles(db, U, [{ id: "A", name: "Nieuw", isMain: true, updatedAt: t("01") }], { nowMs: NOW });
  if ("error" in r) throw new Error(r.error);
  eq(tables.account_data.length, 1); eq(tables.account_data[0].profile_count, 1);
  const none = await syncProfiles(fakeDb({ account_data: [], account_devices: [], app_settings: [] }), U, null, { nowMs: NOW });
  ok(!("error" in none) && !none.wrote && none.updatedAt === null, "leeg account: niets schrijven");
  const big = await syncProfiles(db, U, [{ id: "B", name: "x".repeat(600 * 1024), updatedAt: t("02") }], { nowMs: NOW });
  ok("error" in big && big.error === "too_large", "te groot");
});

Deno.test("velden: enc1-voorvoegsel, oude waarden leesbaar, nooit een fout", async () => {
  const s = await sealField("Journaal");
  ok(s!.startsWith("enc1:") && !s!.includes("Journaal"), "versleuteld");
  eq(await openField(s), "Journaal");
  eq(await openField("leesbaar oud"), "leesbaar oud");
  eq(await openField("enc1:kapot"), "enc1:kapot");
  eq(await sealField(""), null); eq(await sealField(null), null); eq(await openField(null), null);
  ok((await sealField("x")) !== (await sealField("x")), "eigen nonce per keer");
});
