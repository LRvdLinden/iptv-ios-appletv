// Bingr push: versturen via APNs, FCM HTTP v1 en Web Push, zonder externe pushdienst.
// fetch is in te spuiten (tests). Geheimen komen uit function-secrets en komen nooit in een log of antwoord.
import {
  apnsJwt, googleAssertion, importEs256Pkcs8, importRs256Pkcs8, importVapidPrivate, unb64u, vapidAuthorization, encryptWebPush,
} from "./crypto.ts";
import { apnsOutcome, apnsPayload, fcmMessage, fcmOutcome, type Notice, type Outcome, parseWebSub, webPayload, webpushOutcome } from "./logic.ts";

type Env = (k: string) => string | undefined;
type Fetch = typeof fetch;

export type DeviceRow = { id: number; channel: string; token: string; sandbox: boolean; platform: string };

// APNs: HTTP/2 (Deno-fetch onderhandelt h2 via ALPN). Providertoken (JWT): Apple wil hem hoogstens één keer per 20 minuten
// vernieuwd zien en uiterlijk na 60 minuten (anders 429 TooManyProviderTokenUpdates, resp. 403 ExpiredProviderToken).
// Elke instantie van de functie (elke minuut de cron, het beheer, support) maakte vroeger een eigen token en 20 workers
// tegelijk elk nog een: Apple weigerde dan het grootste deel met TooManyProviderTokenUpdates. Nu:
//  - één token per instantie tegelijk (gedeelde promise);
//  - gedeeld tussen instanties via `store` (tabel push_provider_tokens, versleuteld), hergebruikt tot 50 minuten oud;
//  - iat op een vast blok van 30 minuten (apnsIat), zodat ook instanties zonder store hetzelfde tijdstip gebruiken.
export type TokenStore = {
  load(name: string): Promise<{ token: string; iat: number } | null>;
  /** Bewaart het token, tenzij er al een even nieuw of nieuwer staat; geeft het token dat nu geldt (de winnaar). */
  save(name: string, token: string, iat: number): Promise<{ token: string; iat: number } | null>;
};
export const APNS_TOKEN_MAX_AGE_S = 50 * 60;
export const APNS_TOKEN_BLOCK_S = 30 * 60;
/** iat voor een nieuw providertoken: begin van het blok van 30 minuten (alle instanties hetzelfde), of nu bij `fresh`. */
export function apnsIat(nowS: number, fresh = false): number {
  return fresh ? nowS : Math.floor(nowS / APNS_TOKEN_BLOCK_S) * APNS_TOKEN_BLOCK_S;
}
/** Bruikbaar providertoken: niet uit de toekomst (1 minuut speling) en jonger dan 50 minuten. */
export const apnsTokenUsable = (iat: number, nowS: number) => iat <= nowS + 60 && nowS - iat < APNS_TOKEN_MAX_AGE_S;

