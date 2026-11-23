# Oiseau pourri — iOS

The iOS app of [Oiseau pourri](https://oiseaupourri.ch), a native SwiftUI port of the
Android app (`apps/android` in the main repository). It lives in this separate public
repository for now so its builds run on GitHub's free macOS machines; it moves into the
main repository as `apps/ios` once there is a Mac to develop on.

**Status:** step 1 (#1): sign-in and the map, read-only. Never run on a real iPhone yet.

## Layout

| Path | What |
|---|---|
| `Package.swift`, `Sources/OiseauCore` | Plain Swift, no Apple-only framework: API client and errors, session cookies, sign-in, the map's data and rules. Builds and tests on Windows, Linux and macOS. |
| `Sources/OiseauCore/Generated/Models.swift` | The API's models, generated from `contract/openapi.json` by `tools/gen-models.mjs`. |
| `Tests/OiseauCoreTests` | Translated from the Android unit tests, plus the API's recorded answers (`Fixtures/contract`). |
| `App/` | The SwiftUI app: theme, welcome, login, map (MapLibre), bird sheet. |
| `AppTests/` | Screenshot tests: every screen drawn in the simulator and saved as PNG. |
| `AppUITests/` | One journey against the in-memory stub API: welcome → sign-in → map → a bird → sign out. |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated, never committed. |
| `tools/sync-from-monorepo.mjs` | Copies the API contract, the Android strings, icons, mascot and font from the main repository. |

## Commands

```bash
swift test                              # OiseauCore, any OS (Windows: see CLAUDE.md)
node tools/gen-models.mjs               # after the contract changed
node tools/sync-from-monorepo.mjs       # contract, strings and assets from ../oiseau-pourri (origin/main)
```

On a Mac:

```bash
brew install xcodegen
xcodegen generate
open OiseauPourri.xcodeproj
```

Debug talks to `http://localhost:3000` (the main repository's `pnpm dev`), Release to
`https://oiseaupourri.ch`. Launch arguments: `-stubApi` (an in-memory API with the dev
seed's `alice@example.com` / `password123`), `-resetState` (start signed out).

## CI

Every push runs `.github/workflows/ci.yml`: `swift test` on Linux, then on macOS the
project is generated, built for an iPhone simulator, and the unit, screenshot and UI tests
run. Screenshots and logs are uploaded as the run's artifact.

## The rules it follows

- Same game, same words: strings come from the Android `strings.xml` (same keys, French),
  colours and type from the Zine look (spec §14).
- Same contract: models are generated from the API's `openapi.json`; the recorded answers
  of the API's test suite are decoded in `ContractTests`.
- Unreachable is offline (issue #89 in the main repository): no network, a 5xx or a timeout
  never signs the player out or wipes the saved map.

## Sur un vrai iPhone (sans compte développeur payant)

Each CI run uploads `ipa-<run>`: `OiseauPourri-unsigned.ipa`, a Release build talking to
`https://oiseaupourri.ch`, unsigned. To put it on your own iPhone (iOS 17+) with a free
Apple ID:

1. Download it: `gh run download <run-id> -n ipa-<run-number>` (or from the run's page).
2. Sign and install it with a sideloading tool (Sideloadly or AltStore, on Windows or a Mac)
   and your Apple ID, the iPhone plugged in.
3. On the iPhone: Réglages ▸ Confidentialité et sécurité ▸ Mode développeur, then trust
   your Apple ID under Réglages ▸ Général ▸ VPN et gestion de l'appareil.

With a free Apple ID the install lasts 7 days, push notifications and links that open the
app don't work. Those need the paid Apple Developer Program.
