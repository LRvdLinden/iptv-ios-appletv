// Build 146: profielen versleuteld (docs/ACCOUNT.md, "Build 146" → "Profielen versleuteld").
// Pure logica (geen database, geen netwerk), getest in profiles_test.ts; de opslag staat in profiles_store.ts.
//
// account_data.sealed = seal({profiles:[…]}) (AES-GCM, BINGR_SOURCES_KEY) is de bron van waarheid. account_data.profiles
// (jsonb) is alleen nog een leesbare kopie voor apps van build 145 en ouder, zolang die er zijn (zie legacyMode).

export const PROFILES_MAX_BYTES = 512 * 1024;
export const PROFILES_MAX_ITEMS = 100; // inclusief tombstones
export const TOMBSTONE_MS = 90 * 864e5;
/** Eerste build die profielen via device-auth leest en schrijft (get_profiles / put_profiles). */
export const PROFILES_BUILD = 146;

// deno-lint-ignore no-explicit-any
type Obj = Record<string, any>;
const isObj = (v: unknown): v is Obj => !!v && typeof v === "object" && !Array.isArray(v);
const ms = (v: unknown) => { const t = Date.parse(String(v ?? "")); return Number.isFinite(t) ? t : 0; };
const key = (p: Obj) => String(p.id ?? "").trim().toLowerCase();
/** Tijd van een versie: de nieuwste van updatedAt en deletedAt (oud formaat zonder tijden = epoch). */
export const stamp = (p: Obj) => Math.max(ms(p.updatedAt), ms(p.deletedAt));
const isTomb = (p: Obj) => p.deleted === true;

/** Velden die nooit in de profielenlijst horen: pincodes staan in state-section profile.<id> (versleuteld). */
const FORBIDDEN = ["pin", "pinHash", "pinCode"];

/** Binnenkomende lijst opschonen: alleen objecten met een id (max. 80 tekens), geen pincodes, max. 100. */
export function cleanProfiles(list: unknown): Obj[] | null {
  if (!Array.isArray(list)) return null;
  const out: Obj[] = [];
  for (const raw of list) {
    if (!isObj(raw)) continue;
    const id = String(raw.id ?? "").trim();
    if (!id || id.length > 80) continue;
    const p: Obj = { ...raw, id };
    for (const f of FORBIDDEN) delete p[f];
    out.push(p);
    if (out.length >= PROFILES_MAX_ITEMS) break;
  }
  return out;
}

/**
 * Samenvoegen per profiel-id (hoofdletterongevoelig, de schrijfwijze van de winnaar blijft):
 * - de versie met de nieuwste tijd (updatedAt, bij een tombstone ook deletedAt) wint; bij gelijke tijd de binnenkomende;
 * - een tombstone wint nooit van een levend hoofdprofiel (isMain): het hoofdprofiel kan niet verwijderd worden;
 * - velden die alleen in de verliezende (levende) versie staan, blijven bewaard (behalve deleted/deletedAt), zodat een
 *   app die een veld nog niet kent het niet wist; een veld wissen = het op null zetten;
 * - een profiel dat alleen op de server staat, blijft staan (verwijderen gaat altijd via een tombstone);
 * - tombstones ouder dan 90 dagen gaan weg.
 * Volgorde: op `order` (onbekend achteraan), dan op id.
 */
export function mergeProfiles(stored: Obj[], incoming: Obj[], nowMs = Date.now()): Obj[] {
  const out = new Map<string, Obj>();
  for (const p of stored) { const k = key(p); if (k) out.set(k, p); }
  for (const p of incoming) {
    const k = key(p);
    if (!k) continue;
    const cur = out.get(k);
    if (!cur) { out.set(k, p); continue; }
    let win: Obj, lose: Obj;
    if (isTomb(p) && !isTomb(cur) && cur.isMain === true) { win = cur; lose = p; }
    else if (isTomb(cur) && !isTomb(p) && p.isMain === true && stamp(cur) > stamp(p)) { win = p; lose = cur; }
    else if (stamp(p) >= stamp(cur)) { win = p; lose = cur; }
    else { win = cur; lose = p; }
    if (!isTomb(win) && !isTomb(lose)) {
      const merged: Obj = { ...win };
      for (const [f, v] of Object.entries(lose)) if (!(f in merged) && f !== "deleted" && f !== "deletedAt") merged[f] = v;
      out.set(k, merged);
    } else out.set(k, win);
  }
  const cut = nowMs - TOMBSTONE_MS;
  return [...out.values()]
    .filter((p) => !(isTomb(p) && stamp(p) < cut))
    .sort((a, b) => {
      const oa = Number.isFinite(Number(a.order)) && a.order !== null ? Number(a.order) : Infinity;
      const ob = Number.isFinite(Number(b.order)) && b.order !== null ? Number(b.order) : Infinity;
      return oa !== ob ? (oa < ob ? -1 : 1) : key(a) < key(b) ? -1 : key(a) > key(b) ? 1 : 0;
    });
}

/** Aantal profielen zonder tombstones (voor het beheer: account_data.profile_count). */
export const liveCount = (list: Obj[]) => list.filter((p) => isObj(p) && !isTomb(p)).length;

/** Zijn twee lijsten inhoudelijk gelijk (zelfde JSON)? Dan hoeft er niets geschreven te worden. */
export const sameList = (a: Obj[], b: Obj[]) => JSON.stringify(a) === JSON.stringify(b);

// ---- overgang voor oude apps ----
/**
 * app_settings.profiles_legacy:
 * - "mirror" (standaard tot de websites over zijn): account_data.profiles blijft een leesbare kopie, voor iedereen;
 * - "auto": alleen een leesbare kopie voor accounts die nog een apparaat met build < 146 hebben, of waar een oude app of
 *   pagina in de afgelopen 30 dagen rechtstreeks schreef (legacy_at); anders wordt de kopie gewist (profiles = []);
 * - "off": nergens een leesbare kopie; rechtstreeks schrijven via REST wordt geweigerd (trigger, 403 "profiles_moved").
 */
export type LegacyMode = "mirror" | "auto" | "off";
export function legacyMode(v: unknown): LegacyMode {
  const s = typeof v === "string" ? v : "";
  return s === "auto" || s === "off" ? s : "mirror";
}
/** Buildnummer uit een app_version als "1.0.1 (146)"; onbekend = 0 (telt als oud). */
export function buildOf(appVersion: unknown): number {
  const m = /\((\d{1,7})\)\s*$/.exec(String(appVersion ?? "").trim());
  return m ? Number(m[1]) : 0;
}
export const LEGACY_WRITE_DAYS = 30;
/** Moet dit account nog een leesbare kopie hebben? */
export function needsMirror(mode: LegacyMode, devices: { app_version?: string | null }[], legacyAt: unknown, nowMs = Date.now()): boolean {
  if (mode === "mirror") return true;
  if (mode === "off") return false;
  if (devices.some((d) => buildOf(d.app_version) < PROFILES_BUILD)) return true;
  const t = ms(legacyAt);
  return t > 0 && nowMs - t < LEGACY_WRITE_DAYS * 864e5;
}