export class Apns {
  private jwt: { token: string; iat: number } | null = null;
  private pending: Promise<string> | null = null;
  private key: Promise<CryptoKey> | null = null;
  private resetAt = 0;
  private fresh = false;
  constructor(private env: Env, private f: Fetch = fetch, private store?: TokenStore) {}
  configured() { return !!(this.env("APNS_KEY_P8") && this.env("APNS_KEY_ID") && this.env("APNS_TEAM_ID")); }
  /** Na 403 Expired/InvalidProviderToken: één keer per 20 minuten een nieuw token (met iat = nu). */
  reset(nowMs = Date.now()) {
    if (nowMs - this.resetAt < 20 * 60_000) return;
    this.resetAt = nowMs; this.jwt = null; this.fresh = true;
  }
  async token(nowMs = Date.now()): Promise<string> {
    const nowS = Math.floor(nowMs / 1000);
    if (this.jwt && apnsTokenUsable(this.jwt.iat, nowS)) return this.jwt.token;
    if (!this.pending) {
      this.pending = this.obtain(nowS).finally(() => { this.pending = null; });
    }
    return await this.pending;
  }
  private async obtain(nowS: number): Promise<string> {
    const name = `apns:${this.env("APNS_KEY_ID") ?? ""}`;
    if (this.store && !this.fresh) {
      try {
        const s = await this.store.load(name);
        if (s && apnsTokenUsable(s.iat, nowS)) { this.jwt = s; return s.token; }
      } catch { /* zonder gedeeld token verder */ }
    }
    if (!this.key) { this.key = importEs256Pkcs8(this.env("APNS_KEY_P8")!); this.key.catch(() => { this.key = null; }); }
    const iat = apnsIat(nowS, this.fresh);
    const token = await apnsJwt(await this.key, this.env("APNS_KEY_ID")!, this.env("APNS_TEAM_ID")!, iat);
    this.fresh = false;
    this.jwt = { token, iat };
    if (this.store) {
      try {
        const w = await this.store.save(name, token, iat);
        if (w && apnsTokenUsable(w.iat, nowS)) this.jwt = w; // een andere instantie was net eerder: dat token gebruiken
      } catch { /* volgende keer opnieuw */ }
    }
    return this.jwt.token;
  }
  async send(dev: DeviceRow, n: Notice, ttlS = 86400): Promise<Outcome> {
    return await this.post(dev.token, dev.sandbox, apnsPayload(n), { collapseId: String(n.data.msg_id), ttlS });
  }
  // Eén melding met een eigen payload en (optioneel) een ander topic, bv. de beheer-app (BEHEER_APNS_TOPIC). Zelfde sleutel:
  // een APNs-providertoken geldt voor alle apps van het team.
  async post(token: string, sandbox: boolean, payload: unknown, o: { topic?: string; collapseId?: string; ttlS?: number } = {}): Promise<Outcome> {
    if (!this.configured()) return { state: "failed", error: "apns_not_configured" };
    const host = sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
    const headers: Record<string, string> = {
      authorization: `bearer ${await this.token()}`,
      "apns-topic": o.topic || this.env("APNS_TOPIC") || "nl.lrvdlinden.bingr",
      "apns-push-type": "alert",
      "apns-priority": "10",
      "apns-expiration": String(Math.floor(Date.now() / 1000) + (o.ttlS ?? 86400)),
      "content-type": "application/json",
    };
    if (o.collapseId) headers["apns-collapse-id"] = o.collapseId.slice(0, 64);
    const res = await this.f(`${host}/3/device/${token}`, { method: "POST", headers, body: JSON.stringify(payload) });
    let reason = "";
    if (res.status !== 200) { try { reason = String((await res.json())?.reason ?? ""); } catch { /* geen json */ } }
    else await res.body?.cancel();
    const out = apnsOutcome(res.status, reason);
    if (out.resetAuth) this.reset();
    return out;
  }
}

// FCM HTTP v1: OAuth2-access-token uit het serviceaccount (JWT RS256 -> oauth2.googleapis.com/token), in het geheugen
// tot 5 minuten voor het verloopt.
export class Fcm {
  private access: { token: string; until: number } | null = null;
  constructor(private env: Env, private f: Fetch = fetch) {}
  private sa(): { client_email: string; private_key: string; private_key_id?: string; project_id?: string } | null {
    try {
      const j = JSON.parse(this.env("FCM_SERVICE_ACCOUNT") ?? "");
      return j?.client_email && j?.private_key ? j : null;
    } catch { return null; }
  }
  project() { return this.env("FCM_PROJECT_ID") || this.sa()?.project_id || ""; }
  configured() { return !!(this.sa() && this.project()); }
  private pending: Promise<string> | null = null;
  reset() { this.access = null; }
  // één OAuth-aanvraag tegelijk (anders vroegen 20 workers er elk een aan)
  async token(nowMs = Date.now()): Promise<string> {
    if (this.access && nowMs < this.access.until) return this.access.token;
    if (!this.pending) this.pending = this.fetchToken(nowMs).finally(() => { this.pending = null; });
    return await this.pending;
  }
  private async fetchToken(nowMs: number): Promise<string> {
    const sa = this.sa()!;
    const assertion = await googleAssertion(await importRs256Pkcs8(sa.private_key), sa.client_email, sa.private_key_id, Math.floor(nowMs / 1000));
    const res = await this.f("https://oauth2.googleapis.com/token", {
      method: "POST",
      headers: { "content-type": "application/x-www-form-urlencoded" },
      body: new URLSearchParams({ grant_type: "urn:ietf:params:oauth:grant-type:jwt-bearer", assertion }).toString(),
    });
    const j = await res.json().catch(() => ({}));
    if (!res.ok || !j?.access_token) throw new Error(`fcm_oauth_${res.status}`);
    this.access = { token: j.access_token, until: nowMs + Math.max(60, Number(j.expires_in ?? 3600) - 300) * 1000 };
    return this.access.token;
  }
  async send(dev: DeviceRow, n: Notice, ttlS = 86400): Promise<Outcome> {
    if (!this.configured()) return { state: "failed", error: "fcm_not_configured" };
    let tok: string;
    try { tok = await this.token(); } catch (e) { return { state: "retry", error: e instanceof Error ? e.message : "fcm_oauth" }; }
    const res = await this.f(`https://fcm.googleapis.com/v1/projects/${encodeURIComponent(this.project())}/messages:send`, {
      method: "POST",
      headers: { authorization: `Bearer ${tok}`, "content-type": "application/json" },
      body: JSON.stringify(fcmMessage(dev.token, n, ttlS)),
    });
    const body = res.status === 200 ? (await res.body?.cancel(), null) : await res.json().catch(() => null);
    const o = fcmOutcome(res.status, body);
    if (o.resetAuth) this.reset();
    return o;
  }
}

