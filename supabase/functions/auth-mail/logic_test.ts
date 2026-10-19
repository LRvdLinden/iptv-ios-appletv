// Tests voor auth-mail (geen netwerk): deno test supabase/functions/auth-mail/logic_test.ts
function assert(c: unknown, msg = "niet waar") { if (!c) throw new Error(msg); }
function assertEquals(a: unknown, b: unknown) {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`verwacht ${y}, kreeg ${x}`);
}
function assertThrows(f: () => unknown) { try { f(); } catch { return; } throw new Error("verwacht een fout"); }
import { buildMails, hookKeys, htmlToText, renderGo, sign, verifyHook } from "./logic.ts";
import { TEMPLATES } from "./templates.ts";

const SECRET = "v1,whsec_" + btoa("0123456789abcdef0123456789abcdef");
const hdrs = (id: string, ts: string, sig: string) => new Headers({ "webhook-id": id, "webhook-timestamp": ts, "webhook-signature": sig });

Deno.test("handtekening: goed, fout, verlopen, meerdere geheimen", async () => {
  const body = '{"a":1}', ts = String(Math.floor(Date.now() / 1000));
  const sig = await sign(hookKeys(SECRET)[0], "msg_1", ts, body);
  assert(await verifyHook(SECRET, hdrs("msg_1", ts, `v1,${sig}`), body));
  assert(await verifyHook(SECRET, hdrs("msg_1", ts, `v1,xxx v1,${sig}`), body));
  assert(!(await verifyHook(SECRET, hdrs("msg_1", ts, `v1,${sig}`), body + " ")));
  assert(!(await verifyHook(SECRET, hdrs("msg_2", ts, `v1,${sig}`), body)));
  assert(!(await verifyHook(SECRET, hdrs("msg_1", String(Number(ts) - 600), `v1,${sig}`), body)));
  assert(!(await verifyHook("", hdrs("msg_1", ts, `v1,${sig}`), body)));
  const other = "v1,whsec_" + btoa("ffffffffffffffffffffffffffffffff");
  assert(await verifyHook(`${other}|${SECRET}`, hdrs("msg_1", ts, `v1,${sig}`), body));
});

Deno.test("Go-template: variabelen, escapen, if/else, and/eq", () => {
  const ctx = { Email: "a&b@x.nl", Data: { first_name: "<Jan>", lang: "nl" }, RedirectTo: "https://bingr.online/koppelen/?code=a&b", TokenHash: "abc" };
  assertEquals(renderGo("{{ .Email }}", ctx), "a&amp;b@x.nl");
  assertEquals(renderGo("{{ if .Data.first_name }}Hoi {{ .Data.first_name }},{{ end }}", ctx), "Hoi &lt;Jan&gt;,");
  assertEquals(renderGo("{{ if .Data.missing }}x{{ else }}y{{ end }}", ctx), "y");
  assertEquals(renderGo('{{ if and .Data.lang (eq .Data.lang "nl") }}NL{{ else }}EN{{ end }}', ctx), "NL");
  assertEquals(renderGo('{{ if and .Data.lang (eq .Data.lang "nl") }}NL{{ else }}EN{{ end }}', { Data: { lang: "en" } }), "EN");
  assertEquals(renderGo('{{ if and .Data.lang (eq .Data.lang "nl") }}NL{{ else }}EN{{ end }}', { Data: {} }), "EN");
  assertEquals(renderGo("?next={{ .RedirectTo }}", ctx), "?next=https%3A%2F%2Fbingr.online%2Fkoppelen%2F%3Fcode%3Da%26b");
  assertEquals(renderGo("{{ if .A }}a{{ else if .B }}b{{ else }}c{{ end }}", { B: 1 }), "b");
  assertThrows(() => renderGo("{{ range .X }}{{ end }}", {}));
  assertThrows(() => renderGo("{{ if .X }}", {}));
});

Deno.test("alle templates renderen zonder resten, NL en EN, met en zonder naam", () => {
  for (const [key, t] of Object.entries(TEMPLATES)) {
    for (const data of [{ lang: "nl", first_name: "Jan" }, { lang: "en" }, {}]) {
      const html = renderGo(t.content, { Email: "u@x.nl", NewEmail: "n@x.nl", Data: data, RedirectTo: "https://bingr.online/web/", Token: "123456", TokenHash: "deadbeef" });
      assert(!html.includes("{{"), `${key}: rest van een template`);
      assert(!html.includes("supabase.co"), `${key}: supabase.co-link`);
      if (key !== "reauthentication") assert(html.includes("token_hash=deadbeef"), `${key}: token_hash ontbreekt`);
      else assert(html.includes("123456"), "code ontbreekt");
      const nl = (data as { lang?: string }).lang === "nl";
      assert(html.includes(nl ? "lang=nl" : "lang=en") || key === "reauthentication", `${key}: taal`);
    }
  }
});

Deno.test("buildMails: aanmelding, onbekend, e-mailadres wijzigen (secure: hashes andersom)", () => {
  const u = { email: "oud@x.nl", new_email: "nieuw@x.nl", user_metadata: { lang: "nl", first_name: "Jan" } };
  const s = buildMails({ email: "a@x.nl", user_metadata: { lang: "nl" } }, { email_action_type: "signup", token_hash: "h1", redirect_to: "https://bingr.online/web/" });
  assertEquals(s.length, 1);
  assertEquals(s[0].to, "a@x.nl");
  assertEquals(s[0].subject, TEMPLATES.confirmation.subject);
  assert(s[0].html.includes("token_hash=h1&amp;type=signup&amp;lang=nl&amp;next=https%3A%2F%2Fbingr.online%2Fweb%2F"));
  assert(s[0].text.includes("token_hash=h1&type=signup"));
  assertEquals(buildMails({ email: "a@x.nl" }, { email_action_type: "password_changed_notification" }), []);
  assertEquals(buildMails({}, { email_action_type: "signup" }), []);
  const ec = buildMails(u, { email_action_type: "email_change", token_hash: "voorNieuw", token_hash_new: "voorOud", token: "1", token_new: "2" });
  assertEquals(ec.map((m) => m.to), ["oud@x.nl", "nieuw@x.nl"]);
  assert(ec[0].html.includes("token_hash=voorOud"));
  assert(ec[1].html.includes("token_hash=voorNieuw"));
  const one = buildMails({ ...u }, { email_action_type: "email_change", token_hash: "enkel" });
  assertEquals(one.map((m) => m.to), ["nieuw@x.nl"]);
  assertEquals(buildMails({ email: "a@x.nl" }, { email_action_type: "recovery", token_hash: "r" })[0].template, "recovery");
  assertEquals(buildMails({ email: "a@x.nl" }, { email_action_type: "magiclink", token_hash: "m" })[0].template, "magic_link");
});

Deno.test("htmlToText", () => {
  const t = htmlToText('<p>Hoi&nbsp;Jan,</p><a href="https://bingr.online/x?a=1&amp;b=2">Bevestigen</a><br>Klaar');
  assert(t.includes("Hoi Jan,"));
  assert(t.includes("Bevestigen (https://bingr.online/x?a=1&b=2)"));
});

Deno.test("handtekening: testvector van standardwebhooks.com", async () => {
  const h = hdrs("msg_p5jXN8AQM9LWM0D4loKWxJek", "1614265330", "v1,g0hM9SsE+OTPJTGt/tmIKtSyZlE3uFJELVlNIOLJ1OE=");
  assert(await verifyHook("v1,whsec_MfKQ9r8GKYqrTwjUPD8ILPZIo2LaLaSw", h, '{"test": 2432232314}', 1614265330 * 1000));
});
