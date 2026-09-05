# Worklight

A personal macOS menu bar dashboard for Git projects and Mac performance. Built with SwiftUI and AppKit, with no third-party runtime dependencies.

## Install on your Mac

Requires macOS 14 or newer and Xcode or Swift command line tools (Swift 5.9+).

```sh
git clone https://github.com/sarenataji/Worklight.git
cd Worklight
./scripts/install.sh
```

The installer builds a release app, signs it locally, copies it into `~/Applications/Worklight.app`, and opens it. Look for the waveform in your menu bar. Its height reflects CPU usage, and it gently moves at 20% CPU or higher. Reduce Motion keeps it static. Animation uses existing CPU samples without increasing system polling. The first launch also opens a dashboard window; closing that window leaves the menu bar app running. Quit Worklight using the menu in its header.

To update: quit Worklight, pull this repository, and run the installer again. To start at login, add Worklight in System Settings → General → Login Items.

This repository is private. Sign into GitHub before cloning. GitHub Actions also produces a zipped app artifact for its runner’s architecture. That artifact is ad-hoc signed, not notarized; building locally is the intended personal installation route. No paid Apple developer account is needed for this local build.

## Compact neon interface

Version 0.2 uses a 440 × 560 point panel, with black/charcoal surfaces and unfilled neon icons and status labels. Lime highlights the sun, active tab, CPU graph, and action buttons; violet marks incoming/outgoing commits, pink marks local file changes, mint marks verified up-to-date branches, and amber marks issues.

Five collapsed project rows fit without scrolling. Click a row to reveal commit counts, changed-file paths, staging details, editor shortcuts, and guarded pull actions. The small header refresh button fetches remote changes. Status explanations sit below the projects.

CPU and memory stay in a narrow bottom strip: click the CPU sparkline for recent activity, or open **Your Mac** to see live CPU and memory use for detected apps and processes. Memory pressure also adds a compact callout below the projects. The app never labels resource usage as a proven cause of a slowdown. Quit confirmations, process details, search, sorting, and Activity Monitor remain available.

## Projects

Starts with `~/Desktop/apps`; change it using the header’s menu. Discovery searches three levels below the selected folder, skips dependency/build directories and symlinks, and stops at each repository. Git worktrees are supported. Ordinary folders without Git are not listed.

- **Incoming:** commits on the tracked remote branch that your local branch lacks.
- **Outgoing:** local commits not on the tracked branch.
- **Pushed:** the latest successful push recorded in this clone’s Git reflog for the tracked remote branch, with its actual push time and a linked commit on GitHub. A commit count appears when the previous remote tip establishes a fast-forward range. Later fetches leave this push visible; expired or unavailable push records fall back to **Latest remote commit**, without claiming when it was pushed. This does not track whether collaborators have pulled. Activity updates during normal checks or manual refresh.
- **Edited files:** tracked changes plus individual untracked files. Expand the file list to see paths, modification types, and staging state.
- **Updates available:** incoming work exists. Pull is enabled only when the branch is clean and has no outgoing commits.
- **Diverged:** both sides have new commits; review in your editor.
- **Check needed:** remote check failed, or Git could not read the repository. Cached counts are not verified live state.
- **No tracking branch:** remote comparisons are unavailable until an upstream is configured.

Every five minutes, Worklight fetches the tracked branch’s remote using your existing Git credentials. It never stages, commits, pushes, resets, stashes, or automatically pulls. A pull requires an explicit click and confirmation, then rechecks the repository and uses fast-forward-only Git behavior. Avoid editing the same repository during a pull; Git remains the final arbiter of concurrent changes.

Open a project in Finder or VS Code, or view its tracked remote (origin when no tracking branch is configured) on GitHub. The T3 Code shortcut launches the installed nightly app and copies the project path for selecting/adding it there; automatic project selection via deep link is not implemented.

## Performance

- Overall CPU uses differences in kernel CPU counters, normalized across all cores.
- Process CPU uses macOS `ps` estimates, with 100% representing one core. It is not the same time window or scale as the overall CPU chart.
- App totals group processes using running application identities, parent relationships, and bundle paths. Attribution is best effort; some detached helpers remain separate.
- Memory pressure comes from the kernel. Swap displays allocated swap usage, not a claim that swapping is currently causing a slowdown.
- Sampling runs about every three seconds while the dashboard is visible and every fifteen seconds otherwise. The chart contains the latest 40 samples, not a fixed duration.
- The list shows detected apps and processes with their live CPU and resident-memory estimates. It adds attention notes at 80%+ process CPU across samples at least ten seconds apart; 40%+ process CPU while overall CPU is at least 75%; or at least 512 MB resident memory while kernel memory pressure is elevated. These thresholds flag investigation candidates, not proven causes.
- Sort by CPU or memory, search names or PIDs, and expand an app to inspect executable paths and its busiest processes. Memory is summed resident memory and may count shared pages more than once.
- Apps stay visible in Your Mac. Quiet background entries with purple terminal icons sit in a collapsed **Background processes** section; entries meeting the CPU or memory attention criteria stay visible. Search includes all entries, even when the section is collapsed, and matches names, process paths, and PIDs. Clearing search restores the section’s previous state.
- Rows showing **0.0% CPU** are hidden from both the main list and background section, including when sorting by memory. Search reveals them; clear search to hide them again.
- Normal quit and confirmed force quit are available for your non-system desktop apps. Force quit can lose unsaved work. Background/system processes are inspectable here and manageable in Activity Monitor; Worklight does not terminate them.

