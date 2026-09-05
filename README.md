# Worklight

A personal macOS menu bar dashboard for Git projects and Mac performance. Built with SwiftUI and AppKit, with no third-party runtime dependencies.

## Install on your Mac

Requires macOS 14 or newer and Xcode or Swift command line tools (Swift 5.9+).

```sh
git clone https://github.com/sarenataji/Worklight.git
cd Worklight
./scripts/install.sh
```

The installer builds a release app, signs it locally, copies it into `~/Applications/Worklight.app`, and opens it. Look for the sun icon in your menu bar. The first launch also opens a dashboard window; closing that window leaves the menu bar app running. Quit Worklight using the menu in its header.

To update: quit Worklight, pull this repository, and run the installer again. To start at login, add Worklight in System Settings → General → Login Items.

This repository is private. Sign into GitHub before cloning. GitHub Actions also produces a zipped app artifact for its runner’s architecture. That artifact is ad-hoc signed, not notarized; building locally is the intended personal installation route. No paid Apple developer account is needed for this local build.

## Projects

Starts with `~/Desktop/apps`; change it using the header’s menu. Discovery searches three levels below the selected folder, skips dependency/build directories and symlinks, and stops at each repository. Git worktrees are supported. Ordinary folders without Git are not listed.

- **Incoming:** commits on the tracked remote branch that your local branch lacks.
- **Outgoing:** local commits not on the tracked branch.
- **Edited files:** tracked changes plus individual untracked files. Expand the file list to see paths, modification types, and staging state.
- **Updates available:** incoming work exists. Pull is enabled only when the branch is clean and has no outgoing commits.
- **Diverged:** both sides have new commits; review in your editor.
- **Check needed:** remote check failed, or Git could not read the repository. Cached counts are not verified live state.
- **No tracking branch:** remote comparisons are unavailable until an upstream is configured.

Every five minutes, Worklight fetches the tracked branch’s remote using your existing Git credentials. It never stages, commits, pushes, resets, stashes, or automatically pulls. A pull requires an explicit click and confirmation, then rechecks the repository and uses fast-forward-only Git behavior. Avoid editing the same repository during a pull; Git remains the final arbiter of concurrent changes.

Open a project in Finder or VS Code, or view its origin on GitHub. The T3 Code shortcut launches the installed nightly app and copies the project path for selecting/adding it there; automatic project selection via deep link is not implemented.

## Performance

- Overall CPU uses differences in kernel CPU counters, normalized across all cores.
- Process CPU uses macOS `ps` estimates, with 100% representing one core. It is not the same time window or scale as the overall CPU chart.
- App totals group processes using running application identities, parent relationships, and bundle paths. Attribution is best effort; some detached helpers remain separate.
- Memory pressure comes from the kernel. Swap displays allocated swap usage, not a claim that swapping is currently causing a slowdown.
- Sampling runs about every three seconds while the dashboard is visible and every fifteen seconds otherwise. The chart contains the latest 40 samples, not a fixed duration.
- The list focuses on likely contributors: 80%+ process CPU across samples at least ten seconds apart; 40%+ process CPU while overall CPU is at least 75%; or at least 512 MB resident memory while kernel memory pressure is elevated. These thresholds select investigation candidates, not proven causes. Healthy/low-resource entries are hidden.
- Sort by CPU or memory, search names or PIDs, and expand an app to inspect executable paths and its busiest processes. Memory is summed resident memory and may count shared pages more than once.
- Normal quit and confirmed force quit are available for your non-system desktop apps. Force quit can lose unsaved work. Background/system processes are inspectable here and manageable in Activity Monitor; Worklight does not terminate them.

High usage is evidence to investigate, not proof of the cause of a slowdown. Disk, thermal, and network diagnostics are not part of this first version. Process command arguments and working directories are not collected.

## Privacy

No analytics, uploads, or cloud backend. Process data stays in memory on your Mac. Git fetch contacts the remotes already configured in your repositories. Only the chosen workspace path is saved in app preferences. The app is not sandboxed because it needs to read selected Git repositories and use your Git credentials.

## Development and validation

```sh
swift build
swift run Worklight --self-test
swift run Worklight --diagnose
./scripts/build.sh
```

Self-tests create disposable local repositories and verify remote discovery, fetch without file changes, clean fast-forward pulls, dirty-file protection, divergence refusal, fetch failures, and live process sampling. They do not pull or edit your projects.

`--diagnose` prints local repository state without fetching, plus CPU/memory diagnostics. `--render-preview` renders both native dashboard tabs into `dist/` for layout inspection; it uses the dashboard’s normal monitoring behavior. Previews and build output are excluded from Git.

Source layout: `System.swift` handles Git and system sampling; `Model.swift` handles updates and app grouping; `Views.swift` contains the dashboard; `App.swift` defines the menu bar and window scenes.
