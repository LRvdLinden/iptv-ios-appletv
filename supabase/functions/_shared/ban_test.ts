// deno test supabase/functions/_shared/ban_test.ts
import { BANNED_BODY, bannedUntilActive, isBanError } from "./ban.ts";
function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

Deno.test("banned_until: alleen een datum in de toekomst telt", () => {
  const now = Date.parse("2026-10-14T12:00:00Z");
  eq(bannedUntilActive("2026-10-15T12:00:00Z", now), true);
  eq(bannedUntilActive("2126-10-14T12:00:00Z", now), true, "onbepaalde tijd (100 jaar)");
  eq(bannedUntilActive("2026-10-14T11:59:59Z", now), false, "verlopen");
  eq(bannedUntilActive(null, now), false);
  eq(bannedUntilActive(undefined, now), false);
  eq(bannedUntilActive("", now), false);
  eq(bannedUntilActive("kapot", now), false);
});

Deno.test("fout van de auth-server herkennen", () => {
  eq(isBanError({ code: "user_banned", message: "User is banned" }), true);
  eq(isBanError({ status: 400, message: "Invalid Refresh Token: User Banned" }), true);
  eq(isBanError({ code: "bad_jwt", message: "invalid JWT" }), false);
  eq(isBanError(null), false);
  eq(isBanError("user_banned"), false, "alleen objecten");
});

Deno.test("antwoord voor de apps", () => {
  eq(BANNED_BODY, { error: "user_banned", banned: true, reason: "banned" });
});
