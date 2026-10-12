# Bingr: werkafspraken

- Versie blijft 1.0.0. Elke nieuwe build verhoogt `CURRENT_PROJECT_VERSION` in `project.yml`, en `BINGR_BUILD` in `gradle.properties` van de repo bingr-android. Beide hebben hetzelfde nummer.
- iOS, tvOS en macOS gaan altijd samen mee in een build. GitHub Actions bouwt ze bij elke push naar `main`; het resultaat komt op de branch `ci-logs` (`latest.txt`, `Bingr-xcode.zip`).
- Bij elke build:
  - Zet een item in `docs/changelog.json` (NL en EN, met platforms `apple`, `android` en/of `web`).
  - Draai `python3 tools/make_changelog.py` voor `CHANGELOG.md` hier.
  - Draai `python3 tools/make_changelog.py --android ../bingr-android` voor de changelog daar. De Android-workflow haalt daaruit de release-notities.
  - Draai `python3 tools/sync_website.py --site ../bingr-website` (screenshots, buildnummer, changelog), en commit en push daarna ook de website-repo.
- Accounts (Supabase): het contract staat in `docs/ACCOUNT.md`, de backend in `supabase/`. De workflow `Backend` zet schema, functie, e-mailtemplates en app-sleutels klaar.
- Geheime sleutels nooit in de repo; de repo is openbaar. De Supabase-URL en de publishable key mogen er wel in.