// Web Push: RFC 8291 (aes128gcm) + VAPID (RFC 8292). VAPID-JWT per origin 6 uur in het geheugen (geldig 12 uur).
export class WebPush {
  private key: Promise<CryptoKey> | null = null;
  private auth = new Map<string, { value: string; at: number }>();
  constructor(private env: Env, private f: Fetch = fetch) {}
  configured() { return !!(this.env("VAPID_PRIVATE_KEY") && this.env("VAPID_PUBLIC_KEY")); }
  private async authorization(endpoint: string, nowMs = Date.now()) {
    const origin = new URL(endpoint).origin;
    const c = this.auth.get(origin);
    if (c && nowMs - c.at < 6 * 3600_000) return c.value;
    if (!this.key) { this.key = importVapidPrivate(this.env("VAPID_PRIVATE_KEY")!, this.env("VAPID_PUBLIC_KEY")!); this.key.catch(() => { this.key = null; }); }
    const value = await vapidAuthorization(endpoint, await this.key, this.env("VAPID_PUBLIC_KEY")!,
      this.env("VAPID_SUBJECT") || "mailto:support@bingr.online", Math.floor(nowMs / 1000));
    this.auth.set(origin, { value, at: nowMs });
    return value;
  }
  async send(dev: DeviceRow, n: Notice, ttlS = 86400): Promise<Outcome> {
    if (!this.configured()) return { state: "failed", error: "webpush_not_configured" };
    const sub = parseWebSub(dev.token);
    if (!sub) return { state: "invalid", error: "webpush_bad_subscription" };
    const body = await encryptWebPush(new TextEncoder().encode(JSON.stringify(webPayload(n))), unb64u(sub.p256dh), unb64u(sub.auth));
    const res = await this.f(sub.endpoint, {
      method: "POST",
      headers: {
        authorization: await this.authorization(sub.endpoint),
        "content-encoding": "aes128gcm",
        "content-type": "application/octet-stream",
        ttl: String(ttlS),
        urgency: "high",
        topic: `bingr${n.data.msg_id}`.replace(/[^A-Za-z0-9_-]/g, "").slice(0, 32),
      },
      body,
      redirect: "manual",
    });
    await res.body?.cancel();
    return webpushOutcome(res.status);
  }
}

export class Channels {
  apns: Apns; fcm: Fcm; web: WebPush;
  constructor(env: Env, f: Fetch = fetch, store?: TokenStore) { this.apns = new Apns(env, f, store); this.fcm = new Fcm(env, f); this.web = new WebPush(env, f); }
  async send(dev: DeviceRow, n: Notice, ttlS?: number): Promise<Outcome> {
    try {
      if (dev.channel === "apns") return await this.apns.send(dev, n, ttlS);
      if (dev.channel === "fcm") return await this.fcm.send(dev, n, ttlS);
      if (dev.channel === "webpush") return await this.web.send(dev, n, ttlS);
      return { state: "failed", error: "unknown_channel" };
    } catch (e) {
      // netwerkfout of time-out: later nog eens (de melding zelf bevat geen geheimen)
      return { state: "retry", error: `network_${(e instanceof Error ? e.name : "error").slice(0, 40)}` };
    }
  }
}
