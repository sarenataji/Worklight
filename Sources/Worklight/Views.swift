import SwiftUI
import AppKit

private let canvas = Color(red: 0.055, green: 0.067, blue: 0.09)
private let surface = Color(red: 0.09, green: 0.105, blue: 0.135)
private let mint = Color(red: 0.43, green: 0.88, blue: 0.71)
private let blue = Color(red: 0.49, green: 0.70, blue: 1)
private let amber = Color(red: 1, green: 0.74, blue: 0.38)
private let muted = Color(red: 0.62, green: 0.66, blue: 0.73)

struct DashboardView: View {
    @ObservedObject var model: DashboardModel
    @State private var tab: Int
    init(model: DashboardModel, initialTab: Int = 0) { self.model = model; _tab = State(initialValue: initialTab); _sortMemory = State(initialValue: model.performance.memoryLevel >= 2) }
    @State private var search = ""
    @State private var sortMemory = false
    @State private var pendingQuit: AppUsage?
    @State private var forceQuit = false
    @State private var pendingPull: Repository?
    var body: some View {
        VStack(spacing: 0) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    overview
                    tabs
                    if tab == 0 { projects } else { performance }
                }.padding(22)
            }
            footer
        }
        .frame(width: 610, height: 760)
        .background(canvas)
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .font(.system(size: 13))
        .onAppear { model.visible = true; model.start() }
        .onDisappear { model.visible = false }
        .onChange(of: model.performance.memoryLevel) { old, new in if old == 0 { sortMemory = new >= 2 } }
        .alert(forceQuit ? "Force quit \(pendingQuit?.name ?? "app")?" : "Quit \(pendingQuit?.name ?? "app")?", isPresented: Binding(get: { pendingQuit != nil }, set: { if !$0 { pendingQuit = nil } })) {
            Button("Cancel", role: .cancel) { pendingQuit = nil }
            Button(forceQuit ? "Force quit" : "Quit", role: .destructive) {
                if let app = pendingQuit { model.quit(app, force: forceQuit) }; pendingQuit = nil
            }
        } message: { Text(forceQuit ? "Unsaved work may be lost. This closes the entire app and its helpers." : "This requests a normal quit. The app may ask you to save work before closing.") }
        .confirmationDialog("Pull updates into \(pendingPull?.name ?? "project")?", isPresented: Binding(get: { pendingPull != nil }, set: { if !$0 { pendingPull = nil } }), titleVisibility: .visible) {
            Button("Pull updates") { if let repo = pendingPull { model.pull(repo) }; pendingPull = nil }
            Button("Cancel", role: .cancel) { pendingPull = nil }
        } message: { Text("This changes the project’s files. Worklight checks again and only allows a fast-forward with no local edits or outgoing commits.") }
        .sheet(isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Label("Worklight", systemImage: "info.circle").font(.title3.bold())
                ScrollView { Text(model.notice ?? "").textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 260)
                Button("Done") { model.notice = nil }.buttonStyle(.borderedProminent).tint(mint).foregroundStyle(.black)
            }.padding(24).frame(width: 490).background(canvas)
        }
    }
    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "sun.max.fill").font(.system(size: 20)).foregroundStyle(mint)
                .frame(width: 38, height: 38).background(mint.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 2) {
                Text("Worklight").font(.system(size: 19, weight: .semibold, design: .rounded))
                Text("YOUR WORK. A LITTLE CLEARER.").font(.system(size: 9, weight: .medium)).tracking(1.6).foregroundStyle(muted)
            }
            Spacer()
            Circle().fill(mint).frame(width: 6, height: 6)
            Text("Live on your Mac").font(.system(size: 11)).foregroundStyle(muted)
            Menu {
                Button("Choose project folder…") { model.chooseFolder() }.disabled(model.refreshing || model.pulling != nil)
                Button("Open Activity Monitor") { model.activityMonitor() }
                Divider()
                Button("Quit Worklight") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis").frame(width: 26, height: 26) }.menuStyle(.borderlessButton).fixedSize()
        }.padding(.horizontal, 22).padding(.vertical, 17)
        .background(surface.opacity(0.55))
        .overlay(alignment: .bottom) { Rectangle().fill(.white.opacity(0.06)).frame(height: 1) }
    }
    private var overview: some View {
        VStack(alignment: .leading, spacing: 16) {
            if tab == 0 { HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(greeting).font(.system(size: 25, weight: .semibold, design: .rounded))
                    Text(subtitle).font(.system(size: 12)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: model.needsAttention > 0 ? "exclamationmark.circle" : "sparkle").font(.system(size: 24, weight: .light)).foregroundStyle(mint)
            } }
            HStack(spacing: 10) {
                metric("PROJECT UPDATES", value: model.refreshing && model.repositories.isEmpty ? "…" : "\(model.incoming)", detail: model.incoming == 1 ? "project has incoming work" : "projects have incoming work", color: blue, symbol: "arrow.down.circle")
                metric("CPU IN USE", value: "\(Int(model.performance.cpu))%", detail: model.performance.cpu >= 80 ? "Heavy activity right now" : "Across all CPU cores", color: model.performance.cpu >= 80 ? amber : mint, symbol: "cpu")
                metric("MEMORY", value: model.memoryTitle, detail: String(format: "%.1f GB swap in use", model.performance.swapGB), color: model.performance.memoryLevel == 1 ? mint : amber, symbol: "memorychip")
            }
        }
    }
    private var greeting: String {
        if model.performance.memoryLevel == 4 { return "Your Mac needs some room." }
        if model.needsAttention > 0 { return "A few things to look at." }
        if model.incoming > 0 { return "There’s new work to catch up on." }
        return "Your workspace, at a glance."
    }
    private var subtitle: String {
        if model.refreshing { return "Checking your projects for the latest changes…" }
        return "See what changed. Understand what’s running. Stay in control."
    }
    private func metric(_ title: String, value: String, detail: String, color: Color, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 4) { Image(systemName: symbol); Text(title).tracking(0.7) }.font(.system(size: 9, weight: .semibold)).foregroundStyle(muted)
            Text(value).font(.system(size: title == "MEMORY" ? 16 : 28, weight: .semibold, design: .rounded)).foregroundStyle(color).frame(height: 32, alignment: .leading).minimumScaleFactor(0.8).lineLimit(1)
            Text(detail).font(.system(size: 10)).foregroundStyle(muted).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(13).background(surface, in: RoundedRectangle(cornerRadius: 14))
    }
    private var tabs: some View {
        HStack(spacing: 4) {
            tabButton("Projects", icon: "square.stack.3d.up", index: 0)
            tabButton("What’s running", icon: "waveform.path.ecg", index: 1)
        }.padding(4).background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 11))
    }
    private func tabButton(_ title: String, icon: String, index: Int) -> some View {
        Button { tab = index } label: {
            HStack(spacing: 7) { Image(systemName: icon); Text(title).fontWeight(.medium) }
                .frame(maxWidth: .infinity).padding(.vertical, 10)
                .background(tab == index ? Color.white.opacity(0.09) : .clear, in: RoundedRectangle(cornerRadius: 8))
                .foregroundStyle(tab == index ? .white : muted)
        }.buttonStyle(.plain)
    }
    private var projects: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Your projects").font(.system(size: 15, weight: .semibold))
                    Text(model.root.replacingOccurrences(of: NSHomeDirectory(), with: "~")).font(.system(size: 11)).foregroundStyle(muted).lineLimit(1).help(model.root)
                }
                Spacer()
                Button { model.refresh() } label: {
                    HStack(spacing: 5) { if model.refreshing { ProgressView().controlSize(.mini) } else { Image(systemName: "arrow.clockwise") }; Text(model.refreshing ? "Checking" : "Check now") }
                }.buttonStyle(.bordered).disabled(model.refreshing || model.pulling != nil)
            }
            HStack(spacing: 7) {
                Image(systemName: "info.circle").foregroundStyle(blue)
                Text("Checks fetch updates. Your files change only when you choose Pull.").font(.system(size: 11)).foregroundStyle(muted)
            }.padding(.vertical, 2)
            DisclosureGroup("What do these statuses mean?") {
                VStack(alignment: .leading, spacing: 8) {
                    legend("↓ 3 incoming", "Your tracked remote branch has 3 commits you haven’t pulled.", blue)
                    legend("↑ 2 outgoing", "You have 2 local commits you haven’t pushed.", amber)
                    legend("5 changed files", "You have uncommitted work.", amber)
                    legend("Diverged", "Both local and remote branches have new commits.", amber)
                    legend("Up to date", "Your branch matches its tracked remote branch.", mint)
                }.padding(.top, 10)
            }.font(.system(size: 11)).tint(muted).padding(12).background(surface, in: RoundedRectangle(cornerRadius: 10))
            if model.repositories.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.questionmark").font(.largeTitle).foregroundStyle(muted)
                    Text(model.refreshing ? "Finding and checking your projects…" : "No Git projects found here")
                    if !model.refreshing { Button("Choose a folder") { model.chooseFolder() } }
                    Text("Looks up to three folders deep, skipping build dependencies.").font(.caption).foregroundStyle(muted)
                }.frame(maxWidth: .infinity).padding(24).background(surface, in: RoundedRectangle(cornerRadius: 14))
            }
            ForEach(model.repositories) { repo in repoCard(repo) }
        }
    }
    private func repoCard(_ repo: Repository) -> some View {
        let color = repo.error != nil || repo.conflicts > 0 || (repo.ahead > 0 && repo.behind > 0) ? amber : repo.behind > 0 ? blue : repo.changed > 0 || repo.ahead > 0 ? amber : mint
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "folder").font(.system(size: 17)).foregroundStyle(color).frame(width: 34, height: 34).background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(repo.name).font(.system(size: 14, weight: .semibold))
                    Label(repo.branch.isEmpty ? "No branch" : repo.branch, systemImage: "arrow.triangle.branch").font(.system(size: 10)).foregroundStyle(muted)
                }
                Spacer()
                Label(repo.headline, systemImage: repo.error != nil ? "exclamationmark.circle" : repo.behind > 0 ? "arrow.down.circle" : repo.changed > 0 ? "pencil.circle" : "checkmark.circle")
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(color).padding(.horizontal, 8).padding(.vertical, 5).background(color.opacity(0.09), in: Capsule())
            }
            HStack(spacing: 16) {
                countLabel(repo.behind, "incoming", "arrow.down", blue)
                countLabel(repo.ahead, "outgoing", "arrow.up", amber)
                countLabel(repo.changed, "changed files", "pencil", amber)
            }
            if !repo.files.isEmpty {
                DisclosureGroup("See \(repo.files.count) changed files") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(repo.files.prefix(100)) { file in
                            HStack(alignment: .top, spacing: 8) {
                                Text(file.meaning).font(.system(size: 9, weight: .medium)).foregroundStyle(amber).frame(width: 55, alignment: .leading)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(file.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                                    Text(file.location).font(.system(size: 9)).foregroundStyle(muted)
                                }
                                Spacer(minLength: 0)
                                if !file.code.contains("D") {
                                    Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path).appendingPathComponent(file.path)]) } label: { Image(systemName: "arrow.up.forward.square") }.buttonStyle(.plain).help("Show file in Finder")
                                }
                            }
                        }
                        if repo.files.count > 100 { Text("Showing the first 100 files. Open your editor to see all.").font(.caption).foregroundStyle(muted) }
                    }.padding(.top, 8)
                }.font(.system(size: 11)).tint(muted)
            }
            if let error = repo.error {
                Text("Couldn’t verify remote updates. \(error)").font(.system(size: 11)).foregroundStyle(amber).lineLimit(3).help(error).textSelection(.enabled)
            } else if repo.upstream.isEmpty {
                Text("This branch isn’t tracking a remote branch, so incoming updates are unknown.").font(.system(size: 11)).foregroundStyle(muted)
            } else if repo.behind > 0 && !repo.canPull {
                Text(repo.ahead > 0 ? "Local and remote work differ. Review both branches in your editor." : "Commit or stash your local edits in your editor before pulling.").font(.system(size: 11)).foregroundStyle(amber)
            }
            HStack(spacing: 8) {
                Menu {
                    Button("Open in T3 Code · copy project path") { model.openT3(repo) }
                    Button("Open in VS Code") { model.openVSCode(repo) }
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: repo.path)) }
                    if let url = repo.remoteURL { Button("View on GitHub") { NSWorkspace.shared.open(url) } }
                } label: { Text("Open project") }.menuStyle(.borderlessButton).fixedSize()
                Spacer()
                if let checked = repo.checked { Text("Checked \(checked, style: .relative) ago").font(.system(size: 9)).foregroundStyle(muted) }
                else { Text("Remote not verified").font(.system(size: 9)).foregroundStyle(muted) }
                if repo.behind > 0 {
                    Button(model.pulling == repo.path ? "Pulling…" : "Pull \(repo.behind) update\(repo.behind == 1 ? "" : "s")") { pendingPull = repo }
                        .buttonStyle(.borderedProminent).tint(blue).foregroundStyle(.black)
                        .disabled(!repo.canPull || model.refreshing || model.pulling != nil)
                }
            }
        }.padding(15).background(surface, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(.white.opacity(0.045)))
    }
    private func legend(_ title: String, _ meaning: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(title).foregroundStyle(color).frame(width: 110, alignment: .leading)
            Text(meaning).foregroundStyle(muted).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 10))
    }
    private func countLabel(_ count: Int, _ label: String, _ icon: String, _ color: Color) -> some View {
        HStack(spacing: 4) { Image(systemName: icon).foregroundStyle(count > 0 ? color : muted); Text("\(count)").fontWeight(.semibold); Text(label).foregroundStyle(muted) }.font(.system(size: 11))
    }
    private var performance: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("CPU activity").font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Text("\(Int(model.performance.cpu))% of your Mac’s capacity").font(.system(size: 11)).foregroundStyle(mint)
                }
                Sparkline(values: model.history).frame(height: 36).foregroundStyle(mint)
                HStack { Text("Recent samples"); Spacer(); Text("Now") }.font(.system(size: 9)).foregroundStyle(muted)
            }.padding(15).background(surface, in: RoundedRectangle(cornerRadius: 14))
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "memorychip").foregroundStyle(model.performance.memoryLevel == 1 ? mint : amber)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Memory: \(model.memoryTitle.lowercased())").font(.system(size: 12, weight: .semibold))
                    Text("Swap is disk space used for memory. Swap alone doesn’t mean your Mac is currently struggling.").font(.system(size: 11)).foregroundStyle(muted)
                }
            }
            HStack {
                Text("Likely slowdown contributors").font(.system(size: 14, weight: .semibold))
                Spacer()
                Picker("Sort", selection: $sortMemory) { Text("CPU").tag(false); Text("Memory").tag(true) }.pickerStyle(.segmented).frame(width: 125).labelsHidden()
            }
            HStack(spacing: 7) { Image(systemName: "magnifyingglass").foregroundStyle(muted); TextField("Find an app or process", text: $search).textFieldStyle(.plain) }
                .padding(10).background(surface, in: RoundedRectangle(cornerRadius: 9))
            Text("Only apps with resource evidence are shown. These are likely contributors, not a confirmed diagnosis. CPU: 100% = one core.").font(.system(size: 10)).foregroundStyle(muted)
            if let error = model.performance.error { Text(error).foregroundStyle(amber) }
            LazyVStack(spacing: 8) {
                ForEach(filteredApps.prefix(40)) { usage in processCard(usage) }
            }
            if filteredApps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Label(search.isEmpty ? "No clear contributor identified" : "No matching contributors", systemImage: "checkmark.circle").foregroundStyle(mint)
                    Text("Watching for sustained CPU usage and large memory users when pressure is elevated. Disk or thermal issues may need Activity Monitor.").font(.system(size: 11)).foregroundStyle(muted)
                }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(surface, in: RoundedRectangle(cornerRadius: 12))
            }
            Button("Open Activity Monitor for all processes") { model.activityMonitor() }.buttonStyle(.bordered)
            Text("Quit controls are available for your non-system desktop apps. Inspect other processes in Activity Monitor.").font(.system(size: 10)).foregroundStyle(muted)
        }
    }
    private var filteredApps: [AppUsage] {
        model.contributors.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.processes.contains { $0.command.localizedCaseInsensitiveContains(search) || String($0.pid).contains(search) } }
            .sorted { sortMemory ? $0.memoryMB > $1.memoryMB : $0.cpu > $1.cpu }
    }
    private func processCard(_ usage: AppUsage) -> some View {
        DisclosureGroup {
            VStack(alignment: .leading, spacing: 9) {
                ForEach(model.reasons(for: usage), id: \.self) { reason in
                    Label(reason, systemImage: "exclamationmark.circle").font(.system(size: 11)).foregroundStyle(amber)
                }
                ForEach(usage.processes.sorted { $0.cpu > $1.cpu }.prefix(30)) { process in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(process.name).font(.system(size: 11, weight: .medium))
                            Text("PID \(process.pid) · \(process.command)").font(.system(size: 9)).foregroundStyle(muted).lineLimit(2).textSelection(.enabled).help(process.command)
                        }
                        Spacer()
                        Text(String(format: "%.1f%%", process.cpu)).font(.system(size: 10, design: .monospaced)).foregroundStyle(muted)
                    }
                }
                if usage.processes.count > 30 { Text("Showing 30 of \(usage.processes.count) processes. See Activity Monitor for all.").font(.caption).foregroundStyle(muted) }
                if usage.canQuit {
                    HStack {
                        Button("Quit app") { forceQuit = false; pendingQuit = usage }.buttonStyle(.bordered)
                        Spacer()
                        Button("Force quit…") { forceQuit = true; pendingQuit = usage }.buttonStyle(.plain).foregroundStyle(amber).font(.system(size: 11))
                    }.padding(.top, 4)
                }
            }.padding(.top, 10)
        } label: {
            HStack(spacing: 10) {
                if let icon = usage.icon { Image(nsImage: icon).resizable().frame(width: 28, height: 28) }
                else { Image(systemName: "terminal").font(.system(size: 19)).foregroundStyle(muted).frame(width: 28, height: 28) }
                VStack(alignment: .leading, spacing: 4) {
                    Text(usage.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text(model.reasons(for: usage).first ?? "Expand to inspect processes").font(.system(size: 9)).foregroundStyle(muted)
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 4) {
                    Text(sortMemory ? String(format: "%.0f MB", usage.memoryMB) : String(format: "%.1f%%", usage.cpu)).font(.system(size: 14, weight: .semibold, design: .rounded)).foregroundStyle(usage.cpu > 80 ? amber : mint)
                    Text(sortMemory ? String(format: "%.1f%% CPU", usage.cpu) : String(format: "%.0f MB", usage.memoryMB)).font(.system(size: 9)).foregroundStyle(muted)
                    GeometryReader { geo in RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.07)).overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(usage.cpu > 80 ? amber : mint).frame(width: geo.size.width * min(1, max(0.015, sortMemory ? usage.memoryMB / 8192 : usage.cpu / 100))) } }.frame(width: 60, height: 3)
                }
            }
        }.tint(muted).padding(12).background(surface, in: RoundedRectangle(cornerRadius: 11))
    }
    private var footer: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.2.circlepath")
            Text("Projects every 5 min · CPU every \(model.visible ? "3" : "15") sec")
            Spacer()
            Text("PRIVATE BY DEFAULT").font(.system(size: 8, weight: .medium)).tracking(1)
        }.font(.system(size: 10)).foregroundStyle(muted).padding(.horizontal, 22).padding(.vertical, 12)
        .background(surface.opacity(0.55))
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            ZStack {
                ForEach(0..<3) { i in Path { p in let y = CGFloat(i) * geo.size.height / 2; p.move(to: CGPoint(x: 0, y: y)); p.addLine(to: CGPoint(x: geo.size.width, y: y)) }.stroke(.white.opacity(0.05), style: StrokeStyle(lineWidth: 1, dash: [3, 4])) }
                Path { p in
                    guard values.count > 1 else { return }
                    for (i, value) in values.enumerated() {
                        let point = CGPoint(x: CGFloat(i) / CGFloat(values.count - 1) * geo.size.width, y: geo.size.height * (1 - min(100, max(0, value)) / 100))
                        if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                    }
                }.stroke(style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }.accessibilityLabel("Recent CPU usage: \(Int(values.last ?? 0)) percent")
    }
}
