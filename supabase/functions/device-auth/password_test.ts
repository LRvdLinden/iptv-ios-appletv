// deno test supabase/functions/device-auth/password_test.ts
// H1: wachtwoordcontrole bij delete_account (zonder externe imports).
import { passwordCheckResult } from "./password.ts";
function eq(a: unknown, b: unknown, msg = "") {
  if (a !== b) throw new Error(`${msg} verwacht ${JSON.stringify(b)}, kreeg ${JSON.stringify(a)}`);
}

Deno.test("fout wachtwoord", () => {
  eq(passwordCheckResult({ status: 400, code: "invalid_credentials" }), "wrong");
  eq(passwordCheckResult({ status: 400, code: "email_not_confirmed" }), "wrong");
  eq(passwordCheckResult({ status: 401 }), "wrong", "ongeldige sleutel");
});

Deno.test("geen sessie en geen fout telt nooit als goed", () => {
  eq(passwordCheckResult(null), "wrong");
  eq(passwordCheckResult(undefined), "wrong");
});

Deno.test("te veel pogingen", () => {
  eq(passwordCheckResult({ status: 429 }), "rate_limited");
  eq(passwordCheckResult({ status: 400, code: "over_request_rate_limit" }), "rate_limited");
});

Deno.test("storing: niet verwijderen, niet 'fout wachtwoord'", () => {
  eq(passwordCheckResult({ status: 500 }), "unavailable");
  eq(passwordCheckResult({ status: 503 }), "unavailable");
  eq(passwordCheckResult({}), "unavailable", "geen status (netwerkfout)");
});
