// Tests voor de openbare versies (app_settings.release_channels -> status ?action=releases):
//   deno test supabase/functions/status/releases_test.ts
import { cleanBuild, cleanDate, cleanVersion, releasesView } from "./releases.ts";

function eq(a: unknown, b: unknown, msg = "") {
  const x = JSON.stringify(a), y = JSON.stringify(b);
  if (x !== y) throw new Error(`${msg} verwacht ${y}, kreeg ${x}`);
}

Deno.test("velden: versie, build en datum", () => {
  eq(cleanVersion("1.0.3"), "1.0.3");
  eq(cleanVersion(" 1.0 "), "1.0");
  eq(cleanVersion("1"), null);
  eq(cleanVersion("1.0.3-beta"), null);
  eq(cleanVersion("<b>1.0</b>"), null);
  eq(cleanBuild(154), 154);
  eq(cleanBuild("154"), 154);
  eq(cleanBuild(0), null);
  eq(cleanBuild(1.5), null);
  eq(cleanBuild("15a"), null);
  eq(cleanDate("2026-10-30"), "2026-10-30");
  eq(cleanDate("2026-10-30T12:00:00Z"), "2026-10-30");
  eq(cleanDate("2026-02-30"), null);
  eq(cleanDate("gisteren"), null);
});

Deno.test("leeg of onzin geeft geen kanalen", () => {
  const empty = { apple: { live: null, beta: null }, android: { live: null, beta: null }, updatedAt: null };
  eq(releasesView(null), empty);
  eq(releasesView("x"), empty);
  eq(releasesView([]), empty);
  eq(releasesView({ apple: { live: { version: "1.0.2" } } }), empty, "build ontbreekt");
});

Deno.test("alleen de bekende velden gaan naar buiten", () => {
  const v = releasesView({
    apple: { live: { version: "1.0.2", build: 152, date: "2026-10-20", secret: "x" }, beta: { version: "1.0.3", build: "154", label: "TestFlight" } },
    android: { live: null, beta: { version: "1.0.3", build: 154, label: "<script>" } },
    other: { live: { version: "9.9", build: 9 } },
    updatedAt: "2026-10-30T10:00:00Z",
  });
  eq(v, {
    apple: { live: { version: "1.0.2", build: 152, date: "2026-10-20" }, beta: { version: "1.0.3", build: 154, label: "TestFlight" } },
    android: { live: null, beta: { version: "1.0.3", build: 154, label: "Beta" } },
    updatedAt: "2026-10-30T10:00:00.000Z",
  });
});

Deno.test("standaardlabel: Apple TestFlight, Android Beta", () => {
  const v = releasesView({ apple: { beta: { version: "1.0", build: 1 } }, android: { beta: { version: "1.0", build: 1, label: "TestFlight" } } });
  eq(v.apple.beta?.label, "TestFlight");
  eq(v.android.beta?.label, "TestFlight");
});
