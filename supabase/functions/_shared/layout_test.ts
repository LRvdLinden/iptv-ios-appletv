// deno test supabase/functions/_shared/layout_test.ts — gedeelde huisstijl en de accountmails (supabase/templates/build.ts)
import { button, esc, firstNameOf, footerHtml, footerText, greeting, greetingText, layout, personName } from "./layout.ts";
import { renderAuth, renderTemplate, TEMPLATES, VERIFY_TYPE } from "../../templates/build.ts";

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
    if (TEMPLATES[key].code) ok(t.includes("{{ .Token }}") && !t.includes("bevestigen/"), `${key}: alleen een code`);
    else for (const lang of ["nl", "en"]) {
      const u = `https://bingr.online/bevestigen/?token_hash={{ .TokenHash }}&amp;type=${VERIFY_TYPE[key]}&amp;lang=${lang}`;
      ok(t.includes(`href="${u}`), `${key}: knop naar bingr.online/bevestigen (${lang})`);
      ok((t.split(u).length - 1) === 3, `${key}: knop, kopieerlink en linktekst (${lang})`);
    }
    ok(!t.includes("ConfirmationURL") && !/supabase\.co/i.test(t), `${key}: geen Supabase-verify-link`);
    // next (redirect_to van de app) staat altijd als laatste parameter
    for (const m of t.match(/next=\{\{ \.RedirectTo \}\}[^"<]*/g) ?? []) ok(m === "next={{ .RedirectTo }}", `${key}: next achteraan`);
    ok(t.includes("{{ .Email }}") && /negeren/.test(t) && /ignore this email/.test(t), `${key}: reden en 'niet jij'`);
    ok(!/afmelden|unsubscribe/i.test(t), `${key}: transactioneel, geen afmeldlink`);
    ok(!/supabase/i.test(t), `${key}: geen namen van derden`);
    // Go-acties alleen op de bekende plekken (geen kapotte {{ … }})
    for (const a of t.match(/\{\{[^}]*\}\}/g) ?? []) {
      ok(/^\{\{ (\.TokenHash|\.RedirectTo|\.Token|\.Email|\.NewEmail|\.Data\.first_name|else|end|if \.Data\.first_name|if and \.Data\.lang \(eq \.Data\.lang "nl"\)) \}\}$/.test(a), `${key}: ${a}`);
    }
  }
  ok(renderAuth("recovery", "nl").includes("Nieuw wachtwoord kiezen") && renderAuth("recovery", "en").includes("Choose a new password"), "teksten");
  ok(renderAuth("email_change", "nl").includes("{{ .NewEmail }}"), "nieuw adres");
  ok(renderAuth("confirmation", "nl").includes("type=signup&amp;lang=nl&amp;next={{ .RedirectTo }}"), "bevestigen met next");
  ok(!renderAuth("recovery", "en").includes("next="), "recovery zonder next (altijd naar reset/)");
  // aanhef met de voornaam uit user_metadata, alleen als die er is
  for (const key of Object.keys(TEMPLATES)) {
    ok(renderAuth(key, "nl").includes(">Hoi {{ .Data.first_name }},</p>{{ end }}"), `${key}: aanhef NL`);
    ok(renderAuth(key, "en").includes("{{ if .Data.first_name }}<p") && renderAuth(key, "en").includes(">Hi {{ .Data.first_name }},</p>"), `${key}: aanhef EN`);
  }
});

Deno.test("aanhef: voornaam opschonen en escapen", () => {
  ok(personName("  Léon \n  van  der ") === "Léon van der", "trimmen en witruimte");
  ok(personName("<b>Jan</b>") === "bJan/b", "geen < >");
  ok(personName("x".repeat(80)).length === 50 && Array.from(personName("😀".repeat(60))).length === 50, "max. 50 tekens");
  ok(personName("kijk op https://evil.example") === "" && personName("www.spam.nl") === "" && personName("a@b.nl") === "", "geen links of adressen");
  ok(personName(42) === "" && personName(null) === "", "alleen tekst");
  ok(firstNameOf({ user_metadata: { first_name: " Anna ", last_name: "B" } }) === "Anna", "uit de gebruiker");
  ok(firstNameOf({ first_name: "Piet" }) === "Piet" && firstNameOf({ user_metadata: {} }) === "" && firstNameOf(null) === "", "uit metadata of leeg");
  ok(greetingText("nl", "Léon") === "Hoi Léon," && greetingText("en", "Léon") === "Hi Léon," && greetingText("nl", "") === "", "tekst");
  ok(greeting("en", "Tom & Jerry's") === `<p style="margin:0 0 12px;font-size:15px;line-height:23px;font-weight:600;color:#ffffff">Hi Tom &amp; Jerry&#39;s,</p>`, "html ge-escaped");
  ok(greeting("nl", undefined) === "", "zonder naam geen aanhef");
});
