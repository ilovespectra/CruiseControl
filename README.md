# cruise control

The notch dropdown contains only **Manual**, **Rest area**, **Cruise control**, and **Settings**. Settings opens a dedicated window with **Automation**, **Activity**, and **App & permissions** tabs. All automation switches, Ollama configuration, permissions, startup information, log/config shortcuts, and the hide control live there.

The Activity tab shows separate live **HeyClicky** (approved, declined, continued) and **VS Code** (approved, held for review, follow-ups, model switches) counts. They are recorded from actual actions and saved in `activity-stats.json` across restarts and reinstalls. Counts begin at the displayed tracking date; older logs are not guessed or backfilled. VS Code safety holds are not declines, and failed submissions do not count as successes.

> unofficial companion for [heyclicky](https://heyclicky.com) on macOS. **not affiliated with, endorsed by, or connected to heyclicky or its makers.**

HeyClicky asks before it drives your computer ("Go ahead" / "Let HeyClicky drive" vs "Not now"). That's fine while you're at your desk, but long tasks stall while you're away. Cruise Control sits next to the notch while HeyClicky is running and answers those prompts for you, using whichever mode you've picked:

| mode | pill | what happens |
|------|------|--------------|
| manual | `MANUAL` | nothing. you answer prompts yourself |
| rest area | `REST` | every drive request gets **Not now** |
| cruise control | `CRUISE` | every drive request gets **Go ahead** / **Let Clicky Drive** |

In rest and cruise modes it also watches HeyClicky's chat window for a new **Full report** button, which shows up when a task didn't finish. When one appears, Cruise Control clicks it, then types and sends:

> Please continue the users request to implement this particular feature based on your findings

When a **"{task} Needs you"** card shows up in the notch (usually because the task stalled), Cruise Control closes the card, opens that task's chat, and asks a local [Ollama](https://ollama.com) model to draft a short nudge from the conversation. Then it sends the nudge. If Ollama isn't running, it sends `fallbackNudge` instead. Every draft goes through a safety filter: anything that claims you approved something ("assume I selected always allow"), mentions passwords or keys, or tells HeyClicky to skip a permission prompt is redrafted once, and if it's still unsafe the fallback is sent.

**Quiet conversations:** sometimes HeyClicky just stops. The card says *done* but the work isn't finished, or it ends with a question like "May I restart Rippa…?" and waits. Cruise Control watches the conversation in the chat window, or peeks at the notch panel every couple of minutes while you're away. If nothing changes for `stallMinutes` (5), or `busyStallMinutes` (20) while the card still says *working*/*sent*, it opens the chat (**Open in a window**) and asks Ollama to write a reply. The reply answers Clicky's question in the direction that keeps the work going, and never agrees to deleting your data, spending money, messaging people or entering credentials. Then it sends the reply. Each stall gets one reply, within the same rate limits.

**Accidental interrupts:** if you take over mid-drive by mistake (a stray click, say), HeyClicky hands control back with a line like *"Ok, it's all yours"*. In **Cruise** mode Cruise Control notices that hand-back and types a short apology — *"Sorry, I interrupted you by accident — please continue exactly where you left off"* — so the task picks back up. It only fires while you've been idle for `awayIdleSeconds`, so it never fights you when you're actually at the desk working, and it sends one apology per hand-back. Edit the phrases it watches for with `interruptLabels`, the message with `interruptedNudge`, or turn it off with `resumeAfterInterrupt`.

**Interrupted tasks (restarts, crashes):** when the Mac restarts mid-task, HeyClicky's card says *"Rippa Repair · Interrupted — It was cut off before it finished"* with a **Retry** button, and HeyClicky just sits there. Right after Cruise Control (or HeyClicky) launches, and every `stallCheckMinutes` after that, it peeks at the notch while you're idle. For each interrupted task it opens that task's chat and sends a polite bump (`interruptedCardNudge`): *"Sorry about that — you got cut off before you finished… please pick up exactly where you left off"*. If the chat can't be opened, it presses **Retry** instead. Each task gets one bump per 30 minutes, within the usual nudge limits. Interrupted tasks are also resumed after a HeyClicky update.

**Automatic notch inspection:** when the collapsed notch has no positive **Working** count (including an unreadable status), Cruise Control hovers it itself while you're idle, at most once per `stallCheckMinutes` (2 minutes). The expanded scan feeds the same Needs-you, interruption, report, consent, and stall handlers, even when a chat window is already open. It restores the cursor afterward; inspection alone does not send a nudge or bypass existing budgets. Manual mode and active keyboard/mouse use prevent this hover.

HeyClicky sometimes *wrongly* thinks you took over and quietly stops even though you're away (on your phone, say) — often with no message at all. For that, Cruise Control leans on your idle time: once you've been idle for `awayAfterMinutes` (4) it treats you as **away** and swaps the quiet thresholds for the much shorter `awayStallMinutes` (2) / `awayBusyStallMinutes` (8). So a silent stop while you're away gets a continue nudge in a couple of minutes instead of 5–20.

**Updates:** when HeyClicky's Sparkle appcast lists a newer build, Cruise Control presses the notch's **Update app** button. That button only shows while the notch is hovered, so it waits until mouse and keyboard have been idle for `awayIdleSeconds`, briefly hovers the notch, and puts your cursor back. It remembers which tasks were in progress (`pending-relaunch.json`, so this survives restarts). If HeyClicky doesn't relaunch within about 45s it reopens it. After the relaunch, it sends each of those tasks an Ollama-drafted "you were updated, pick up where you left off" message. Updating happens in every mode while **keep heyclicky updated** is on. The post-update nudge is skipped in manual mode. That button only shows while the notch is hovered, so it waits until mouse and keyboard have been idle for `awayIdleSeconds`, briefly hovers the notch, and puts your cursor back. It remembers which tasks were in progress (`pending-relaunch.json`, so this survives restarts). If HeyClicky doesn't relaunch within about 45s it reopens it. After the relaunch, it sends each of those tasks an Ollama-drafted "you were updated, pick up where you left off" message. Updating happens in every mode while **keep heyclicky updated** is on. The post-update nudge is skipped in manual mode.

**macOS permission dialogs:** when HeyClicky triggers a system automation alert — *"HeyClicky" wants access to control "Reason"* — macOS waits on a manual **Allow** / **Don't Allow** click. In **Cruise** mode Cruise Control presses **Allow**; in **Rest Area** it presses **Don't Allow**; in **Manual** it leaves it for you. For safety it only ever touches an alert whose text actually names HeyClicky (`clickyAppNames`); any other app's permission prompt is left alone. It presses via Accessibility first and falls back to a synthetic click. Turn it off with `autoAnswerSystemDialogs`.

**Always allow in VS Code (off by default, risky):** the **always allow in vscode** toggle in the notch dropdown watches VS Code's chat tool confirmations (*"Run in terminal: … Allow Once · Skip"*). It reads the request through Accessibility, runs it past a fixed blocklist (sudo, `rm -rf ~`/`/` or whole personal folders, `find ~ … -delete`, `curl | sh`, base64-to-shell, keychain dumps, SSH/cloud key access, force-push, disk erase, disabling SIP…), then asks your local Ollama model whether it looks malicious. Only if both pass does it press **Allow Once** (never "always"). If anything is flagged, Ollama is down, or the answer is unclear, the prompt is left on screen for you. Every decision goes to the log. Turning it on shows a warning first; the risks are real and go well beyond losing a cache: data loss, leaked secrets, prompt injection from pages or repos the agent reads (which can also try to fool the reviewer), malicious packages, and real-world side effects like deploys or pushes. A small local model is not a security boundary. Test the reviewer without pressing anything: `"/Applications/Cruise Control.app/Contents/MacOS/CruiseControl" --review "rm -rf build && swift build"`.

**Cost-aware VS Code models (off by default):** turn on **use cheaper vscode models** in the Cruise Control dropdown. The active, unambiguous VS Code chat starts with **MAI-Code-1.1-Flash**. Switching preserves that conversation and its history; it does not create another agent, cancel work, resend the task, or interrupt a terminal command. Automatic switches wait for the turn to finish and an empty composer. Other windows and manually selected models are left alone.

**Cruise indicator:** in Cruise mode, a softly illuminated green speedometer and **CRUISE** badge (224 × 96 points) appears at the lower-right of every connected display, above the Dock. Its window level is above ordinary app windows, menus, and desktop overlays, including full-screen spaces. macOS secure system screens can still take precedence. It stays visible when the notch is hidden, follows display and Dock-layout changes, and lets clicks pass through. Manual and Rest modes turn it off. This indicates the selected mode, not that HeyClicky is currently working or that macOS permissions have been granted.

**Task-specific VS Code follow-ups:** enable **keep vscode tasks going** to let local Ollama inspect an idle chat after five quiet minutes in Cruise mode. Only an identified unfinished request gets a brief, labelled text follow-up. Completed conversations are left alone. Follow-ups require an empty composer, an idle user, no running turn or pending approval, and the same focused conversation before sending; no screenshots are taken or attached. Attempts have a 15-minute cooldown, and the same transcript is not answered twice. `chat-bumps.json` persists this history; uncertain submissions are not resent, and failures are logged. This is a conservative local-model judgement, not a guarantee that every unfinished task will be detected.

Ollama reviews only newly observed progress on the cheap model, at most once every five minutes, locally. Three unresolved attempts at the same problem, an explicitly evidenced regression, or at least 20 minutes with stalled progress permits a suggestion to escalate to **GPT-6.1 Sol**, never an automatic escalation. A confirmation dialog shows the evidence and cost warning; **Keep the current model** is the default. Complexity alone, fixed errors, approval waits, and long but productive work do not qualify. The answer must be typed JSON with an exact supporting transcript quote; review failures keep the current model. There is a ten-minute switch/suggestion cooldown and no automatic downgrade after escalation in that conversation. State and recent progress are stored locally in `model-routing.json` so restarting Cruise Control does not reset the budget. Model availability and prices depend on your Copilot account; this is a two-tier preference, not live billing analysis. Selecting a model through the UI cannot enforce or guarantee GitHub's server-side routing; always check the reported executing model if strict endpoint control is required.

## build & install

Needs macOS 14+ and the Swift toolchain (Command Line Tools are enough).

```sh
./scripts/build-app.sh             # builds build/Cruise Control.app
./scripts/build-app.sh --install   # copies to /Applications + installs a LaunchAgent (always running; launchd restarts it if it exits)
./scripts/build-app.sh --uninstall # removes both
swift test                         # unit tests (Swift Testing)
```

Signing uses `$CC_SIGN_IDENTITY` if set, otherwise the first codesigning identity in your keychain. A stable identity keeps your permission grants across rebuilds.

## permissions

- **Accessibility** (required): reads HeyClicky's buttons and presses them, and synthesizes clicks and keystrokes as a fallback.
- **Screen Recording** (optional): an OCR fallback that captures **only HeyClicky's windows** near the notch, in case a prompt isn't exposed through Accessibility.

Grant both in System Settings → Privacy & Security. The dropdown shows a "grant" row for anything that's missing.

## using it

Click the pill next to the notch, then pick a mode. Cruise Control is always running in the background, and the pill appears whenever HeyClicky is open. **hide** tucks the pill away (your mode keeps working). It comes back the next time HeyClicky launches, or when you open Cruise Control from Spotlight/Finder. To stop it for good, run `./scripts/build-app.sh --uninstall`.

## config

`~/Library/Application Support/CruiseControl/config.json` (it's also linked from the dropdown):

| key | default |
|-----|---------|
| `mode` | `manual` (`manual` / `rest` / `cruise`) |
| `autoContinueReports` | `true` |
| `continuePrompt` | the message above |
| `allowLabels` | `Go ahead`, `Let Clicky Drive`, `Let HeyClicky drive` (also matches `let <x> drive`) |
| `denyLabels` | `Not right now`, `Not now` |
| `reportLabels` | `Show Full Report`, `Full report` |
| `sendLabels` | `Up`, `Send`, `Arrow Up`, `Send message` |
| `clickyBundleIDs` | `com.humansongs.clicky`, `com.yourcompany.leanring-buddy` |
| `pollInterval` / `ocrInterval` | `1` / `2` seconds |
| `ocrFallback` | `true` |
| `reportFreshnessMinutes` | `20`: only reports with a recent timestamp count |
| `maxContinuesPerHour` / `minSecondsBetweenContinues` | `10` / `90` |
| `needsYouLabels` / `dismissLabels` | `Needs you` / `Close`, `xmark`, `Dismiss` |
| `maxNudgesPerTaskPerHour` | `6` (also shares the hourly budget above) |
| `ollamaEnabled` / `ollamaURL` | `true` / `http://127.0.0.1:11434` |
| `ollamaModel` | `""`: the first non-embedding model installed |
| `fallbackNudge` | sent when Ollama is unavailable or its draft is unsafe |
| `replyToStalls` | `true` |
| `stallMinutes` / `busyStallMinutes` / `stallCheckMinutes` | `5` / `20` / `2` |
| `awayAfterMinutes` | `4`: idle this long ⇒ treated as away, using the shorter thresholds below |
| `awayStallMinutes` / `awayBusyStallMinutes` | `2` / `8`: quiet thresholds while you're away |
| `awayIdleSeconds` | `30`: only hover the notch or type into HeyClicky after you've been idle this long |
| `openChatLabels` | `Open in a window` |
| `resumeAfterInterrupt` | `true`: apologise and resume when you interrupt a drive by mistake |
| `interruptLabels` | handoff phrases like `it's all yours`, `over to you` |
| `interruptedNudge` | the apology message sent after an accidental interrupt |
| `interruptedStatuses` / `retryLabels` | `interrupted`, `cut off`, `stopped` / `Retry`, `Try again` |
| `interruptedCardNudge` | the polite bump sent to a task whose card says *Interrupted* |
| `vscodeAutoApprove` | `false`: approve VS Code chat tool confirmations after the blocklist + Ollama review |
| `vscodeAllowLabels` | `Allow Once`, `Allow`, `Continue`, `Run` |
| `vscodeBundleIDs` / `vscodeCheckSeconds` | VS Code, Insiders, VSCodium / `1.5` |
| `autoSelectVSCodeModel` | `false`: enable cost-aware switching in the active chat |
| `economyModel` / `escalationModel` | `MAI-Code-1.1-Flash` / `GPT-6.1 Sol` |
| `modelEscalationFailures` / `modelEscalationMinutes` | `3` unresolved failures / `20` minutes of stalled progress |
| `modelReviewMinutes` / `modelSwitchCooldownMinutes` | `5` / `10` |
| `vscodeTaskBumps` | `false`: task-specific text follow-ups in Cruise mode |
| `vscodeBumpQuietMinutes` / `vscodeBumpCooldownMinutes` | `5` / `15` |
| `autoUpdateClicky` | `true` |
| `updateLabels` | `Update app`, `Install Update & Relaunch`, `Install & Relaunch`, `Install and Relaunch`, `Restart to update` |
| `updateCheckMinutes` | `30` |
| `relaunchNudge` | post-update fallback message |
| `autoAnswerSystemDialogs` | `true`: answer macOS permission alerts that name HeyClicky |
| `systemAllowLabels` / `systemDenyLabels` | `Allow`, `OK`, `Always Allow` / `Don't Allow`, `Deny` |
| `clickyAppNames` | `HeyClicky`, `Clicky`: a system alert is only touched if its text names one of these |
| `pillSide` | `right` |
| `showOnlyWithClicky` | `true` |

Other files:

- `~/Library/Application Support/CruiseControl/seen-reports.json`: reports that have already been handled
- `nudge-budget.json`: rate-limit history, which persists across restarts
- `pending-relaunch.json`: tasks to nudge once HeyClicky comes back from an update
- `model-routing.json`: per-conversation model state and recent progress, stored locally
- `chat-bumps.json`: quiet-chat follow-up history, stored locally
- `~/Library/Logs/CruiseControl.log`: activity log
- `~/Library/LaunchAgents/com.ilovespectra.cruisecontrol.plist`

## diagnostics

```sh
swift build && .build/debug/CruiseControl --scan
```

This prints what the scanner sees in HeyClicky right now (consent prompt, reports, composer, send button, Needs-you card, update button, installed version) without clicking anything.

```sh
.build/debug/CruiseControl --draft "Task name"             # draft 3 needs-you nudges with Ollama (nothing is sent)
.build/debug/CruiseControl --draft "Task name" --relaunch  # same, for the post-update nudge
.build/debug/CruiseControl --draft --stall                 # same, for a reply to a quiet conversation
.build/debug/CruiseControl --assess-model "Three attempts failed..." # local progress review; no UI actions
.build/debug/CruiseControl --draft-chat-bump "User: fix checkout. Agent: unfinished." # local draft only; nothing sent
.build/debug/CruiseControl --model-menu                    # opens the focused chat's picker and lists available models
.build/debug/CruiseControl --select-model MAI-Code-1.1-Flash # explicitly selects and verifies the model for the next turn
```

The explicit `--select-model` diagnostic may change the selection during a running turn, but never cancels it. The current response is not restarted; the selected model applies to a subsequent turn.

## safety notes

- In cruise mode, an AI agent drives your computer without asking you first. Only use it when you're OK with that.
- Esc still stops HeyClicky mid-drive. Switch back to manual from the notch at any time.
- Ollama drafts that fake your consent, mention credentials, or bypass prompts are never sent.
- macOS permission alerts are only auto-answered when their text names HeyClicky; any other app's prompt is left for you.
- Continue messages are rate-limited, only react to a single brand-new report, and are never sent in manual mode.

## landing page

`site/` holds a static page (`index.html`, `styles.css`, `icon.svg`). Open it directly or host it anywhere.

## fonts

Inter, Instrument Serif and Geist Mono are bundled under the SIL Open Font License (see `Resources/Fonts/OFL-*.txt`).
