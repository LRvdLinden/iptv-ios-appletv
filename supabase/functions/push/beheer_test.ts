// Unittests voor de meldingen naar de beheer-app: deno test supabase/functions/push/beheer_test.ts
// Zonder netwerk of database: tekstopbouw, samenvatten, staatovergangen, watermerken en de APNs-aanroep met eigen topic.
import {
  beheerPayload, buildNotices, clip, fmtDuration, initState, manifestBuilds, manifestDue, MAX_PER_KIND, replyNotices,
  statusNotices, ticketNotices, wants,
} from "./beheer_logic.ts";
import { Apns } from "./channels.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}
function ok(v: unknown, msg = "niet waar") { if (!v) throw new Error(msg); }

Deno.test("beheer: tekst afkappen op ~120 tekens, op één regel", () => {
  eq(clip("  kort\n onderwerp "), "kort onderwerp");
  const long = "woord ".repeat(60);
  const c = clip(long);
  ok(c.length <= 120, `te lang: ${c.length}`);
  ok(c.endsWith("…"));
  eq(clip("x".repeat(200)).length, 120);
  eq(clip(null), "");
});

Deno.test("beheer: nieuw ticket en samenvatting boven 3", () => {
  eq(ticketNotices([{ number: 42, subject: "Kan niet inloggen" }]), [
    { kind: "ticket", title: "Nieuw ticket #42", body: "Kan niet inloggen", url: "bingrbeheer://support/42" },
  ]);
  eq(ticketNotices([{ number: 7, subject: "" }])[0].body, "(geen onderwerp)");
  const five = [5, 1, 3, 2, 4].map((n) => ({ number: n, subject: `s${n}` }));
  const s = ticketNotices(five);
  eq(s.length, 1);
  eq(s[0], { kind: "ticket", title: "5 nieuwe tickets", body: "#1, #2, #3, #4, #5", url: "bingrbeheer://support" });
  eq(ticketNotices(five.slice(0, MAX_PER_KIND)).map((n) => n.title), ["Nieuw ticket #1", "Nieuw ticket #3", "Nieuw ticket #5"]);
});

Deno.test("beheer: klantantwoord; eerste bericht van een ticket telt niet als antwoord", () => {
  const r = replyNotices([
    { id: 10, number: 42, body: "Eerste bericht", first: true },
    { id: 11, number: 41, body: "Het werkt nog steeds niet", first: false },
  ]);
  eq(r, [{ kind: "reply", title: "Nieuw antwoord op #41", body: "Het werkt nog steeds niet", url: "bingrbeheer://support/41" }]);
  const many = [1, 2, 3, 4].map((i) => ({ id: i, number: 9, body: `b${i}`, first: false }));
  eq(replyNotices(many), [{ kind: "reply", title: "4 nieuwe antwoorden", body: "Op #9", url: "bingrbeheer://support/9" }]);
  const mixed = [1, 2, 3, 4].map((i) => ({ id: i, number: 8 + (i % 2), body: "x", first: false }));
  eq(replyNotices(mixed)[0].url, "bingrbeheer://support");
});

Deno.test("beheer: builds uit het manifest, nieuw boven het watermerk, nieuw platform stil", () => {
  const cur = manifestBuilds({ platforms: { android: { build: 116 }, tizen: { build: 116 }, apple: { build: 115 }, beheer: { build: "x" }, other: { build: 3 } } });
  eq(cur, { android: 116, tizen: 116, apple: 115 });
  const r = buildNotices(cur, { android: 115, tizen: 116 });
  eq(r.notices, [{ kind: "build", title: "Android-build 116 staat klaar", body: "In Downloads op beheer.bingr.online", url: "bingrbeheer://downloads" }]);
  eq(r.mark, { android: 116, tizen: 116, apple: 115 }); // apple had geen watermerk: vastgelegd zonder melding
  eq(buildNotices({ android: 114 }, { android: 115 }).notices, []); // lager (teruggezet) = niets
  const all = buildNotices({ android: 2, tizen: 2, apple: 2, beheer: 2 }, { android: 1, tizen: 1, apple: 1, beheer: 1 });
  eq(all.notices.map((n) => n.title), ["4 nieuwe builds staan klaar"]);
  eq(buildNotices({ beheer: 9 }, { beheer: 8 }).notices[0].title, "Beheer-app-build 9 staat klaar");
});

Deno.test("beheer: statusovergangen op open storingen (geen flapperen), duur bij herstel", () => {
  const now = Date.parse("2026-10-17T12:30:00Z");
  const mark = { site: { s: "up" as const }, api: { s: "down" as const, since: "2026-10-17T12:18:00Z" }, old: { s: "up" as const } };
  const r = statusNotices([
    { id: "site", name: "Website", down: true, since: "2026-10-17T12:25:00Z" },
    { id: "api", name: "API apps", down: false },
    { id: "smtp", name: "E-mail (SMTP)", down: true, since: "2026-10-17T12:00:00Z" }, // nieuw: stil vastgelegd
  ], mark, now);
  eq(r.notices, [
    { kind: "status", title: "Storing: Website", body: "Sinds 14:25", url: "bingrbeheer://status" },
    { kind: "status", title: "Weer online: API apps", body: "Na 12 min weer bereikbaar", url: "bingrbeheer://status" },
  ]);
  eq(r.mark, { site: { s: "down", since: "2026-10-17T12:25:00Z" }, api: { s: "up", since: null }, smtp: { s: "down", since: "2026-10-17T12:00:00Z" } });
  // zelfde staat: niets
  eq(statusNotices([{ id: "site", name: "Website", down: true, since: "x" }], r.mark, now).notices, []);
  // meer dan 3 wijzigingen: één samenvatting
  const ids = ["a", "b", "c", "d", "e"];
  const s = statusNotices(ids.map((id, i) => ({ id, name: id, down: i < 3 })), Object.fromEntries(ids.map((id, i) => [id, { s: i < 3 ? "up" : "down", since: null }])) as never, now);
  eq(s.notices, [{ kind: "status", title: "5 statuswijzigingen", body: "3 storingen, 2 weer online", url: "bingrbeheer://status" }]);
  eq(statusNotices([{ id: "a", name: "A", down: false }], { a: { s: "down", since: null } }, now).notices[0].body, "Weer bereikbaar");
});

