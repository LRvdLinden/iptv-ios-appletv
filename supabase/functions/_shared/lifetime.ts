// Build 167: Bingr wordt alleen Lifetime (contract in docs/ACCOUNT.md, "Build 167: alleen Lifetime"). Pure logica zonder
// database of netwerk, gedeeld door device-auth (entitlements, stream_start), billing (checkout met code, config),
// stripe-webhook (code gebruikt) en de functie lifetime (codes en mail). Getest in lifetime_test.ts.
//   app_settings.lifetime_only = {enabled, announce_at, cutover_at, discount_pct, code_valid_until, trial_days,
//                                 new_paid_from, new_paid_from_apple}   (build 168: nieuwe accounts eerst kopen, per platformgroep)
//   app_settings.iap            = {apple}            (koopknop in de Apple-apps, StoreKit)
//   app_settings.upgrade_link   = {…, apple_eu}      (EU External Purchase Link in de Apple-apps)
// Zolang enabled false is (standaard) verandert er niets: access is altijd "full" en lifetime_only ontbreekt.
import { APPLE_PRODUCT_ID } from "./apple.ts";
import { type Entitlements, linkGroup, normalizePlan, normalizePlatform, type Platform, PRICE_CENTS } from "./plans.ts";

export type LifetimeSettings = {
  enabled: boolean; announce_at: string | null; cutover_at: string | null; discount_pct: number;
  code_valid_until: string | null; trial_days: number;
  /** build 168: accounts die op of na dit moment zijn aangemaakt, moeten eerst kopen (Android, Android TV, web/Windows) */
  new_paid_from: string | null;
  /** build 168: hetzelfde voor de Apple-apps (iOS, iPadOS, tvOS, macOS); pas na de goedkeuring van Apple */
  new_paid_from_apple: string | null;
};
export const DEFAULT_LIFETIME: LifetimeSettings = {
  enabled: false, announce_at: null, cutover_at: null, discount_pct: 30, code_valid_until: null, trial_days: 0,
  new_paid_from: null, new_paid_from_apple: null,
};
/** Aanvulling 2: de vaste overgang (1 december 2026 00:00 Europe/Amsterdam), standaard in app_settings en voorstel in het
 *  beheer; de code werkt tot dit moment (t/m 30 november 23:59). Zolang enabled false is, doet hij niets. */
export const DEFAULT_CUTOVER = "2026-12-01T00:00:00+01:00";
export type IapSettings = { apple: boolean };
export const DEFAULT_IAP: IapSettings = { apple: false };
export const DISCOUNT_MIN = 1, DISCOUNT_MAX = 90, TRIAL_MAX = 90;
const DAY = 86_400_000;

const iso = (v: unknown): string | null => {
  if (typeof v !== "string" || !v.trim() || v.length > 40) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? v.trim() : null;
};
const intIn = (v: unknown, lo: number, hi: number, d: number) => (Number.isInteger(v) && (v as number) >= lo && (v as number) <= hi ? v as number : d);

/** app_settings.lifetime_only lezen; ontbrekend of ongeldig = standaard (uit). */
export function normalizeLifetime(v: unknown): LifetimeSettings {
  const o = v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {};
  return {
    enabled: o.enabled === true,
    announce_at: iso(o.announce_at),
    cutover_at: iso(o.cutover_at),
    discount_pct: intIn(o.discount_pct, DISCOUNT_MIN, DISCOUNT_MAX, DEFAULT_LIFETIME.discount_pct),
    code_valid_until: iso(o.code_valid_until),
    trial_days: intIn(o.trial_days, 0, TRIAL_MAX, 0),
    new_paid_from: iso(o.new_paid_from),
    new_paid_from_apple: iso(o.new_paid_from_apple),
  };
}
export function normalizeIap(v: unknown): IapSettings {
  const o = v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : {};
  return { apple: o.apple === true };
}
/** upgrade_link.apple_eu (EU External Purchase Link), standaard false. */
export const euAppleLink = (v: unknown): boolean =>
  !!v && typeof v === "object" && !Array.isArray(v) && (v as Record<string, unknown>).apple_eu === true;
