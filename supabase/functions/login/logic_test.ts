// deno test supabase/functions/login/logic_test.ts  (build 141, blokkeert de deploy in Backend)
import { type Begin, classify, type Deps, type Finish, handleLogin, normEmail, publishableKey, secretKey, tooMany, type TokenReply } from "./logic.ts";

function eq(a: unknown, b: unknown, msg = "") {
  if (JSON.stringify(a) !== JSON.stringify(b)) throw new Error(`${msg}: ${JSON.stringify(a)} !== ${JSON.stringify(b)}`);
}
const UID = "00000000-0000-4000-8000-0000000000c1";
const SESSION = JSON.stringify({ access_token: "a", token_type: "bearer", expires_in: 3600, expires_at: 1, refresh_token: "r", user: { id: UID } });
const gotrue = (status: number, body: unknown): TokenReply => ({ status, text: typeof body === "string" ? body : JSON.stringify(body) });
const WRONG = gotrue(400, { code: 400, error_code: "invalid_credentials", msg: "Invalid login credentials" });

// nabootsing van de database (zelfde regels als bingr_login_begin/finish: 5 fouten = dicht, 15 -> 30 -> 60 min)
function fakeDb(opts: { known?: boolean; ipMax?: number } = {}) {
  const st = { fails: 0, level: 0, lockedS: 0, tickets: 0, ipHits: 0, finishes: [] as string[], begins: 0 };
  const deps = (reply: () => TokenReply | Promise<TokenReply>): Deps => ({
    async begin(): Promise<Begin> {
      st.begins++; st.ipHits++;
      if (st.ipHits > (opts.ipMax ?? 30)) return { status: "rate", retry_after: 420 };
      if (opts.known === false) return { status: "continue" };
      if (st.lockedS > 0) return { status: "locked", retry_after: st.lockedS };
      st.tickets++;
      return { status: "continue", user_id: UID };
    },
    async finish(uid, result): Promise<Finish> {
      eq(uid, UID, "finish user");
      st.finishes.push(result); st.tickets = 0;
      if (result === "ok") { st.fails = 0; return { status: "ok" }; }
      if (result !== "wrong") return { status: "ok" };
      if (++st.fails >= 5) { st.fails = 0; st.level = Math.min(st.level + 1, 3); st.lockedS = 900 * 2 ** (st.level - 1); return { status: "locked", retry_after: st.lockedS }; }
      return { status: "ok" };
    },
    token: async () => await reply(),
  });
  return { st, deps };
}
const body = (r: { body: string }) => JSON.parse(r.body);

Deno.test("normEmail", () => {
  eq(normEmail("  A@Example.COM "), "a@example.com");
  eq(normEmail("geen-adres"), "");
  eq(normEmail(""), "");
  eq(normEmail(42), "");
  eq(normEmail("a b@example.com"), "");
  eq(normEmail("x".repeat(250) + "@e.nl"), "");
});

Deno.test("ongeldige invoer = invalid_credentials zonder database of GoTrue", async () => {
  const { st, deps } = fakeDb();
  for (const b of [null, {}, { email: "a@example.com" }, { email: "a@example.com", password: "" }, { email: "x", password: "p" },
    { email: "a@example.com", password: "p".repeat(201) }, { email: ["a@example.com"], password: "p" }]) {
    const r = await handleLogin(b, deps(() => { throw new Error("niet aanroepen"); }));
    eq(r.status, 400); eq(body(r).error_code, "invalid_credentials");
  }
  eq(st.begins, 0, "geen begin");
});

Deno.test("gelukt: exact het antwoord van GoTrue, teller weg", async () => {
  const { st, deps } = fakeDb();
  const r = await handleLogin({ email: "A@example.com", password: "goed", device_id: "d", platform: "ios" }, deps(() => gotrue(200, SESSION)));
  eq(r.status, 200); eq(r.body, SESSION, "body ongewijzigd"); eq(st.finishes, ["ok"]); eq(st.tickets, 0);
});

Deno.test("5 fouten = 429 too_many_attempts, daarna ook goed wachtwoord geweigerd; oplopend 15/30/60", async () => {
  const { st, deps } = fakeDb({ ipMax: 1000 });
  for (const minutes of [15, 30, 60, 60]) {
    for (let i = 1; i <= 4; i++) {
      const r = await handleLogin({ email: "a@example.com", password: "fout" }, deps(() => WRONG));
      eq([r.status, body(r).error_code], [400, "invalid_credentials"], `fout ${i}`);
    }
    const r5 = await handleLogin({ email: "a@example.com", password: "fout" }, deps(() => WRONG));
    eq(r5.status, 429, "5e fout"); eq(body(r5).error_code, "too_many_attempts");
    eq(body(r5).retry_after, minutes * 60); eq(r5.retryAfter, minutes * 60);
    eq(body(r5).msg, `Too many attempts. Try again in ${minutes} minutes.`);
    let called = false;
    const r6 = await handleLogin({ email: "a@example.com", password: "goed" }, deps(() => { called = true; return gotrue(200, SESSION); }));
    eq(r6.status, 429, "goed wachtwoord tijdens blokkade"); eq(called, false, "GoTrue niet aangeroepen tijdens blokkade");
    st.lockedS = 0; // blokkade verlopen
  }
});

