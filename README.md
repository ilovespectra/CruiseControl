# Cruise Control

A macOS notch companion that keeps HeyClicky tasks moving while you're away. Choose **Manual** to answer prompts yourself, **Rest** to deny driving, or **Cruise** to approve it. Optional local Ollama nudges help stalled tasks continue; VS Code automation is opt-in.

Independent, open-source public beta. **Not affiliated with HeyClicky.**

**Warning:** auto-approval removes human review. Agents can delete files, expose secrets, or spend money. Use backups and supervise important work. Hiding the notch does not stop automation.

In **Cruise** mode the notch dropdown stays visible even when HeyClicky is closed, keeping VS Code automation controls accessible. The HeyClicky-only visibility preference applies to Manual and Rest modes. Explicitly hiding the notch and briefly hiding it for synthetic clicks still work.

[Website](https://cruise.kolektivkrog.si) · [Documentation & safety](https://cruise.kolektivkrog.si/docs.html)

## Install

Requires **macOS 14+**.

1. [Download the latest installer](https://github.com/ilovespectra/CruiseControl/releases/latest/download/CruiseControl.pkg) and open it. It installs the app and an always-running login agent.
2. Grant **Accessibility** in System Settings → Privacy & Security. **Screen Recording** is optional for screen-reading fallback.
3. Open Cruise Control from Applications. Start in **Manual** and review Settings before enabling automation.

The installer is unsigned and not notarized, so macOS may warn or block it. Review the project before approving installation. A small Ollama status icon in the dropdown opens the Ollama section in Settings, where you can check health, [install the official Ollama app](https://ollama.com/download/mac), start it and pull a model—no Terminal required. Cruise Control does not bundle the runtime or model weights: they have separate licensing, update, storage and download-consent considerations; model downloads can be large and model terms vary.

Ollama is optional for HeyClicky nudges, which use fallback text when it is off or unavailable. Ollama is load-bearing for enabled VS Code request reviews, model-progress checks and chat follow-ups: if a review cannot run, the request is left for you; failed checks do not auto-escalate or send a follow-up. This changes which response-handling features can run; it is not a measured promise of a night-and-day speed improvement.

To stop automation, choose Manual and disable the separate VS Code approval/model switches and HeyClicky updates. Already-running agents must be stopped in their own app.

Stopping an individual HeyClicky task takes priority over automatic recovery. **Stopped**, **Stopped by you**, paused and cancelled tasks receive no automatic follow-up or Retry, even when tracked by task audits. Stops are remembered across Cruise Control restarts; resume the task yourself in HeyClicky to allow recovery again. Interrupted/crashed tasks remain recoverable when their chat can be verified.

In Cruise mode, recovery also recognizes **Didn't finish** timeout/error cards and prefers their **Retry** button. Failed presses do not spend continuation budget or start a long recovery cooldown. Visible Retry controls in the already-verified task can be pressed without moving the pointer; opening another chat still waits for idle input. VS Code checks every window, reviews live carousel inputs rather than stale chat descriptions, and rotates failed approvals so one stuck request cannot starve the others. “Allow All” is handled as individual reviewed approvals, not a blanket grant. Dialog clicks are a last resort while idle, after verifying the owning window and hit-testing the same reviewed button; sidebar approvals remain background-only.

**Settings → Automation → VS Code → Allow file edits without a readable diff** is a separate, persistent opt-in (off by default). VS Code's **Write file?** and **Create file?** dialogs sometimes expose only file names and change counts, without a text-area title, full paths or edit contents. With this switch enabled, Ollama can review that metadata and approve the edit or creation; this can include files outside the workspace and does not constitute a review of the diff. With it disabled, Cruise holds these requests and explains why in the activity log and the Settings approval status. Ollama-rejected commands remain held regardless of this switch.

**Allow tool permissions (including session grants)** in the same Settings section is another independent, persistent opt-in, off by default. It covers **Allow tool from …?** prompts for Pylance and other providers, after Ollama reviews the exposed tool/provider identity and scope. Hidden inputs are not reviewed. **Allow in this Session** can authorize subsequent tool calls without individual confirmation; disabling this switch stops new Cruise grants but does not revoke permissions already granted in VS Code. Cruise does not press permanent/always-allow or workspace-wide tool grants. The main VS Code approval switch and usage cutoff still apply.

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

For an administrator-owned installation, use the packaged macOS installer instead of `--install`; the development script leaves the existing login agent running when it cannot replace the app.

Open `site/index.html` or `site/docs.html` to preview the website. Website tests require Node.js:

```sh
node --test Tests/site/downloads.test.mjs
```

Uninstall the app and login agent with `./scripts/build-app.sh --uninstall`. Local settings are preserved.

## Contribute

[Open an issue](https://github.com/ilovespectra/CruiseControl/issues) or submit a pull request. Keep changes focused, add tests for behavior changes, and update the docs when needed. Include macOS/app versions in bug reports and redact private information from logs.