/** Tot wanneer de codes gelden: code_valid_until, anders cutover_at. */
export const codeValidUntil = (s: LifetimeSettings): string | null => s.code_valid_until ?? s.cutover_at;

// ---------------- build 168: nieuwe accounts eerst kopen (per platformgroep) ----------------
/**
 * Platformgroep voor new_paid_from: "apple" (ios, ipados, tvos, macos) of "other" (android, androidtv, web = ook Windows,
 * en de oude tv-apps). Onbekend platform (null) = "other": bij de toegang is dat de strenge kant, want de Apple-apps
 * melden hun platform altijd (body.platform of het geregistreerde apparaat).
 */
export type PaidGroup = "apple" | "other";
export const paidGroup = (p: Platform | null | undefined): PaidGroup => (p && linkGroup(p) === "apple" ? "apple" : "other");
/** De ingestelde datum van die groep (ook als hij nog in de toekomst ligt), of null. */
export const newPaidDate = (s: LifetimeSettings, g: PaidGroup): string | null => (g === "apple" ? s.new_paid_from_apple : s.new_paid_from);
/** Geldt de regel nu voor die groep? Lifetime-only aan, datum gezet en nu ≥ datum. Geeft het moment (ms) of null. */
export function newPaidActive(s: LifetimeSettings, g: PaidGroup, now = Date.now()): number | null {
  const d = s.enabled ? newPaidDate(s, g) : null;
  const t = d ? Date.parse(d) : NaN;
  return Number.isFinite(t) && now >= t ? t : null;
}
/** Valt dit account onder de regel (aangemaakt op of na de datum van zijn platformgroep, en die datum is voorbij)? */
export function newPaidSubject(s: LifetimeSettings, g: PaidGroup, createdAt: string | null | undefined, now = Date.now()): boolean {
  const t = newPaidActive(s, g, now);
  const c = createdAt ? Date.parse(createdAt) : NaN;
  return t !== null && Number.isFinite(c) && c >= t;
}
/**
 * De overgang die voor dit account op dit platform geldt: new_paid_from(_apple) voor een account onder de regel, anders
 * cutover_at. Zo zijn "na de overgang", de proefperiode en cutover_at in entitlements per account juist.
 */
export function effectiveCutover(s: LifetimeSettings, g: PaidGroup, createdAt: string | null | undefined, now = Date.now()): string | null {
  return newPaidSubject(s, g, createdAt, now) ? newPaidDate(s, g) : s.cutover_at;
}

// ---------------- toegang ----------------
export type Access = "full" | "activate";
/**
 * Proefperiode: alleen voor accounts die op of na cutover_at zijn aangemaakt (build 168: of onder de regel "nieuwe
 * accounts eerst kopen" vallen), en alleen met trial_days > 0. Zonder `group` (oudere aanroepers): alleen cutover_at.
 */
export function trialUntil(s: LifetimeSettings, createdAt: string | null | undefined, group?: PaidGroup, now = Date.now()): string | null {
  if (!s.enabled || s.trial_days <= 0 || !createdAt) return null;
  const c = Date.parse(createdAt);
  if (!Number.isFinite(c)) return null;
  const cut = s.cutover_at ? Date.parse(s.cutover_at) : NaN;
  const afterCut = Number.isFinite(cut) && c >= cut;
  if (!afterCut && !(group && newPaidSubject(s, group, createdAt, now))) return null;
  return new Date(c + s.trial_days * DAY).toISOString();
}
/**
 * "activate" = alleen het scherm Activeer Lifetime: Lifetime-only staat aan, de overgang van dit account is voorbij, het
 * account is niet Lifetime en heeft geen lopende proefperiode. In alle andere gevallen "full".
 * De overgang van het account is cutover_at, of (build 168) new_paid_from van zijn platformgroep als het account op of na
 * die datum is aangemaakt. `platform` ontbreekt (oudere aanroepers) of is onbekend = groep "other" (de strenge kant).
 * Met new_paid_from en new_paid_from_apple null is de uitkomst precies zoals in build 167.
 */