Deno.test("limiet per IP/e-mail = 429 met retry_after", async () => {
  const { deps } = fakeDb({ ipMax: 2 });
  await handleLogin({ email: "a@example.com", password: "fout" }, deps(() => WRONG));
  await handleLogin({ email: "a@example.com", password: "fout" }, deps(() => WRONG));
  const r = await handleLogin({ email: "a@example.com", password: "goed" }, deps(() => gotrue(200, SESSION)));
  eq([r.status, body(r).error_code, body(r).retry_after, body(r).msg], [429, "too_many_attempts", 420, "Too many attempts. Try again in 7 minutes."]);
});

Deno.test("onbekend adres: GoTrue beslist (invalid_credentials), niets geteld", async () => {
  const { st, deps } = fakeDb({ known: false });
  const r = await handleLogin({ email: "x@example.com", password: "p" }, deps(() => WRONG));
  eq([r.status, body(r).error_code], [400, "invalid_credentials"]); eq(st.finishes, []);
});

Deno.test("email_not_confirmed, banned, 429 van Auth, storing", async () => {
  const cases: [TokenReply, number, string][] = [
    [gotrue(400, { error_code: "email_not_confirmed", msg: "Email not confirmed" }), 400, "email_not_confirmed"],
    [gotrue(400, { error_code: "user_banned", msg: "User is banned" }), 403, "user_banned"],
    [gotrue(429, { error_code: "over_request_rate_limit", msg: "Request rate limit reached" }), 429, "too_many_attempts"],
    [gotrue(500, { error_code: "unexpected_failure" }), 503, "login_unavailable"],
    [gotrue(403, { msg: "Sign in with the latest version of Bingr." }), 503, "login_unavailable"],
    [gotrue(401, { message: "Invalid API key" }), 503, "login_unavailable"],
    [gotrue(200, "geen json"), 503, "login_unavailable"],
    [null, 503, "login_unavailable"],
    [gotrue(422, { error_code: "validation_failed" }), 400, "invalid_credentials"],
  ];
  for (const [reply, status, code] of cases) {
    const { st, deps } = fakeDb();
    const r = await handleLogin({ email: "a@example.com", password: "p" }, deps(() => reply));
    eq([r.status, body(r).error_code], [status, code], `${reply?.status}`);
    eq(st.finishes, ["other"], "niet geteld, ticket weg");
    if (status === 429) eq(body(r).retry_after, 60);
  }
});

Deno.test("databasefout bij begin: zonder bescherming door (GoTrue beslist), fout bij finish breekt niets", async () => {
  const deps: Deps = {
    begin: () => Promise.reject(new Error("db")),
    finish: () => Promise.reject(new Error("db")),
    token: async () => gotrue(200, SESSION),
  };
  const r = await handleLogin({ email: "a@example.com", password: "p" }, deps);
  eq(r.status, 200);
  const r2 = await handleLogin({ email: "a@example.com", password: "p" }, { ...deps, begin: async () => null, token: async () => WRONG });
  eq(r2.status, 400);
  const r3 = await handleLogin({ email: "a@example.com", password: "p" }, { ...deps, token: () => Promise.reject(new Error("net")) });
  eq(r3.status, 503);
});

Deno.test("classify", () => {
  eq(classify(gotrue(400, { error_code: "invalid_grant" })).kind, "wrong");
  eq(classify(gotrue(400, { msg: "User is banned" })).kind, "banned");
  eq(classify(gotrue(200, { access_token: "a" })).kind, "unavailable");
});

Deno.test("tooMany", () => {
  eq(JSON.parse(tooMany(30).body).msg, "Too many attempts. Try again in 1 minute.");
  eq(JSON.parse(tooMany(0).body).retry_after, 1);
  eq(JSON.parse(tooMany(NaN).body).retry_after, 60);
});

Deno.test("sleutels uit SUPABASE_SECRET_KEYS / SUPABASE_PUBLISHABLE_KEYS", () => {
  eq(secretKey(JSON.stringify({ default: "sb_secret_abc" })), "sb_secret_abc");
  eq(secretKey(JSON.stringify({ other: "sb_secret_x" })), "sb_secret_x");
  eq(secretKey(JSON.stringify({ default: "eyJlegacy" })), null);
  eq(secretKey("geen json"), null);
  eq(secretKey(undefined), null);
  eq(publishableKey(JSON.stringify({ default: "sb_publishable_p" }), "anon"), "sb_publishable_p");
  eq(publishableKey(undefined, "anon"), "anon");
  eq(publishableKey("kapot", null), null);
});
