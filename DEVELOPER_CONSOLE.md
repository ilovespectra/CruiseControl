# Cruise Control Publisher

Cruise Control's repository includes a separate macOS maintainer utility and its binary repackaging source. The Publisher target is not embedded in `Cruise Control.app`; normal app builds still build only the user application.

## Build and preview

Build the console from the repository root with `swift build --product CruiseControlPublisher`. In the Publisher window, choose this source checkout and select **Build preview**. A preview uses the latest clean, pushed production commit and writes an unsigned local preview under `build/releases/`; it does not create a GitHub release. For the regular app, use `scripts/build-app.sh`.

The repackage script refuses a dirty checkout or a checkout that is not exactly at the latest pushed production commit. It stages the build in a temporary directory and keeps prior output intact if the selected version's output directory already exists.

The console chooses the next version from the highest stable GitHub release, the app bundle's current version, and any local `build/releases/*/release.json` candidates. Version comparison is numeric; historical versions with multi-digit minor or patch fields remain valid, but new versions roll digits at nine (`1.0.9` → `1.1.0`; `1.9.9` → `2.0.0`). A local staged `1.0.13` therefore makes the next candidate `1.1.0`, without rewriting that old candidate. A preview does not publish a release or change the public download feed.

## Official publishing boundary

Publishing requires the explicit confirmation in the Publisher and `gh` authenticated to GitHub. Before reading release metadata or building for publication, the script verifies that the authenticated login is the owner of `ilovespectra/CruiseControl`, that the repository metadata names that same owner, and that the account has `admin: true`. A clone's own credentials cannot publish to the official repository unless GitHub grants that account those actual permissions. No GitHub tokens, signing keys, or owner credentials are stored in this source or the user app.

The Publisher's current release action is explicitly unsigned (`--publish --unsigned`), so macOS may show an installation warning. Signed/notarized packaging is available to the script only when the maintainer provides valid Developer ID identities and a local notary keychain profile; do not put those credentials in the repository.

## Scope

This protects the official GitHub release, not modified forks. Public source cannot prevent someone from editing and running their own copy. The installed Cruise Control updater consumes official release artifacts and checks their published SHA-256 manifest; it does not receive Publisher credentials.