export function accessFor(s: LifetimeSettings, plan: unknown, createdAt: string | null | undefined, now = Date.now(),
  platform: Platform | null = null): { access: Access; trial_until: string | null } {
  const g = paidGroup(platform);
  const trial = trialUntil(s, createdAt, g, now);
  if (!s.enabled || !s.cutover_at || normalizePlan(plan) === "lifetime") return { access: "full", trial_until: normalizePlan(plan) === "lifetime" ? null : trial };
  const eff = effectiveCutover(s, g, createdAt, now);
  const cut = eff ? Date.parse(eff) : NaN;
  if (!Number.isFinite(cut) || now < cut) return { access: "full", trial_until: trial };
  if (trial && Date.parse(trial) > now) return { access: "full", trial_until: trial };
  return { access: "activate", trial_until: trial };
}
export const ACTIVATION_REQUIRED = { error: "activation_required", plan: "free" } as const;

// ---------------- kortingscodes ----------------
// Vorm BINGR-XXXX-XXXX zonder verwarrende tekens (geen 0/O, 1/I/L): 31 tekens, 8 posities = ± 8,5 × 10^11 codes.
export const CODE_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789";
export const CODE_RE = new RegExp(`^BINGR-[${CODE_ALPHABET}]{4}-[${CODE_ALPHABET}]{4}$`);
export function randomCode(rand: (n: number) => Uint8Array = (n) => crypto.getRandomValues(new Uint8Array(n))): string {
  // zonder modulo-scheefheid: alleen bytes < 248 (= 8 × 31) gebruiken
  const out: string[] = [];
  while (out.length < 8) for (const b of rand(16)) if (b < 248 && out.length < 8) out.push(CODE_ALPHABET[b % 31]);
  return `BINGR-${out.slice(0, 4).join("")}-${out.slice(4).join("")}`;
}
/** Wat iemand intypt (spaties, kleine letters, zonder streepjes) naar de vaste vorm; ongeldig = null. */
export function normalizeCode(v: unknown): string | null {
  if (typeof v !== "string" || v.length > 40) return null;
  let s = v.toUpperCase().replace(/[\s_-]+/g, "");
  if (s.startsWith("BINGR")) s = s.slice(5);
  if (s.length !== 8) return null;
  const c = `BINGR-${s.slice(0, 4)}-${s.slice(4)}`;
  return CODE_RE.test(c) ? c : null;
}

export type CodeRow = {
  user_id: string; code: string; stripe_promotion_code_id: string | null; expires_at: string | null; redeemed_at: string | null;
};
export type CodeCheck = { ok: true; row: CodeRow } | { ok: false; reason: "not_found" | "other_account" | "redeemed" | "expired" | "not_ready" };
/** Mag dit account deze code nu gebruiken? Eén keer, alleen door het eigen account, tot en met expires_at. */
export function checkCode(row: CodeRow | null | undefined, userId: string, now = Date.now()): CodeCheck {
  if (!row) return { ok: false, reason: "not_found" };
  if (String(row.user_id).toLowerCase() !== userId.toLowerCase()) return { ok: false, reason: "other_account" };
  if (row.redeemed_at) return { ok: false, reason: "redeemed" };
  const exp = row.expires_at ? Date.parse(row.expires_at) : NaN;
  if (!Number.isFinite(exp) || now > exp) return { ok: false, reason: "expired" };
  if (!row.stripe_promotion_code_id || !/^promo_[A-Za-z0-9]+$/.test(row.stripe_promotion_code_id)) return { ok: false, reason: "not_ready" };
  return { ok: true, row };
}
/** Prijs na korting (centen), zoals Stripe rekent: korting = afgerond percentage van de prijs. */
export const priceAfter = (cents: number, pct: number) => cents - Math.round((cents * pct) / 100);

