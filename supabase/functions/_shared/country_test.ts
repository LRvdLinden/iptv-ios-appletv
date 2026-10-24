// deno test supabase/functions/_shared/country_test.ts
import { countryOf } from "./country.ts";
const req = (h?: string) => new Request("https://x.test/", { headers: h === undefined ? {} : { "cf-ipcountry": h } });
function eq(a: unknown, b: unknown, msg = "") { if (a !== b) throw new Error(`${msg} verwacht ${b}, kreeg ${a}`); }

Deno.test("land: alleen een geldige landcode van twee letters", () => {
  eq(countryOf(req("NL")), "NL", "NL");
  eq(countryOf(req(" be ")), "BE", "kleine letters en spaties");
  for (const v of ["", "XX", "T1", "NLD", "N", "1A", "N L"]) eq(countryOf(req(v)), null, `"${v}"`);
  eq(countryOf(req()), null, "zonder header");
});
