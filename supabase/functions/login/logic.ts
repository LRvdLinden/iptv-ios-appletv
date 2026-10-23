// build 141: logica van de functie login (zonder externe imports, zodat hij los te testen is; logic_test.ts).
// Contract (docs/ACCOUNT.md "Inloggen via de functie login (build 141)"):
//   POST /functions/v1/login {email, password, device_id?, platform?}
//   200: exact het antwoord van /auth/v1/token?grant_type=password (access_token, token_type, expires_in, expires_at,
//        refresh_token, user)
//   400 {error_code:"invalid_credentials", msg} | 400 {error_code:"email_not_confirmed", msg}
//   429 {error_code:"too_many_attempts", msg, retry_after} (per account en per IP/e-mail) | 403 {error_code:"user_banned", msg}
//   503 {error_code:"login_unavailable", msg}
// Het wachtwoord komt nooit in een log of tabel; in de database staan alleen user_id, hashes en tijden.

export type Begin =
  | { status: "continue"; user_id?: string }
  | { status: "rate" | "locked"; retry_after: number };
export type Finish = { status: "ok" } | { status: "locked"; retry_after: number };
export type TokenReply = { status: number; text: string } | null; // null = geen antwoord (netwerk)

export interface Deps {
  begin(email: string): Promise<Begin | null>; // null = databasefout (dan zonder bescherming door)
  finish(userId: string, result: "ok" | "wrong" | "other"): Promise<Finish | null>;
  token(email: string, password: string): Promise<TokenReply>;
  log?(msg: string): void; // alleen statuscodes en soorten, nooit gegevens
}
export type Reply = { status: number; body: string; retryAfter?: number };

export const MAX_EMAIL = 254, MAX_PASSWORD = 200;

const err = (status: number, error_code: string, msg: string, extra: Record<string, unknown> = {}): Reply => ({
  status,
  body: JSON.stringify({ error_code, msg, ...extra }),
  ...(typeof extra.retry_after === "number" ? { retryAfter: extra.retry_after as number } : {}),
});
export const invalid = () => err(400, "invalid_credentials", "Invalid login credentials");
export const unconfirmed = () => err(400, "email_not_confirmed", "Email not confirmed");
export const banned = () => err(403, "user_banned", "User is banned");
export const unavailable = () => err(503, "login_unavailable", "Sign-in is temporarily unavailable. Try again later.");
export function tooMany(seconds: number): Reply {
  const s = Math.max(1, Math.ceil(Number.isFinite(seconds) ? seconds : 60));
  const m = Math.max(1, Math.ceil(s / 60));
  return err(429, "too_many_attempts", `Too many attempts. Try again in ${m} ${m === 1 ? "minute" : "minutes"}.`, { retry_after: s });
}

// e-mailadres zoals GoTrue het opslaat (kleine letters, zonder spaties eromheen); leeg = ongeldig
export function normEmail(v: unknown): string {
  if (typeof v !== "string") return "";
  const e = v.trim().toLowerCase();
  if (!e || e.length > MAX_EMAIL || !/^[^\s@]+@[^\s@]+$/.test(e)) return "";
  return e;
}

// Antwoord van GoTrue (/token?grant_type=password) indelen
export type Kind = "ok" | "wrong" | "unconfirmed" | "banned" | "rate" | "unavailable" | "client";
export function classify(r: TokenReply): { kind: Kind; code: string } {
  if (!r) return { kind: "unavailable", code: "" };
  let j: Record<string, unknown> = {};
  try { const p = JSON.parse(r.text || "{}"); if (p && typeof p === "object") j = p; } catch { /* geen JSON */ }
  const code = String(j.error_code ?? j.code ?? j.error ?? "");
  const text = String(j.msg ?? j.message ?? j.error_description ?? "").toLowerCase();
  if (r.status === 200) return typeof j.access_token === "string" && typeof j.refresh_token === "string"
    ? { kind: "ok", code } : { kind: "unavailable", code };
  if (code === "user_banned" || text.includes("banned")) return { kind: "banned", code };
  if (r.status === 429 || code === "over_request_rate_limit") return { kind: "rate", code };
  if (code === "email_not_confirmed") return { kind: "unconfirmed", code };
  if (code === "invalid_credentials" || code === "invalid_grant") return { kind: "wrong", code };
  if (r.status === 400 || r.status === 422) return { kind: "client", code };
  return { kind: "unavailable", code }; // 401/403 (sleutel, hook) en 5xx: storing aan onze kant
}

export async function handleLogin(input: unknown, deps: Deps): Promise<Reply> {
  const b = (input && typeof input === "object" ? input : {}) as Record<string, unknown>;
  const email = normEmail(b.email);
  const password = typeof b.password === "string" ? b.password : "";
  if (!email || !password || password.length > MAX_PASSWORD) return invalid();

  let begin: Begin | null = null;
  try { begin = await deps.begin(email); } catch { begin = null; }
  if (begin === null) deps.log?.("login: begin mislukt (database), zonder bescherming door");
  else if (begin.status === "rate" || begin.status === "locked") return tooMany(begin.retry_after);
  const uid = begin?.status === "continue" ? begin.user_id : undefined;

  let reply: TokenReply = null;
  try { reply = await deps.token(email, password); } catch { reply = null; }
  const { kind, code } = classify(reply);
  if (kind !== "ok" && kind !== "wrong") deps.log?.(`login: GoTrue ${reply?.status ?? "geen antwoord"} ${kind}${code ? " " + code : ""}`);

  const fin = async (result: "ok" | "wrong" | "other") => {
    if (!uid) return null;
    try { return await deps.finish(uid, result); } catch { return null; }
  };
  switch (kind) {
    case "ok":
      await fin("ok");
      return { status: 200, body: reply!.text };
    case "wrong": {
      const f = await fin("wrong");
      if (f && f.status === "locked") return tooMany(f.retry_after);
      return invalid();
    }
    case "unconfirmed": await fin("other"); return unconfirmed();
    case "banned": await fin("other"); return banned();
    case "rate": await fin("other"); return tooMany(60);
    case "client": await fin("other"); return invalid();
    default: await fin("other"); return unavailable();
  }
}

// Sleutel voor de server-aanroep van /token: een secret key (sb_secret_…, nodig voor Sb-Forwarded-For) uit
// SUPABASE_SECRET_KEYS (JSON {naam: sleutel}); anders null (dan de publishable/anon-sleutel, zonder IP-doorgifte).
export function secretKey(raw: string | undefined | null): string | null {
  if (!raw) return null;
  try {
    const o = JSON.parse(raw);
    if (o && typeof o === "object") {
      const v = (o as Record<string, unknown>).default ?? Object.values(o)[0];
      return typeof v === "string" && v.startsWith("sb_secret_") ? v : null;
    }
  } catch { /* geen JSON */ }
  return null;
}
export function publishableKey(raw: string | undefined | null, legacy: string | undefined | null): string | null {
  if (raw) {
    try {
      const o = JSON.parse(raw);
      const v = o && typeof o === "object" ? ((o as Record<string, unknown>).default ?? Object.values(o)[0]) : null;
      if (typeof v === "string" && v) return v;
    } catch { /* geen JSON */ }
  }
  return legacy || null;
}
