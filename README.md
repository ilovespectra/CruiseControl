# Cruise Control

A macOS companion that can automatically approve HeyClicky's normal drive prompts while you're away. Use **Manual** to answer yourself, **Rest** to deny prompts, or **Cruise** to approve them. Optional VS Code automation is separate and opt-in.

Independent, open-source public beta. **Not affiliated with HeyClicky.**

**Warning:** auto-approval removes human review. Agents can delete files, expose secrets, or spend money. Use backups and supervise important work. Hiding the notch does not stop automation.

Release versions follow the digit-rollover policy: `1.0.8` → `1.0.9` → `1.1.0`, and `1.9.9` → `2.0.0`. The latest public release is `1.0.11`. The `1.1.0` candidate is unverified and unreleased; the download link below follows published GitHub releases only.

In **Cruise** mode the notch dropdown stays visible even when HeyClicky is closed, keeping VS Code automation controls accessible. The HeyClicky-only visibility preference applies to Manual and Rest modes. Explicitly hiding the notch and briefly hiding it for synthetic clicks still work.

The bottom-right screen indicator shows a green gauge and **CRUISE** in Cruise mode, or the dropdown's yellow coffee cup and **REST** in Rest mode. It appears on every display and across Spaces, independently of HeyClicky's visibility; Manual mode hides it. The indicator does not intercept clicks.

