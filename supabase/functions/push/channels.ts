// Bingr push: versturen via APNs, FCM HTTP v1 en Web Push, zonder externe pushdienst.
// fetch is in te spuiten (tests). Geheimen komen uit function-secrets en komen nooit in een log of antwoord.
import {
  apnsJwt, googleAssertion, importEs256Pkcs8, importRs256Pkcs8, importVapidPrivate, unb64u, vapidAuthorization, encryptWebPush,
} from "./crypto.ts";
import { apnsOutcome, apnsPayload, fcmMessage, fcmOutcome, type Notice, type Outcome, parseWebSub, webPayload, webpushOutcome } from "./logic.ts";

type Env = (k: string) => string | undefined;
type Fetch = typeof fetch;

export type DeviceRow = { id: number; channel: string; token: string; sandbox: boolean; platform: string };

// APNs: HTTP/2 (Deno-fetch onderhandelt h2 via ALPN). Provider token 50 minuten in het geheugen (Apple: max. 60).
export class Apns {
  private jwt: { token: string; at: number } | null = null;
  private key: Promise<CryptoKey> | null = null;
  constructor(private env: Env, private f: Fetch = fetch) {}
  configured() { return !!(this.env("APNS_KEY_P8") && this.env("APNS_KEY_ID") && this.env("APNS_TEAM_ID")); }
  reset() { this.jwt = null; }
  async token(nowMs = Date.now()): Promise<string> {
    if (this.jwt && nowMs - this.jwt.at < 50 * 60_000) return this.jwt.token;
    if (!this.key) { this.key = importEs256Pkcs8(this.env("APNS_KEY_P8")!); this.key.catch(() => { this.key = null; }); }
    const token = await apnsJwt(await this.key, this.env("APNS_KEY_ID")!, this.env("APNS_TEAM_ID")!, Math.floor(nowMs / 1000));
    this.jwt = { token, at: nowMs };
    return token;
  }
  async send(dev: DeviceRow, n: Notice, ttlS = 86400): Promise<Outcome> {
    if (!this.configured()) return { state: "failed", error: "apns_not_configured" };
    const host = dev.sandbox ? "https://api.sandbox.push.apple.com" : "https://api.push.apple.com";
    const res = await this.f(`${host}/3/device/${dev.token}`, {
      method: "POST",
      headers: {
        authorization: `bearer ${await this.token()}`,
        "apns-topic": this.env("APNS_TOPIC") || "nl.lrvdlinden.bingr",
        "apns-push-type": "alert",
        "apns-priority": "10",
        "apns-expiration": String(Math.floor(Date.now() / 1000) + ttlS),
        "apns-collapse-id": String(n.data.msg_id).slice(0, 64),
        "content-type": "application/json",
      },
      body: JSON.stringify(apnsPayload(n)),
    });
    let reason = "";
    if (res.status !== 200) { try { reason = String((await res.json())?.reason ?? ""); } catch { /* geen json */ } }
    else await res.body?.cancel();
    const o = apnsOutcome(res.status, reason);
    if (o.resetAuth) this.reset();
    return o;
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
  reset() { this.access = null; }
  async token(nowMs = Date.now()): Promise<string> {
    if (this.access && nowMs < this.access.until) return this.access.token;
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
  constructor(env: Env, f: Fetch = fetch) { this.apns = new Apns(env, f); this.fcm = new Fcm(env, f); this.web = new WebPush(env, f); }
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
