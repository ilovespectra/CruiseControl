# Cruise Control

A macOS companion that can automatically approve HeyClicky's normal drive prompts while you're away. Use **Manual** to answer yourself, **Rest** to deny prompts, or **Cruise** to approve them. Optional VS Code automation is separate and opt-in.

Independent, open-source public beta. **Not affiliated with HeyClicky.**

**Warning:** auto-approval removes human review. Agents can delete files, expose secrets, or spend money. Use backups and supervise important work. Hiding the notch does not stop automation.

Release versions follow the digit-rollover policy: `1.0.8` → `1.0.9` → `1.1.0`, and `1.9.9` → `2.0.0`. The latest public release is `1.1.0`; its installer is unsigned and not notarized, so macOS may warn. The download link below follows published GitHub releases only.

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

For an explicit end-to-end delivery diagnostic, stop the normal LaunchAgent first, then run `CruiseControl --verify-clicky-delivery "Task name"` while Cruise is enabled and input is idle. Unlike the inspection commands, this **sends a uniquely identified receipt-only test message** through the normal durable sender; it asks HeyClicky not to perform any other work. It returns success only after finding that message in the same task's transcript. Restart the normal LaunchAgent afterwards, including if verification fails; an unconfirmed message remains saved for its normal retry/review flow.

**Settings → Tasks** is a dedicated, searchable HeyClicky task workspace, also reachable through **tasks** in Cruise Control's dropdown. Its user story is simple: find a job by project, set a local priority, define a verifiable result in your own words, then compare that goal with the latest actual HeyClicky response. The task card keeps reported state, report evidence, criteria gaps, and unknown status distinct; “reported done” is never treated as independent proof. Project and priority controls organize Cruise's local review list and do not reorder HeyClicky's queue. It reads local job records and thread excerpts, including tasks not visible on screen, and uses stable job IDs so same-named tasks remain separate. Choose **Project**, **Workspace**, or **All tasks** grouping, with search, filters, and optional sorting. Set a task's local workspace folder with the folder chooser when the conversation does not identify it; this path is organizational metadata and does not move or edit files. A project and its GitHub repository are one entity, not separate organization modes. **Infer projects with local Ollama** uses requests, both sides of thread excerpts, reports, links and paths; only model confidence of at least 0.9 with a literal supporting quote and grounded project identity is accepted. This is a conservative model score, not a calibrated probability. Uncertain tasks remain **Unspecified**. Errors are displayed, and a remote Ollama endpoint is not used for this review. Expand a task to choose an existing project or **Correct project…** with just a name; repository details are optional, and a workspace folder can be set separately per task. Explicit corrections, including **Leave unspecified**, survive refresh/restart and are never replaced. **Infer again** removes that override. Refresh never opens tasks or sends messages. Optional size measurement scans caches and working folders; shared folders contribute to each task's size, not additional disk usage.

**Thread-owned project evidence:** Cruise joins each job's current and historical `threadID` values to `AgentHarness/h1-local/<threadID>/turns.json`, the harness `job.json` working directory, `HomeSpaceCache/transcript-<threadID>.json`, and read-only Codex `threads.id` metadata (`cwd`, `git_origin_url`). It never joins by nickname, guesses a similar folder, or imports another thread's tool traces. Expand **Thread evidence** to see source/thread provenance and read errors. Missing optional stores are allowed; malformed stores are reported. Path traversal, symlink escapes and oversized JSON files are rejected. Historical evidence informs grouping, not completion status or permission to resume work.

**Independent task review & replies** is a separate, off-by-default setting. It reviews selected tasks in Manual or Rest mode even with all drive, auto-allow and ordinary continuation features disabled. Save a definition of done and explicitly enable **Include in background task review** for each task. Set High/Normal/Low project priorities on project cards, with an optional task override beside **Define done…**. Eligible work is reviewed in ranked order, not strict finish-one-project-first order. Working, stopped, dismissed, empty-report and user-blocked tasks are excluded; the usage cutoff still applies. Reviews use local Ollama and recheck report/goal/opt-in freshness after assessment.

**Reply delivery** has two explicitly different policies:
- **API-only (replies held)** is the default. No supported current HeyClicky background-send API was found. Replies stay saved; no chat navigation, focus, typing, clicking or Return is used. Cache and SQLite writes are not a sending API; Cruise never uses them to inject messages.
- **Chat-only UI while idle** is a separate opt-in, not an API. It can open/select a unique HeyClicky task, populate its empty composer and send while input is idle. It uses the durable sender, transcript receipts, stopped-task checks and continuation budgets/round limits. Duplicate nicknames block routing. Saved messages retain their stable task ID, report fingerprint, goal and chat-only policy across restarts. Disabling task review/opt-in, changing delivery back to API-only, changing the goal or reaching a usage limit stops submission; edits and uncertain sends are held rather than overwritten or resent. Only a same-task transcript receipt marks a reply delivered.

Neither policy enables drive/auto-allow switches, approves tools/permissions or bypasses a pending drive request. Chat-only messages instruct the agent to stop and report blockers requiring screen control or grants; this is not a sandbox for the agent's own tools or previously granted permissions. For chat-only operation, select Manual mode and disable separate VS Code automation; existing automation switches remain independently controlled. Read-only inference diagnostics: `CruiseControl --infer-task-project <jobID>`.

Project assignments, grouping and sorting survive restarts. Earlier name-only assignments migrate only when a name identifies one job; ambiguous or missing assignments remain visible for review rather than attaching to an arbitrary thread. Previously identified tasks missing from a later job list remain cached and marked unavailable.

**Define done…** saves a verifiable completion target for one job ID. **Assess latest report** reads the latest available report against it with local Ollama (or explicitly labelled conservative rules if unavailable); this does not independently verify the work. **Bump now** queues a one-time comparison and follow-up without turning on persistent per-task Auto-bump. That follow-up is grounded in the selected task's latest report and saved criteria; it waits for idle input and is not sent when the report is stale, a decision is needed, identity is ambiguous, or an error/no-progress condition is found. Persistent **Auto-bump this task** requires its own per-task opt-in plus the global **Allow per-task auto-bumps in Cruise mode** gate. New reports and the bounded round limit are required for further bumps. Cruise reads local HeyClicky records; no private HeyClicky API is assumed, and messages use the visible interface only. These task controls never approve permissions, publish, or bypass decisions that need you. The separate **Continue toward saved definitions of done** option permits bounded follow-ups in Cruise mode while **Keep unfinished tasks going** is also enabled. Working, stopped, dismissed, user-blocked and ambiguously named tasks are not automatically resumed. Per-definition round limits, normal continuation budgets and durable delivery protections still apply.

Queued definition-of-done follow-ups retain their job ID and original target across restarts. Editing/removing that target, disabling definition follow-ups, lowering the round limit below the reserved round or losing readable completion history holds the message for review rather than sending against an obsolete goal.

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