// ---------------- entitlements ----------------
export type LifetimeView = {
  enabled: true; announced: boolean; cutover_at: string | null; code: string | null; code_valid_until: string | null;
  discount_pct: number; trial_until: string | null;
  /** build 168: alleen aanwezig (true) als dit account onder "nieuwe accounts eerst kopen" valt op dit platform */
  new_paid?: true;
};
export type LifetimeEntitlements = Entitlements & {
  access: Access;
  iap: { apple: boolean; product_id: string };
  upgrade: Entitlements["upgrade"] & { link_eu_apple: boolean };
  lifetime_only?: LifetimeView;
};
export type LifetimeContext = {
  settings: LifetimeSettings; iap: IapSettings; euApple: boolean; platform: Platform | null;
  createdAt: string | null | undefined;
  /** eigen code van het account (of null), alleen nodig als enabled */
  code?: CodeRow | null;
  now?: number;
};
/**
 * Entitlements van build 167: het bestaande object (plans.ts) met access, iap en upgrade.link_eu_apple erbij, en
 * lifetime_only als Lifetime-only aan staat. Bestaande velden veranderen nooit. De code staat er alleen in voor een
 * Gratis-account met een bruikbare code en nooit op een Apple-platform (korting buiten Apple om).
 */
export function withLifetime(base: Entitlements, c: LifetimeContext): LifetimeEntitlements {
  const now = c.now ?? Date.now();
  const s = c.settings;
  const a = accessFor(s, base.plan, c.createdAt, now, c.platform);
  const out: LifetimeEntitlements = {
    ...base,
    access: a.access,
    iap: { apple: c.iap.apple, product_id: APPLE_PRODUCT_ID },
    upgrade: { ...base.upgrade, link_eu_apple: c.euApple },
  };
  if (s.enabled) {
    const apple = c.platform ? linkGroup(c.platform) === "apple" : false;
    // build 168: een account onder "nieuwe accounts eerst kopen" heeft geen korting (die is voor bestaande accounts) en
    // als overgang de datum van zijn platformgroep (in het verleden)
    const subject = base.plan !== "lifetime" && newPaidSubject(s, paidGroup(c.platform), c.createdAt, now);
    // c.code is al de rij van dit account (device-auth leest hem op user_id)
    const usable = base.plan !== "lifetime" && !apple && !subject && c.code ? checkCode(c.code, String(c.code.user_id), now) : null;
    const ann = s.announce_at ? Date.parse(s.announce_at) : NaN;
    out.lifetime_only = {
      enabled: true,
      announced: Number.isFinite(ann) && now >= ann,
      cutover_at: subject ? newPaidDate(s, paidGroup(c.platform)) : s.cutover_at,
      code: usable?.ok ? usable.row.code : null,
      code_valid_until: usable?.ok ? usable.row.expires_at : null,
      discount_pct: s.discount_pct,
      trial_until: a.trial_until,
    };
    if (subject) out.lifetime_only.new_paid = true;
  }
  return out;
}

// ---------------- Stripe: coupon en promotion codes ----------------
/** Vaste coupon-id per korting en einddatum, zodat aanmaken idempotent is (GET eerst, anders POST met deze id). */
export function couponId(pct: number, validUntil: string): string {
  const d = new Date(Date.parse(validUntil)).toISOString().slice(0, 10).replace(/-/g, "");
  return `bingr_lifetime_${pct}_${d}`;
}
const unix = (isoTime: string) => String(Math.floor(Date.parse(isoTime) / 1000));
/** POST /v1/coupons: percent_off, één keer, in te wisselen tot validUntil. */
export function couponParams(pct: number, validUntil: string): [string, string][] {
  return [
    ["id", couponId(pct, validUntil)], ["percent_off", String(pct)], ["duration", "once"], ["redeem_by", unix(validUntil)],
    ["name", `Bingr Lifetime ${pct}%`], ["metadata[bingr]", "lifetime_only"],
  ];
}
/** POST /v1/promotion_codes: de code van één account, max. 1 keer, verloopt op validUntil. */
export function promotionParams(coupon: string, code: string, userId: string, validUntil: string): [string, string][] {
  return [
    // met de vastgezette Stripe-Version van _shared/stripe.ts (2025-03-31.basil) heet de parameter `coupon`
    ["coupon", coupon], ["code", code], ["max_redemptions", "1"], ["expires_at", unix(validUntil)],
    ["metadata[user_id]", userId], ["metadata[bingr]", "lifetime_only"],
  ];
}
export const promotionIdempotencyKey = (userId: string, code: string) => `bingr-lifetime-promo-${userId.toLowerCase()}-${code}`;

