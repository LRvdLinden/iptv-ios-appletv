# Bingr: werkafspraken

- Versie blijft 1.0.0. Elke nieuwe build verhoogt `CURRENT_PROJECT_VERSION` in `project.yml`, en `BINGR_BUILD` in `gradle.properties` van de repo bingr-android. Beide hebben hetzelfde nummer.
- iOS, tvOS en macOS gaan altijd samen mee in een build. GitHub Actions bouwt ze bij elke push naar `main`; het resultaat komt op de branch `ci-logs` (`latest.txt`, `Bingr-xcode.zip`).
- Bij elke build:
  - Zet een item in `docs/changelog.json`: per build `items` met per punt `type` (`new`, `improved` of `fixed`), `platforms` (`ios`, `ipados`, `tvos`, `macos`, `android`, `androidtv` (= Android TV, Google TV en Fire TV), `tizen` (= Samsung TV, vanaf build 55), `web`) en de tekst in `nl` en `en`. Kies de platforms per punt precies: alleen waar het echt voor geldt.
  - Draai `python3 tools/make_changelog.py` voor `CHANGELOG.md` hier.
  - Draai `python3 tools/make_changelog.py --android ../bingr-android` voor de changelog daar (Android, Android TV en Samsung TV/Tizen). De Android-workflow haalt daaruit de release-notities voor de APK en de .wgt.
  - "Alle apps" betekent alle apps incl. `tizen`; voor builds < 55 geldt een punt met de zes oudere apps ook als "Alle apps" (zie `tools/make_changelog.py`, `TIZEN_FROM`).
  - Draai `python3 tools/sync_website.py --site ../bingr-website` (screenshots, buildnummer, changelog), en commit en push daarna ook de website-repo.
  - Controleer daarna dat de workflow `Website` in bingr-website geslaagd is en dat bingr.online het nieuwe buildnummer toont. Is de upload mislukt, start hem dan opnieuw. Elke build hoort in de changelog op de website te staan.
- Accounts (Supabase): het contract staat in `docs/ACCOUNT.md`, de backend in `supabase/`. De workflow `Backend` zet schema, functie, e-mailtemplates en app-sleutels klaar.
- Geheime sleutels nooit in de repo; de repo is openbaar. De Supabase-URL en de publishable key mogen er wel in.
