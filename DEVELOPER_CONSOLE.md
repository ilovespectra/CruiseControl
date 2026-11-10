# Cruise Control Publisher

Cruise Control's repository includes a separate macOS maintainer utility and its binary repackaging source. The Publisher target is not embedded in `Cruise Control.app`; normal app builds still build only the user application.

## Build and preview

Build the console from the repository root with `swift build --product CruiseControlPublisher`. In the Publisher window, choose this source checkout and select **Build preview**. A preview uses the latest clean, pushed production commit and writes an unsigned local preview under `build/releases/`; it does not create a GitHub release. For the regular app, use `scripts/build-app.sh`.

The repackage script refuses a dirty checkout or a checkout that is not exactly at the latest pushed production commit. It stages the build in a temporary directory and keeps prior output intact if the selected version's output directory already exists.

The console chooses versions with numeric ordering and rolls digits at nine (`1.0.9` → `1.1.0`; `1.9.9` → `2.0.0`). Draft versions follow the latest stable release and app baseline; previews also account for staged local candidates so an existing preview is never overwritten. A preview never creates a GitHub release or changes the public download feed.

## Owner-only GitHub drafts

Choose **Build GitHub draft…** to create an unpublished release for manual review. Before release metadata is read or release assets are built, the script verifies that `gh` is authenticated as the owner of `ilovespectra/CruiseControl` and that the account has `admin: true`. If that preflight fails, it safely downgrades to a local preview; it never falls back to a public release. Forks and non-owner accounts therefore keep local-only builds. No GitHub tokens or owner credentials are stored in this source or the user app.

The draft flow builds the clean, pushed production commit in an isolated workspace, runs tests, verifies the app signature and universal architectures, and checks the package, release manifest, and SHA-256 file against one another. Local Ollama selects up to four relevant verified commit subjects; the notes use those exact subjects and verified build facts rather than unverified generated claims. The console creates a GitHub **draft** with the package and checksums, reads it back, and verifies its unpublished state, source commit, and uploaded asset digests/sizes. The owner reviews and publishes it manually. Unsigned packages may trigger macOS warnings.

## Scope

This protects the official GitHub release, not modified forks. Public source cannot prevent someone from editing and running their own copy. The installed Cruise Control updater consumes official release artifacts and checks their published SHA-256 manifest; it does not receive Publisher credentials.
