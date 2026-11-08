# Cruise Control

A macOS notch companion that keeps HeyClicky tasks moving while you're away. Choose **Manual** to answer prompts yourself, **Rest** to deny driving, or **Cruise** to approve it. Optional local Ollama nudges help stalled tasks continue; VS Code automation is opt-in.

Independent, open-source public beta. **Not affiliated with HeyClicky.**

**Warning:** auto-approval removes human review. Agents can delete files, expose secrets, or spend money. Use backups and supervise important work. Hiding the notch does not stop automation.

[Website](https://cruise.kolektivkrog.si) · [Documentation & safety](https://cruise.kolektivkrog.si/docs.html)

## Install

Requires **macOS 14+**.

1. [Download the latest installer](https://github.com/ilovespectra/CruiseControl/releases/latest/download/CruiseControl.pkg) and open it. It installs the app and an always-running login agent.
2. Grant **Accessibility** in System Settings → Privacy & Security. **Screen Recording** is optional for screen-reading fallback.
3. Open Cruise Control from Applications. Start in **Manual** and review Settings before enabling automation.

The installer is unsigned and not notarized, so macOS may warn or block it. Review the project before approving installation. [Ollama](https://ollama.com) is optional for HeyClicky nudges; configure it in Settings.

To stop automation, choose Manual and disable the separate VS Code approval/model switches and HeyClicky updates. Already-running agents must be stopped in their own app.

## Local development

Install Xcode Command Line Tools (`xcode-select --install`), then:

```sh
git clone https://github.com/ilovespectra/CruiseControl.git
cd CruiseControl
swift build
swift test
./scripts/build-app.sh             # build the app without installing
./scripts/build-app.sh --install   # install locally and start the login agent
```

Open `site/index.html` or `site/docs.html` to preview the website. Website tests require Node.js:

```sh
node --test Tests/site/downloads.test.mjs
```

Uninstall the app and login agent with `./scripts/build-app.sh --uninstall`. Local settings are preserved.

## Contribute

[Open an issue](https://github.com/ilovespectra/CruiseControl/issues) or submit a pull request. Keep changes focused, add tests for behavior changes, and update the docs when needed. Include macOS/app versions in bug reports and redact private information from logs.
