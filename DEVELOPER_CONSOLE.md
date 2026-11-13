# Cruise Control Publisher

Build the macOS web-console launcher with `bash scripts/build-dev-console.sh`; the resulting app is `build/Cruise Control Publisher.app`. Build products, durable console state, experimental screenshots and local task evidence are ignored by Git; reusable logo originals and app PNG resources are tracked.

<img src="site/assets/brand/blue-gauge.jpg" alt="Cruise Control gauge" width="72" height="72" />

Build a preview, prepare a GitHub draft, then review and publish. Publisher is a separate macOS maintainer utility; regular app builds include only Cruise Control.

## Build and preview

The **Commit staged changes…** button commits the current Git index only, preserving unstaged edits and existing hooks/signing. Enter a message or leave it blank to let local Ollama (`127.0.0.1:11434`, model `CC_OLLAMA_MODEL` or `qwen2.5:3b`) draft a concise subject from the staged diff. It refuses to commit if the index changes during drafting. Commit output and failures persist in build history. The UI asks for confirmation before committing; push separately before packaging.

Launch the persistent browser UI with `python3 scripts/dev-console.py --start`, or build/run `CruiseControlPublisher`, choose your checkout, and click **Open developer console**. It installs a per-user LaunchAgent (`com.ilovespectra.cruisecontrol.devconsole`) so the console comes back after login or a crash. It listens only at `http://127.0.0.1:3347`. Set `CRUISE_CONSOLE_PORT` before starting to use a different local port.

For foreground operation, run `python3 scripts/dev-console.py` and open that URL. If launchd is denied access to a checkout in Documents, grant the actual Python.app interpreter Files and Folders / Full Disk Access in macOS settings, then retry. Permission is never bypassed; failed startup stops the service and reports the log location. With Homebrew, Python.app can differ from the `python3` launcher path. Until permission is granted, the console must remain foreground-only.

The UI shows build history, the selected next version, exact source commit, exit status, and compilation output including errors. Logs and SQLite job records live in ignored `build/developer-console/`. Independent workers hold an OS build lock and continue if the browser or HTTP service restarts; a dead worker is marked interrupted rather than successful. Reopening the browser reconnects to durable output. Only one repackage job can run at a time.

Requests require the exact loopback Host, same-origin POSTs and a per-server session token. Credentials remain with `gh`; the browser never receives them. Local previews can read public GitHub release metadata without GitHub authentication. Draft uploads still enforce official-owner/admin authorization in the packaging script, not merely in the UI.

To stop persistence: `launchctl bootout gui/$(id -u)/com.ilovespectra.cruisecontrol.devconsole`, then remove that exact plist from `~/Library/LaunchAgents/`. Existing build workers are independent and are not cancelled by stopping the HTTP service. Preserve build output/logs for diagnosis.

Build the launcher from the repository root with `swift build --product CruiseControlPublisher`. In the Publisher window, choose this source checkout and open the console. Select **Repackage local preview** in the web UI. A preview uses the latest clean, pushed production commit and writes an unsigned local preview under `build/releases/`; it does not create a GitHub release. For the regular app, use `scripts/build-app.sh`.

Start from a clean checkout at the latest pushed production commit. The repackage script checks both, stages the build in a temporary directory, and preserves existing version output.

The console chooses versions with numeric ordering and rolls digits at nine (`1.0.9` → `1.1.0`; `1.9.9` → `2.0.0`). Draft versions follow the latest stable release and app baseline; previews also account for staged local candidates. Previews stay local.

## Owner-only GitHub drafts

Choose **Repackage GitHub draft…** to prepare a release for review. The script checks that `gh` is authenticated as the owner of `ilovespectra/CruiseControl` with `admin: true`; other accounts get a local preview. Authentication stays with `gh`, outside the source and user app.

The draft flow:

1. Builds the production commit in an isolated workspace and runs tests.
2. Verifies the app signature, universal architectures, package, release manifest and SHA-256 file.
3. Uses local Ollama to select up to four relevant commit subjects for the release notes, alongside build facts.
4. Uploads the package and checksums to a GitHub **draft**, then checks its state, source commit and asset digests/sizes.
5. Leaves publication to the owner after review. Unsigned packages may trigger macOS installation warnings.

## Scope

The installed updater uses official release artifacts and checks their published SHA-256 manifest. Publisher credentials remain separate from the installed app.