Deno.test("beheer: duur leesbaar", () => {
  eq(fmtDuration(20), "minder dan een minuut");
  eq(fmtDuration(12 * 60), "12 min");
  eq(fmtDuration(125 * 60), "2 u 5 min");
  eq(fmtDuration(120 * 60), "2 u");
  eq(fmtDuration(27 * 3600), "1 d 3 u");
});

Deno.test("beheer: watermerken de eerste keer op de huidige stand (geen stortvloed)", () => {
  const now = Date.parse("2026-10-17T12:00:00Z");
  const cur = { maxTicket: 120, maxMessage: 900, builds: { android: 116 }, monitors: [{ id: "site", name: "Website", down: true, since: "2026-10-17T11:00:00Z" }] };
  const a = initState(null, cur, now);
  eq(a.armed, { ticket: false, reply: false, build: false, status: false });
  eq([a.state.last_ticket_number, a.state.last_message_id, a.state.builds], [120, 900, { android: 116 }]);
  eq(a.state.monitors, { site: { s: "down", since: "2026-10-17T11:00:00Z" } });
  // bestaande rij: alles blijft staan en mag melden
  const b = initState({ last_ticket_number: 100, last_message_id: 800, builds: { android: 115 }, monitors: {} }, cur, now);
  eq(b.armed, { ticket: true, reply: true, build: true, status: true });
  eq([b.state.last_ticket_number, b.state.last_message_id, b.state.builds], [100, 800, { android: 115 }]);
  // manifest nog niet op te halen: builds blijft leeg en wordt later vastgelegd
  const c = initState({ last_ticket_number: 1, last_message_id: 1, builds: null, monitors: {} }, { ...cur, builds: null }, now);
  eq([c.armed.build, c.state.builds], [false, null]);
  // manifest niet opgehaald deze ronde (cur.builds null): bestaand watermerk blijft
  eq(initState({ builds: { android: 1 } }, { ...cur, builds: null }, now).state.builds, { android: 1 });
  // geen tickets/berichten in de database: watermerk 0
  eq(initState(null, { ...cur, maxTicket: 0, maxMessage: 0 }, now).state.last_ticket_number, 0);
});

Deno.test("beheer: manifest hoogstens elke 5 minuten", () => {
  const now = Date.parse("2026-10-17T12:00:00Z");
  eq(manifestDue(null, now), true);
  eq(manifestDue("2026-10-17T11:58:00Z", now), false);
  eq(manifestDue("2026-10-17T11:55:00Z", now), true);
});

Deno.test("beheer: payload, voorkeuren", () => {
  eq(beheerPayload({ kind: "ticket", title: "T", body: "B", url: "bingrbeheer://support/1" }), {
    aps: { alert: { title: "T", body: "B" }, sound: "default", "thread-id": "ticket" }, kind: "ticket", url: "bingrbeheer://support/1",
  });
  eq(wants({ tickets: false, replies: true }, "ticket"), false);
  eq(wants({ tickets: false }, "reply"), true);
  eq(wants(null, "status"), true);
  eq(wants({ status: false }, "status"), false);
});

Deno.test("beheer: APNs met topic van de beheer-app, sandbox per apparaat", async () => {
  const ec = await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, true, ["sign", "verify"]);
  const der = new Uint8Array(await crypto.subtle.exportKey("pkcs8", ec.privateKey));
  const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...der))}\n-----END PRIVATE KEY-----\n`;
  const env: Record<string, string> = { APNS_KEY_P8: pem, APNS_KEY_ID: "KID", APNS_TEAM_ID: "EU3UY476T6", APNS_TOPIC: "nl.lrvdlinden.bingr" };
  const calls: { url: string; headers: Record<string, string>; body: unknown }[] = [];
  const fake = ((u: string, init: RequestInit) => {
    calls.push({ url: u, headers: init.headers as Record<string, string>, body: JSON.parse(String(init.body)) });
    return Promise.resolve(u.includes("dead") ? Response.json({ reason: "BadDeviceToken" }, { status: 400 }) : new Response(null, { status: 200 }));
  }) as typeof fetch;
  const apns = new Apns((k) => env[k], fake);
  const payload = beheerPayload({ kind: "build", title: "Android-build 116 staat klaar", body: "In Downloads op beheer.bingr.online", url: "bingrbeheer://downloads" });
  eq((await apns.post("ab".repeat(32), true, payload, { topic: "nl.lrvdlinden.bingr.beheer" })).state, "sent");
  eq(calls[0].url, `https://api.sandbox.push.apple.com/3/device/${"ab".repeat(32)}`);
  eq([calls[0].headers["apns-topic"], calls[0].headers["apns-push-type"]], ["nl.lrvdlinden.bingr.beheer", "alert"]);
  eq(calls[0].body, payload);
  const bad = await apns.post("dead", false, payload, { topic: "nl.lrvdlinden.bingr.beheer" });
  eq([bad.state, bad.error], ["invalid", "apns_BadDeviceToken"]);
  ok(calls[1].url.startsWith("https://api.push.apple.com/"));
  // zonder sleutels: niet versturen
  eq((await new Apns(() => undefined, fake).post("ab", false, payload)).error, "apns_not_configured");
});
