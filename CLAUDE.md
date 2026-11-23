# CLAUDE.md

The iOS app of Oiseau pourri: a native SwiftUI port of the Android app in the main
repository (`PL4Y3R51/oiseau-pourri`, `apps/android`), kept here, public, while there is no
Mac, so CI runs on GitHub's free macOS runners. Read `README.md` first.

## How to work here

- **The Android app is the reference.** A screen or rule is translated from its Android
  file (named in a comment), not redesigned. The spec is `oiseaupourri-cahier-des-charges-v4.md`
  in the main repository.
- **Strings, contract and assets are never edited by hand**: `node tools/sync-from-monorepo.mjs`
  brings them from the main repository's `origin/main`, then `node tools/gen-models.mjs`. A
  string the iOS app alone needs goes in `project.yml` (Info.plist texts) or, if it is a
  real UI text, into the Android `strings.xml` first.
- **Pure logic goes in `OiseauCore`** (no SwiftUI, UIKit, MapKit or Security), with tests,
  so it is compiled and tested without a Mac. A rule that matters gets a test that goes red
  when the rule is broken; check it by breaking the rule once.
- **The app (`App/`) is written without a compiler at hand.** CI is the compiler: push the
  work branch, read the run (`gh run watch`, `gh run view --log-failed`), download the
  screenshots (`gh run download`) and look at them before calling a screen done.
- Every user-visible text goes through `L("key")`; never hard-code French in Swift.
- Never hard-code a colour in a view: use `Zine.*` (mirror of `ui/theme/Color.kt`).

## Windows

`swift build` / `swift test` need the VS 2022 Build Tools (C++ and Windows SDK), a
developer shell (`Enter-VsDevShell`), `SDKROOT` set, and `--build-system native` (Swift
6.4's new build engine does not pass the MSVC include paths to clang).

## Git

Work on a branch `<issue>-<slug>`, never on `main`. Pushing the work branch is fine (that is
how the app gets built); opening or updating a PR, and anything on `main`, needs the owner's OK.
