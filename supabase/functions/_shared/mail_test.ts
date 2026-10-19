// deno test --allow-env supabase/functions/_shared/mail_test.ts (mailtest-sleutel in mail.ts; workflow Backend)
import { isMailtestAddress, mailtestOk, withName } from "./mail.ts";
function assertEquals(a: unknown, b: unknown) {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`verwacht ${y}, kreeg ${x}`);
}

const hex = async (s: string) =>
  Array.from(new Uint8Array(await crypto.subtle.digest("SHA-256", new TextEncoder().encode(s))), (x) => x.toString(16).padStart(2, "0")).join("");

Deno.test("mailtest: alleen testadressen support+ci-…@bingr.online", () => {
  assertEquals(isMailtestAddress("support+ci-0a1b2c3d4e@bingr.online"), true);
  assertEquals(isMailtestAddress("support+ci-0a1b2c3d4e-nb@bingr.online"), true);
  assertEquals(isMailtestAddress("support@bingr.online"), false);
  assertEquals(isMailtestAddress("support+ci-0a1b2c3d4e@example.com"), false);
  assertEquals(isMailtestAddress("iemand+ci-0a1b2c3d4e@bingr.online"), false);
  assertEquals(isMailtestAddress(null), false);
});

Deno.test("mailtest: sleutel tegen app_settings.mailtest", async () => {
  const key = "a".repeat(48), now = Date.parse("2026-10-19T10:00:00Z");
  const row = { sha256: await hex(key), until: "2026-10-19T10:20:00Z" };
  assertEquals(await mailtestOk(key, async () => row, now), true);
  assertEquals(await mailtestOk("b".repeat(48), async () => row, now), false);
  assertEquals(await mailtestOk(key, async () => ({ ...row, until: "2026-10-19T09:59:00Z" }), now), false); // verlopen
  assertEquals(await mailtestOk(key, async () => ({ ...row, until: "2026-10-19T11:00:00Z" }), now), false); // te lang geldig
  assertEquals(await mailtestOk(key, async () => null, now), false);
  assertEquals(await mailtestOk("", async () => row, now), false);
  assertEquals(await mailtestOk(key, async () => { throw new Error("db"); }, now), false);
});

Deno.test("afzender: kaal adres krijgt de naam Bingr", () => {
  assertEquals(withName("noreply@bingr.online"), "Bingr <noreply@bingr.online>");
  assertEquals(withName("Bingr <noreply@bingr.online>"), "Bingr <noreply@bingr.online>");
  assertEquals(withName(" noreply@bingr.online ", "Bingr Support"), "Bingr Support <noreply@bingr.online>");
  assertEquals(withName(""), "");
});
