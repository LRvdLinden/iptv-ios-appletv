// deno test supabase/functions/_shared/layout_test.ts — gedeelde huisstijl en de accountmails (supabase/templates/build.ts)
import { button, esc, footerHtml, footerText, layout } from "./layout.ts";
import { renderAuth, renderTemplate, TEMPLATES } from "../../templates/build.ts";

const ok = (c: unknown, m: string) => { if (!c) throw new Error(m); };

Deno.test("layout: escapen en opbouw", () => {
  ok(esc(`<a href="x">'&`) === "&lt;a href=&quot;x&quot;&gt;&#39;&amp;", "esc");
  ok(button('https://x.nl/?a=1&b="2"', "<Klik>").includes('href="https://x.nl/?a=1&amp;b=&quot;2&quot;"'), "knop-URL ge-escaped");
  const h = layout({ lang: "en", docTitle: "<t>", preheader: "<p>", label: "Account", contentHtml: "<p>x</p>", footerHtml: "f" });
  ok(h.includes('lang="en"') && h.includes("<title>&lt;t&gt;</title>") && h.includes(">Account</td>"), "kop");
  ok(h.includes("BINGR") && h.includes("border-top:4px solid #E50914"), "huisstijl");
});

Deno.test("layout: voettekst met en zonder afmelden", () => {
  const f = footerHtml({ lang: "nl", reasonHtml: "Reden.", year: 2026 });
  ok(f.includes("Reden.") && f.includes("© 2026 Bingr") && f.includes("support.bingr.online") && f.includes("/privacy.html"), "vast");
  ok(!/afmelden/i.test(f), "geen afmeldlink zonder URL");
  const u = footerHtml({ lang: "en", reasonHtml: "R", unsubscribeUrl: "https://bingr.online/unsubscribe/?t=a&b" });
  ok(u.includes(">Unsubscribe</a>") && u.includes("t=a&amp;b"), "afmeldlink");
  ok(footerText({ lang: "nl", reason: "R", unsubscribeUrl: "https://u" }).includes("Afmelden: https://u"), "platte tekst");
});

Deno.test("accountmails: NL/EN, Go-variabelen, geen afmeldlink", () => {
  for (const key of Object.keys(TEMPLATES)) {
    const t = renderTemplate(key, 2026);
    ok(t.startsWith('{{ if and .Data.lang (eq .Data.lang "nl") }}<!doctype html>') && t.endsWith("</html>{{ end }}"), `${key}: taalkeuze`);
    ok((t.match(/<!doctype html>/g) ?? []).length === 2 && t.includes("{{ else }}"), `${key}: NL en EN`);
    ok(TEMPLATES[key].code ? t.includes("{{ .Token }}") : t.includes('href="{{ .ConfirmationURL }}"'), `${key}: actie`);
    ok(t.includes("{{ .Email }}") && /negeren/.test(t) && /ignore this email/.test(t), `${key}: reden en 'niet jij'`);
    ok(!/afmelden|unsubscribe/i.test(t), `${key}: transactioneel, geen afmeldlink`);
    ok(!/supabase/i.test(t), `${key}: geen namen van derden`);
    // Go-acties alleen op de bekende plekken (geen kapotte {{ … }})
    for (const a of t.match(/\{\{[^}]*\}\}/g) ?? []) {
      ok(/^\{\{ (\.ConfirmationURL|\.Token|\.Email|\.NewEmail|else|end|if and \.Data\.lang \(eq \.Data\.lang "nl"\)) \}\}$/.test(a), `${key}: ${a}`);
    }
  }
  ok(renderAuth("recovery", "nl").includes("Nieuw wachtwoord kiezen") && renderAuth("recovery", "en").includes("Choose a new password"), "teksten");
  ok(renderAuth("email_change", "nl").includes("{{ .NewEmail }}"), "nieuw adres");
});
