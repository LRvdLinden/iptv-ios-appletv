// deno test supabase/functions/device-auth/naming_test.ts
// Eigen naam bij het koppelen (zonder externe imports).
import { cleanDeviceName, deviceKind, deviceTypeLabel } from "./naming.ts";
function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

Deno.test("soort: start-apparaat en register-platform komen overeen", () => {
  eq(["Apple TV", "iPhone", "iPad", "Mac", "Android TV", "Google TV", "Fire TV", "Samsung TV", "tizen", "Android", "Android tablet", "browser", "CI-test", null].map(deviceKind),
    ["tvos", "ios", "ios", "macos", "androidtv", "androidtv", "androidtv", "tizen", "tizen", "android", "android", "web", "other", "other"]);
});

Deno.test("soort: webspeler (weergavenaam bij start, browser bij aanmelden)", () => {
  eq(["Chrome op Mac", "Safari on iPad", "Firefox op Windows", "Edge", "browser", "windows"].map(deviceKind), ["web", "web", "web", "web", "web", "web"]);
});

Deno.test("label voor het naamveld", () => {
  eq(deviceTypeLabel("Apple TV"), "Apple TV");
  eq(deviceTypeLabel("tizen"), "Samsung TV");
  eq(deviceTypeLabel(""), "TV");
  eq(deviceTypeLabel(null), "TV");
});

Deno.test("naam opschonen", () => {
  eq(cleanDeviceName("  Apple TV -  Woonkamer "), { name: "Apple TV - Woonkamer" });
  eq(cleanDeviceName("Apple TV - ", "Apple TV"), { name: null }, "alleen het voorvoegsel: geen eigen naam");
  eq(cleanDeviceName("apple tv", "Apple TV"), { name: null });
  eq(cleanDeviceName("Slaapkamer"), { name: "Slaapkamer" }, "helemaal eigen naam");
  eq(cleanDeviceName("Zolder\u0000‮ TV"), { name: "Zolder TV" }, "stuur- en richtingtekens weg");
  eq(cleanDeviceName(""), { name: null });
  eq(cleanDeviceName(undefined), { name: null });
  eq(cleanDeviceName("x".repeat(40)), { name: "x".repeat(40) });
  eq(cleanDeviceName("x".repeat(41)), { error: "name_too_long" });
  eq(cleanDeviceName("Samsung TV – Keuken —"), { name: "Samsung TV – Keuken" });
  eq(cleanDeviceName("Tv 🎬 kamer"), { name: "Tv 🎬 kamer" });
});
