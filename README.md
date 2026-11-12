# Cruise Control

Set your own pace with HeyClicky on macOS. Choose how drive prompts are handled, organize tasks around a saved goal, and inspect local storage.

Independent open-source software; not affiliated with or endorsed by HeyClicky.

> **Safety:** Cruise mode automatically approves drive prompts, removing a human checkpoint. Agents can change or delete files, access data, take actions, or spend money. Start in Manual, keep backups, and use a restricted environment. Cruise is not a sandbox or a guaranteed spending limit.

Latest published release: [![Latest GitHub release](https://img.shields.io/github/v/release/ilovespectra/CruiseControl?display_name=tag&label=latest)](https://github.com/ilovespectra/CruiseControl/releases/latest). The download link below follows GitHub's latest stable release. These docs describe current source; the release notes identify the published build, but do not independently verify every feature. Task-message delivery requires a same-task transcript receipt, and Storage totals may be partial when a root is unavailable.

## Download and install

Requires macOS 14 or later.

**[Download the latest macOS installer](https://github.com/ilovespectra/CruiseControl/releases/latest/download/CruiseControl.pkg)** · [Release notes](https://github.com/ilovespectra/CruiseControl/releases/latest)

1. Open the downloaded installer.
2. Grant Accessibility in System Settings → Privacy & Security. Screen Recording is optional.
3. Open Cruise Control and begin in **Manual**; review Settings before enabling automation.

The installer is unsigned and not notarized, so macOS may warn or block it. Do not disable system protections to install it; inspect the source and release notes first.

## Build and run locally

Requires macOS 14 or later and Xcode Command Line Tools (`xcode-select --install`). From a checkout:

```sh
swift test
./scripts/build-app.sh
open "build/Cruise Control.app"
```

To install this local build in `/Applications` and register its login agent, use `./scripts/build-app.sh --install`. This changes the installed app; if it is administrator-owned, update it with the packaged installer instead.

## Contribute

Start with [CONTRIBUTING.md](CONTRIBUTING.md), then [open an issue](https://github.com/ilovespectra/CruiseControl/issues) or submit a focused pull request. Add tests for behavior changes and redact private information from logs.

## More

- [Feature guide and safety notes](https://cruise.kolektivkrog.si/docs.html)
- [Publisher and release safeguards](DEVELOPER_CONSOLE.md) (maintainers)
- [Source code](https://github.com/ilovespectra/CruiseControl)
