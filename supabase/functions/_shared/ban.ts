// Geblokkeerd account (blokkade uit het beheer = ban op het auth-account, banned_until). Pure functies, getest in ban_test.ts.
// Contract met de apps (docs/ACCOUNT.md, "Geblokkeerd account"): een functie die een ingelogde gebruiker verwacht, antwoordt
// voor een geblokkeerd account met 401 BANNED_BODY. De apps (build 82) herkennen error "user_banned" / banned: true en tonen
// dan de melding; bij 401 vernieuwen Android en Samsung TV eerst, en dat vernieuwen geeft door de ban ook user_banned.

export const BANNED_BODY = { error: "user_banned", banned: true, reason: "banned" } as const;

/** banned_until van het auth-account ligt in de toekomst. */
export function bannedUntilActive(v: unknown, now = Date.now()): boolean {
  if (v == null || v === "") return false;
  const t = Date.parse(String(v));
  return Number.isFinite(t) && t > now;
}

/** Fout van de auth-server (getUser met een access token van een geblokkeerd account): code user_banned of "banned" in de tekst. */
export function isBanError(e: unknown): boolean {
  if (!e || typeof e !== "object") return false;
  const o = e as { code?: unknown; error_code?: unknown; message?: unknown; msg?: unknown };
  const code = String(o.code ?? o.error_code ?? "").toLowerCase();
  if (code === "user_banned") return true;
  return /banned/i.test(String(o.message ?? o.msg ?? ""));
}
