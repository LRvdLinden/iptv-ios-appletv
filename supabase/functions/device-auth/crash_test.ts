// Tests voor de crashrapporten (build 171): deno test supabase/functions/device-auth/crash_test.ts
// Alleen verzonnen gegevens (example.invalid, documentatie-IP's).
import { cleanCrash, clipBytes, MESSAGE_MAX, scrubCrashText, STACK_MAX, validAppKey } from "./crash.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "") { if (!v) throw new Error(`niet waar: ${msg}`); }
const NOW = Date.parse("2026-11-15T12:00:00Z");
const base = { platform: "ios", kind: "crash", signature: "EXC_BAD_ACCESS PlayerView.swift:120", build: 171, app_version: "1.0.6 (171)" };

Deno.test("IPTV-URL's worden <url>, ook zonder schema", () => {
  eq(scrubCrashText("open http://iptv.example.invalid:8080/live/jan/geheim/123.ts mislukt"), "open <url> mislukt");
  eq(scrubCrashText("rtmp://1.2.3.4/app"), "<url>");
  eq(scrubCrashText("pad /live/jan/geheim/123.m3u8 faalde"), "pad <url> faalde");
  eq(scrubCrashText("player_api.php?username=jan&password=geheim"), "<url>");
  eq(scrubCrashText("jan:geheim@iptv.example.invalid/get"), "<url>");
  eq(scrubCrashText("zie www.example.invalid/x"), "zie <url>");
});

Deno.test("e-mail, IP, query en geheimen", () => {
  eq(scrubCrashText("account jan@example.invalid"), "account <email>");
  eq(scrubCrashText("verbinding met 192.0.2.10:8080 weg"), "verbinding met <ip> weg");
  eq(scrubCrashText("v6 2001:db8::1 weg"), "v6 <ip> weg");
  eq(scrubCrashText("token=abc123 password: x1"), "token=<redacted> password: <redacted>");
  eq(scrubCrashText("pagina?id=5&x=y"), "pagina<query>");
});

Deno.test("lange tokens weg, symbolen en bestandsnamen blijven", () => {
  eq(scrubCrashText("jwt eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJl"), "jwt <token>");
  eq(scrubCrashText("hash 0123456789abcdef0123456789abcdef"), "hash <token>");
  eq(scrubCrashText("k Ab3dE5fG7hJ9kL1mN3pQ5rS7tU9vW1xY3zA5bC7dE9"), "k <token>");
  const sym = "$s5Bingr14AccountServiceC7refreshyyYaKFTY0_ PlayerView.swift:120 nl.lrvdlinden.bingr.MainActivity.onCreate(MainActivity.kt:42)";
  eq(scrubCrashText(sym), sym);
  eq(scrubCrashText("0x0000000104a3c120 Bingr + 123"), "0x0000000104a3c120 Bingr + 123");
});

Deno.test("cleanCrash: geldig rapport, opgeschoond en begrensd", () => {
  const r = cleanCrash({ ...base, message: "x".repeat(900) + " http://a.example.invalid/x", stack: "y".repeat(40000), at: "2026-11-15T11:00:00Z", count: 3 }, NOW);
  ok(r.ok, "ok");
  if (!r.ok) return;
  eq(r.report.message!.length, MESSAGE_MAX, "message 500");
  ok(new TextEncoder().encode(r.report.stack!).length <= STACK_MAX, "stack 16 KB");
  eq(r.report.count, 3);
  eq(r.report.at, "2026-11-15T11:00:00.000Z");
  eq(r.report.platform, "ios");
});

Deno.test("cleanCrash: foute velden", () => {
  eq(cleanCrash(null, NOW), { ok: false, error: "bad_report", field: "body" });
  eq(cleanCrash({ ...base, platform: "tizen" }, NOW), { ok: false, error: "bad_report", field: "platform" });
  eq(cleanCrash({ ...base, kind: "boom" }, NOW), { ok: false, error: "bad_report", field: "kind" });
  eq(cleanCrash({ ...base, signature: "" }, NOW), { ok: false, error: "bad_report", field: "signature" });
  eq(cleanCrash({ ...base, build: "abc" }, NOW), { ok: false, error: "bad_report", field: "build" });
  eq(cleanCrash({ ...base, at: "2026-11-01T00:00:00Z" }, NOW), { ok: false, error: "bad_report", field: "at" });
  eq(cleanCrash({ ...base, count: 0 }, NOW), { ok: false, error: "bad_report", field: "count" });
});

Deno.test("cleanCrash: standaarden, toekomst afgekapt, count max 1000, stack als lijst", () => {
  const r = cleanCrash({ platform: "WEB", kind: "error", signature: "TypeError: x is undefined", at: NOW / 1000 + 86400, count: 99999, stack: ["a", "b"] }, NOW);
  ok(r.ok);
  if (!r.ok) return;
  eq(r.report.platform, "web");
  eq(r.report.build, null);
  eq(r.report.count, 1000);
  eq(r.report.stack, "a\nb");
  eq(Date.parse(r.report.at), NOW + 600_000);
});

Deno.test("signature wordt ook opgeschoond", () => {
  const r = cleanCrash({ ...base, signature: "Fout bij http://x.example.invalid/live/a/b/1.ts" }, NOW);
  ok(r.ok);
  if (r.ok) eq(r.report.signature, "Fout bij <url>");
});

Deno.test("clipBytes knipt geen teken doormidden", () => {
  eq(clipBytes("ééé", 5), "éé");
  eq(clipBytes("a😀b", 3), "a");
  eq(clipBytes("abc", 10), "abc");
});

Deno.test("validAppKey: publishable keys (JSON) en de oude anon key", () => {
  const pub = JSON.stringify({ default: "sb_publishable_test_aaaaaaaaaaaaaaaa" });
  ok(validAppKey("sb_publishable_test_aaaaaaaaaaaaaaaa", pub, null), "publishable");
  ok(validAppKey("anon-key-xxxxxxxxxxxxxxxxxxxx", pub, "anon-key-xxxxxxxxxxxxxxxxxxxx"), "anon");
  ok(!validAppKey("sb_publishable_test_bbbbbbbbbbbbbbbb", pub, null), "fout");
  ok(!validAppKey(null, pub, "anon-key-xxxxxxxxxxxxxxxxxxxx"), "leeg");
  ok(!validAppKey("kort", null, "kort"), "te kort");
});