[Website](https://cruise.kolektivkrog.si) · [Documentation & safety](https://cruise.kolektivkrog.si/docs.html) · [Maintainer console](DEVELOPER_CONSOLE.md)

**Launch the maintainer console:** From the repository root on macOS 14 or newer, run `swift run --product CruiseControlPublisher`. This builds and launches the Publisher utility; it is separate from `Cruise Control.app`. See [`DEVELOPER_CONSOLE.md`](DEVELOPER_CONSOLE.md) for build-preview and publishing safeguards.

## Install

Requires **macOS 14+**.

1. [Download the latest installer](https://github.com/ilovespectra/CruiseControl/releases/latest/download/CruiseControl.pkg) and open it. It installs the app and an always-running login agent.
2. Grant **Accessibility** in System Settings → Privacy & Security. **Screen Recording** is optional for screen-reading fallback.
3. Open Cruise Control from Applications. Start in **Manual** and review Settings before enabling automation.

The installer is unsigned and not notarized, so macOS may warn or block it. Review the project before approving installation. A small Ollama status icon in the dropdown opens the Ollama section in Settings, where you can check health, [install the official Ollama app](https://ollama.com/download/mac), start it and pull a model—no Terminal required. Cruise Control does not bundle the runtime or model weights: they have separate licensing, update, storage and download-consent considerations; model downloads can be large and model terms vary.

Ollama is optional for HeyClicky nudges, which use fallback text when it is off or unavailable. Ollama is load-bearing for enabled VS Code request reviews, model-progress checks and chat follow-ups: if a review cannot run, the request is left for you; failed checks do not auto-escalate or send a follow-up. This changes which response-handling features can run; it is not a measured promise of a night-and-day speed improvement.

To stop automation, choose Manual and disable the separate VS Code approval/model switches and HeyClicky updates. Already-running agents must be stopped in their own app.

Stopping an individual HeyClicky task takes priority over automatic recovery. **Stopped**, **Stopped by you**, paused and cancelled tasks receive no automatic follow-up or Retry, even when tracked by task audits. Stops are remembered across Cruise Control restarts; resume the task yourself in HeyClicky to allow recovery again. Interrupted/crashed tasks remain recoverable when their chat can be verified.

HeyClicky follow-ups are saved locally before the composer is changed. Cruise confirms delivery in the same task's transcript, retries an unchanged unsent draft, and does not navigate to another task while delivery is pending. Pending messages survive Cruise Control restarts and lost HeyClicky drafts. User-edited drafts and ambiguous submissions are held rather than overwritten or sent twice. **Settings → Activity → Pending HeyClicky message** shows the full saved text, task and delivery status, with an explicit discard action. If the task is stopped, its conversation moves on, or it stays undelivered for 30 minutes, the message remains saved for review rather than being silently deleted or sent stale. Review the chat and copy/revise the saved text if needed, then explicitly discard the delivery record; this does not remove any draft in HeyClicky. Manual mode and disabling **Keep unfinished tasks going** also stop pending-message retries.

In Cruise mode, a closing question from HeyClicky (“Did you mean…?”, “Shall I retry…?”) is treated as an implicit **yes** whenever the latest report still says work is unfinished, missing, incomplete, unconfirmed, pending, not tested/pushed/run, unchanged (“made no edits”, “in the same state”) or that an issue remains. Ollama drafts the follow-up from those report sentences; if it declines or can't ground its draft, Cruise sends a follow-up quoting them verbatim. Credentials, sign-in, payments, permissions, publication and deletion are still left for you.

When HeyClicky taps out in its main chat (**HeyClicky → Your chat**) — a finished task card whose summary still lists unfinished work and ends with a question or suggested next step such as “shall I retry in smaller checkpoints?” — Cruise mode replies there with a **yes** that asks Clicky to split the remaining work into smaller tasks that can each be verified on their own, quoting the unfinished items. Ollama drafts the reply; drafts that don't name the task verbatim or ask for small, verifiable steps are replaced with a deterministic reply. Cruise checks the main chat while you are away, at most once per task-audit interval, skips tasks you stopped or that are still working, never overwrites a draft, and uses the same saved, delivery-verified path as other follow-ups. Turn it off with **Settings → HeyClicky → Answer tap-outs in the main chat**. `CruiseControl --inspect-main-chat` prints the reply it would send without sending it.

In Cruise mode, recovery also recognizes **Didn't finish** timeout/error cards and prefers their **Retry** button. Failed presses do not spend continuation budget or start a long recovery cooldown. Visible Retry controls in the already-verified task can be pressed without moving the pointer; opening another chat still waits for idle input. VS Code checks every window, reviews live carousel inputs rather than stale chat descriptions, and rotates failed approvals so one stuck request cannot starve the others. “Allow All” is handled as individual reviewed approvals, not a blanket grant. Dialog clicks are a last resort while idle, after verifying the owning window and hit-testing the same reviewed button; sidebar approvals remain background-only.

**Settings → Automation → VS Code → Allow file edits without a readable diff** is a separate, persistent opt-in (off by default). VS Code's **Write file?** and **Create file?** dialogs sometimes expose only file names and change counts, without a text-area title, full paths or edit contents. With this switch enabled, Ollama can review that metadata and approve the edit or creation; this can include files outside the workspace and does not constitute a review of the diff. With it disabled, Cruise holds these requests and explains why in the activity log and the Settings approval status. Ollama-rejected commands remain held regardless of this switch.

**Allow tool permissions (including session grants)** in the same Settings section is another independent, persistent opt-in, off by default. It covers **Allow tool from …?** prompts for Pylance and other providers, after Ollama reviews the exposed tool/provider identity and scope. Hidden inputs are not reviewed. **Allow in this Session** can authorize subsequent tool calls without individual confirmation; disabling this switch stops new Cruise grants but does not revoke permissions already granted in VS Code. Cruise does not press permanent/always-allow or workspace-wide tool grants. The main VS Code approval switch and usage cutoff still apply.

**URL fetches** (VS Code's **Fetch URL? Allow fetching web content?** dialog and URL-only sidebar approvals) have their own setting in the same section: **Review each URL with Ollama** (default), **Allow all URL fetches**, or **Leave URL fetches for me**. Allow all skips the Ollama review for requests whose only inputs are `http`/`https` URLs, including localhost and private-network addresses, and approves fetch dialogs even when VS Code doesn't expose a unique URL. It still requires the main VS Code approval switch.

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
