# Bingr: werkafspraken

- Versie blijft 1.0.0. Elk platform heeft zijn eigen build. Buildnummers zijn één doorlopende reeks: een nieuwe build krijgt het volgende vrije nummer (hoogste build in `docs/changelog.json` + 1), en alleen de platforms die echt veranderen krijgen dat nummer. Wat niet verandert, krijgt geen nieuwe build.
  - Apple (iOS, iPadOS, tvOS, macOS): `CURRENT_PROJECT_VERSION` in `project.yml`, alleen verhogen als de Apple-apps veranderen.
  - Android, Android TV en Samsung TV (Tizen): `BINGR_BUILD` in `gradle.properties` van bingr-android, alleen verhogen als die apps veranderen (APK en .wgt komen in één release).
  - Website (`web`) en server (`server`): geen buildnummer in een bestand; hun build is het nummer van de changelog-build waarin ze veranderen. De website toont de nieuwste build met een punt voor `web`.
  - Een build die alleen de website en/of server raakt, verhoogt dus niets in `project.yml` of `gradle.properties`.
- iOS, tvOS en macOS gaan altijd samen mee in een Apple-build. GitHub Actions bouwt ze bij elke push naar `main`; het resultaat komt op de branch `ci-logs` (`latest.txt`, `Bingr-xcode.zip`).
- Bij elke build:
  - Zet een item in `docs/changelog.json` (één item per build, alleen met punten voor de platforms in die build): per build `items` met per punt `type` (`new`, `improved` of `fixed`), `platforms` (`ios`, `ipados`, `tvos`, `macos`, `android`, `androidtv` (= Android TV, Google TV en Fire TV), `tizen` (= Samsung TV, vanaf build 55), `web` (= de website bingr.online), `server` (= de backend: Supabase, accounts, sync en limieten)) en de tekst in `nl` en `en`. Kies de platforms per punt precies: alleen waar het echt voor geldt.
  - Draai `python3 tools/make_changelog.py` voor `CHANGELOG.md` hier.
  - Draai `python3 tools/make_changelog.py --android ../bingr-android` voor de changelog daar (Android, Android TV en Samsung TV/Tizen). De Android-workflow haalt daaruit de release-notities voor de APK en de .wgt.
  - "Alle apps" betekent alle apps incl. `tizen`; voor builds < 55 geldt een punt met de zes oudere apps ook als "Alle apps" (zie `tools/make_changelog.py`, `TIZEN_FROM`).
  - Draai `python3 tools/sync_website.py --site ../bingr-website` (screenshots, buildnummer, changelog), en commit en push daarna ook de website-repo.
  - Controleer daarna dat de workflow `Website` in bingr-website geslaagd is en dat bingr.online het nieuwe buildnummer toont. Is de upload mislukt, start hem dan opnieuw. Elke build hoort in de changelog op de website te staan.
- Accounts (Supabase): het contract staat in `docs/ACCOUNT.md`, de backend in `supabase/`. De workflow `Backend` zet schema, functie, e-mailtemplates en app-sleutels klaar.
- Geheime sleutels nooit in de repo; de repo is openbaar. De Supabase-URL en de publishable key mogen er wel in.
- Admin-dashboard: staat in de privé-repo LRvdLinden/bingr-beheer (https://beheer.bingr.online, functie `admin`). Wijzigingen daaraan nooit in de changelog.