High usage is evidence to investigate, not proof of the cause of a slowdown. Disk, thermal, and network diagnostics are not part of this first version. Process command arguments and working directories are not collected.

## Privacy

No analytics, uploads, or cloud backend. Process data stays in memory on your Mac. Git fetch contacts the remotes already configured in your repositories. The chosen workspace path, appearance, and per-project active-time totals are saved in app preferences. The app is not sandboxed because it needs to read selected Git repositories and use your Git credentials.

## Development and validation

```sh
swift build
swift run Worklight --self-test
swift run Worklight --diagnose
./scripts/build.sh
```

Self-tests create disposable local repositories and verify remote discovery, fetch without file changes, clean fast-forward pulls, dirty-file protection, divergence refusal, fetch failures, and live process sampling. They do not pull or edit your projects.

`--diagnose` prints local repository state without fetching, plus CPU/memory diagnostics. `--render-preview` renders both native dashboard tabs and an expanded changed-file view into `dist/` for layout inspection; it uses the dashboard’s normal monitoring behavior. Previews and build output are excluded from Git.

Source layout: `System.swift` handles Git and system sampling; `Model.swift` handles updates and app grouping; `Views.swift` contains the dashboard; `App.swift` defines the menu bar and window scenes.

## Project work sessions

Expand a project and choose **Start project session**, or choose a project from the header's **Work time** popup. The session follows you across editors, terminals, browsers, and AI apps. Use **Pause**, **Resume**, **Switch project…**, or **Stop** explicitly; only one project is timed at once. Automatic project suggestions are not implemented.

After five minutes without mouse or keyboard input, the entire idle interval is removed from the running total and held for review. On return, choose **Count** to include thinking, reading, or waiting, or **Exclude** to discard it. Tracking stays paused until that choice. Resolve idle time before switching or stopping. Sleep, screen lock/inactive sessions, and unexpected sampling gaps pause tracking; resuming after wake is explicit. No window contents, messages, or keystrokes are recorded, and no Accessibility permission is needed.

**History…** lists uninterrupted work intervals. Pause the current interval before editing its project, start, or end. Edits cannot overlap another interval or extend into the future. Earlier totals are preserved separately because they have no detailed session history.

Sessions are sampled every five seconds and saved locally every 30 seconds and on control changes, sleep, and normal quit. Abrupt termination can lose the most recent unsaved time. Restart restores the selected project paused, without counting time while Worklight was closed. Unattended AI runtime is not measured separately.

The new session store uses a separate preferences key and leaves the original totals untouched. Reverting the code restores the original timer and its pre-update totals; new session data remains stored for a later upgrade but is not visible in the old timer.

## App updates

The header Refresh button syncs Git projects and checks published stable GitHub releases independently. Automatic five-minute project checks do not poll for app updates. When a newer compatible release exists, Projects shows **Install & restart**; refresh alone never installs or quits. The private-repository updater uses an existing GitHub CLI installation at `/opt/homebrew/bin/gh` or `/usr/local/bin/gh`, signed in with repository access (`gh auth login`). Worklight does not store GitHub tokens. If GitHub CLI is absent, use the manual installer.

Update packages must be named `Worklight-macOS-universal.zip` and have GitHub's SHA-256 asset digest. Worklight checks the digest, archive paths, bundle identifier/version, both Mac architectures and ad-hoc signature integrity before replacement. These are private, locally signed builds, not Developer ID notarized releases; trust comes from access-controlled GitHub release assets rather than a pinned publisher certificate. The current app stages a sibling bundle, launches its own updater helper, saves the timer, then quits normally. Replacement failures attempt to restore the previous app. Settings and saved work time are retained; active timer sessions must be selected again. A writable installed `.app` location is required.

Release maintainers: update `VERSION` with a stable three-part version, commit it, and push a matching `vX.Y.Z` tag when ready to publish. The tag workflow builds and tests a universal app, then publishes the ZIP to GitHub Releases. Main-branch pushes only build CI artifacts; they do not publish updates. No release has to be created merely to test or develop the updater locally. The already installed app needs one manual installation of an updater-enabled version before it can use this feature.