/** Promotion code die bij een betaalde Checkout Session gebruikt is (discounts of onze eigen metadata), anders null. */
// deno-lint-ignore no-explicit-any
export function promotionCodeOf(s: Record<string, any> | null | undefined): string | null {
  const ok = (v: unknown): v is string => typeof v === "string" && /^promo_[A-Za-z0-9]+$/.test(v) && v.length <= 255;
  for (const d of Array.isArray(s?.discounts) ? s!.discounts : []) {
    const p = typeof d?.promotion_code === "string" ? d.promotion_code : d?.promotion_code?.id;
    if (ok(p)) return p;
  }
  const m = s?.metadata?.promotion_code;
  return ok(m) ? m : null;
}

// ---------------- build 168: publieke billing config per platformgroep ----------------
/**
 * Platformgroep van een aanvraag aan de publieke `billing config`. Eerst `platform` (body of ?platform=; de website en de
 * webspeler sturen "web"), anders de User-Agent:
 *   - Apple-apps (URLSession): "Bingr/<build> CFNetwork/… Darwin/…"  → apple
 *   - Android en Android TV (OkHttp): "Bingr v<versie>"                → other
 *   - browsers (website, webspeler, Windows-app via WebView2): "Mozilla/…" → other
 * Onbekend = "apple": de voorzichtige kant voor het welkomstscherm (de Apple-apps mogen nooit te vroeg wisselen). Het is
 * alleen het welkomstscherm; de toegang zelf bepaalt device-auth per account en platform.
 */
export function configGroup(platform: unknown, userAgent: string | null | undefined): PaidGroup {
  const p = normalizePlatform(platform);
  if (p) return paidGroup(p);
  const ua = String(userAgent ?? "").slice(0, 300);
  if (/CFNetwork\/|Darwin\//i.test(ua)) return "apple";
  if (/^Bingr v\d/i.test(ua) || /okhttp\//i.test(ua)) return "other";
  if (/^Mozilla\//i.test(ua)) return "other";
  return "apple";
}
export type PublicLifetime = {
  enabled: boolean; cutover_at: string | null; after_cutover: boolean; trial_days: number; announce_at: string | null; announced: boolean;
  new_paid?: true; new_paid_from?: string;
};
/**
 * `lifetime_only` van de publieke `billing config` (zonder code; die voegt billing toe voor een ingelogd account).
 *   - Niet ingelogd (`account` ontbreekt): after_cutover = cutover_at voorbij, of de regel "nieuwe accounts eerst kopen"
 *     geldt voor deze platformgroep (dan ook new_paid: true en new_paid_from). Zo wisselt het welkomstscherm van de apps
 *     (Apple 167, Android 167, webspeler) zonder app-wijziging.
 *   - Ingelogd: per account. Een bestaand account (van vóór new_paid_from) ziet after_cutover pas na cutover_at, dus geen
 *     "Gratis is gestopt" vóór 1 december; een account onder de regel krijgt after_cutover true en new_paid.
 * Met new_paid_from en new_paid_from_apple null precies zoals build 167.
 */
export function publicLifetime(s: LifetimeSettings, group: PaidGroup, now = Date.now(), account?: { createdAt: string | null | undefined }): PublicLifetime {
  const on = s.enabled;
  const cut = on && s.cutover_at ? Date.parse(s.cutover_at) : NaN;
  const ann = on && s.announce_at ? Date.parse(s.announce_at) : NaN;
  const out: PublicLifetime = {
    enabled: on, cutover_at: on ? s.cutover_at : null, after_cutover: Number.isFinite(cut) && now >= cut,
    trial_days: on ? s.trial_days : 0, announce_at: on ? s.announce_at : null, announced: Number.isFinite(ann) && now >= ann,
  };
  if (!on || !s.cutover_at) return out;
  const np = account ? newPaidSubject(s, group, account.createdAt, now) : newPaidActive(s, group, now) !== null;
  if (np) {
    out.after_cutover = true;
    out.new_paid = true;
    out.new_paid_from = newPaidDate(s, group)!;
  }
  return out;
}
