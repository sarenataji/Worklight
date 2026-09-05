import SwiftUI
import AppKit

// Neutral surfaces; saturated accents carry meaning without tinted card fills.
private enum Palette {
    static let canvas = Color(hex: 0x090909)
    static let surface = Color(hex: 0x141414)
    static let line = Color(hex: 0x292929)
    static let text = Color(hex: 0xFAFAFA)
    static let muted = Color(hex: 0xA3A3A3)
    static let lime = Color(hex: 0xDFFF00)
    static let violet = Color(hex: 0xAD5CFF)
    static let pink = Color(hex: 0xFF29A8)
    static let mint = Color(hex: 0x00FF9D)
    static let amber = Color(hex: 0xFFCA00)
}
private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 255) / 255, green: Double((hex >> 8) & 255) / 255, blue: Double(hex & 255) / 255)
    }
}

struct DashboardView: View {
    static let width: CGFloat = 440
    static let height: CGFloat = 560
    @ObservedObject var model: DashboardModel
    @State private var tab: Int
    @State private var expandedRepository: String?
    @State private var expandedApp: String?
    @State private var showLegend = false
    @State private var showCPU = false
    @State private var search = ""
    @State private var sortMemory: Bool
    @State private var pendingQuit: AppUsage?
    @State private var forceQuit = false
    @State private var pendingPull: Repository?
    @Environment(\.openWindow) private var openWindow

    init(model: DashboardModel, initialTab: Int = 0, expandedRepository: String? = nil) {
        self.model = model
        _tab = State(initialValue: initialTab)
        _sortMemory = State(initialValue: model.performance.memoryLevel >= 2)
        _expandedRepository = State(initialValue: expandedRepository)
    }
    var body: some View {
        VStack(spacing: 0) {
            header
            tabs
            ScrollView {
                Group { if tab == 0 { projects } else { performance } }
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            footer
        }
        .frame(width: Self.width, height: Self.height)
        .background(Palette.canvas).foregroundStyle(Palette.text)
        .preferredColorScheme(.dark).font(.system(size: 11))
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
            VStack(alignment: .leading, spacing: 16) {
                Label("Worklight", systemImage: "info.circle").font(.headline)
                ScrollView { Text(model.notice ?? "").font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }.frame(maxHeight: 250)
                Button("Done") { model.notice = nil }.buttonStyle(NeonButtonStyle())
            }.padding(20).frame(width: 390).background(Palette.canvas)
        }
    }
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sun.max").font(.system(size: 19, weight: .medium)).foregroundStyle(Palette.lime)
                .frame(width: 28, height: 28).overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Palette.line))
            Text("Worklight").font(.system(size: 14, weight: .semibold))
            Spacer()
            Circle().fill(model.history.isEmpty ? Palette.muted : Palette.lime).frame(width: 5, height: 5)
                .accessibilityLabel(model.history.isEmpty ? "Starting monitoring" : "Monitoring your Mac")
            Button { model.refresh() } label: {
                if model.refreshing { ProgressView().controlSize(.mini).frame(width: 24, height: 24) }
                else { Image(systemName: "arrow.clockwise").frame(width: 24, height: 24) }
            }.buttonStyle(.plain).foregroundStyle(Palette.muted).disabled(model.refreshing || model.pulling != nil)
                .help("Fetch remote updates without changing your files").accessibilityLabel("Check projects now")
            Menu {
                Button("Choose project folder…") { model.chooseFolder() }.disabled(model.refreshing || model.pulling != nil)
                Button("Open dashboard window") { openWindow(id: "dashboard") }
                Button("Open Activity Monitor") { model.activityMonitor() }
                Divider()
                Text("Projects checked every 5 minutes")
                Text("CPU sampled every 3 seconds while open")
                Divider()
                Button("Quit Worklight") { NSApplication.shared.terminate(nil) }
            } label: { Image(systemName: "ellipsis").frame(width: 20, height: 24) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().foregroundStyle(Palette.muted)
                .accessibilityLabel("Worklight settings")
        }.padding(.horizontal, 16).frame(height: 54)
    }
    private var tabs: some View {
        HStack(spacing: 20) {
            tabButton("Projects", index: 0)
            tabButton("Your Mac", index: 1)
            Spacer()
        }.padding(.horizontal, 16).frame(height: 38)
            .overlay(alignment: .bottom) { rule }
    }
    private func tabButton(_ title: String, index: Int) -> some View {
        Button { tab = index } label: {
            HStack(spacing: 6) {
                Text(title).fontWeight(.medium)
                if index == 0 {
                    Text("\(model.repositories.count)").font(.system(size: 9, weight: .medium))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(Palette.surface, in: RoundedRectangle(cornerRadius: 4))
                } else if model.performance.memoryLevel >= 2 || !model.contributors.isEmpty {
                    Circle().fill(Palette.amber).frame(width: 5, height: 5)
                }
            }.foregroundStyle(tab == index ? Palette.lime : Palette.muted).frame(height: 38)
                .overlay(alignment: .bottom) { if tab == index { Rectangle().fill(Palette.lime).frame(height: 2) } }
        }.buttonStyle(.plain).accessibilityAddTraits(tab == index ? .isSelected : [])
    }
    private var projects: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(model.root.replacingOccurrences(of: NSHomeDirectory() + "/", with: "")).fontWeight(.medium).lineLimit(1).truncationMode(.middle).help(model.root)
                Spacer(minLength: 8)
                Text(model.refreshing ? "Checking…" : "\(model.incoming) with incoming work").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }.padding(.horizontal, 2)
            if model.repositories.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "folder.badge.questionmark").font(.system(size: 24)).foregroundStyle(Palette.violet)
                    Text(model.refreshing ? "Finding and checking projects…" : "No Git projects found here")
                    if !model.refreshing { Button("Choose a folder") { model.chooseFolder() }.buttonStyle(NeonButtonStyle()) }
                    Text("Looks three folders deep, skipping build dependencies.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.frame(maxWidth: .infinity).padding(20).background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
            } else {
                VStack(spacing: 0) {
                    ForEach(model.repositories) { repo in
                        repoRow(repo)
                        if repo.id != model.repositories.last?.id { rule }
                    }
                }.background(Palette.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Palette.line))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            if model.performance.memoryLevel >= 2 { memoryNudge }
            HStack {
                if model.refreshing { Text("Fetching updates…") }
                else if let date = model.lastScan { Text("Scanned \(date, style: .relative) ago") }
                else { Text("Waiting for first check") }
                Spacer()
                Button("What do the statuses mean?") { showLegend.toggle() }.buttonStyle(.plain)
                    .accessibilityValue(showLegend ? "Expanded" : "Collapsed")
            }.font(.system(size: 9)).foregroundStyle(Palette.muted).padding(.horizontal, 2)
            if showLegend {
                VStack(alignment: .leading, spacing: 8) {
                    legend("↓ 3 incoming", "Your tracked remote branch has 3 commits you haven’t pulled.", Palette.violet)
                    legend("↑ 2 outgoing", "You have 2 local commits you haven’t pushed.", Palette.violet)
                    legend("5 changed files", "You have uncommitted work.", Palette.pink)
                    legend("Diverged", "Both local and remote branches have new commits.", Palette.amber)
                    legend("Up to date", "Your branch matches its tracked remote branch.", Palette.mint)
                    Text("Checks fetch updates. Files change only when you choose Pull. A failed check leaves remote counts unverified.")
                        .font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.padding(10)
            }
        }
    }
    private func status(_ repo: Repository) -> (String, Color) {
        if repo.error != nil || repo.conflicts > 0 || repo.branch == "(detached)" { return (repo.headline, Palette.amber) }
        if repo.upstream.isEmpty { return ("No tracking branch", Palette.muted) }
        if repo.ahead > 0 && repo.behind > 0 { return ("Diverged", Palette.amber) }
        if repo.behind > 0 { return ("↓ \(repo.behind) incoming", Palette.violet) }
        if repo.ahead > 0 { return ("↑ \(repo.ahead) outgoing", Palette.violet) }
        if repo.changed > 0 { return ("\(repo.changed) changed files", Palette.pink) }
        return repo.checked == nil ? ("Remote not verified", Palette.muted) : ("✓ Up to date", Palette.mint)
    }
    private func repoRow(_ repo: Repository) -> some View {
        let (label, color) = status(repo)
        let expanded = expandedRepository == repo.id
        return VStack(spacing: 0) {
            Button { expandedRepository = expanded ? nil : repo.id } label: {
                HStack(spacing: 9) {
                    Image(systemName: "folder").font(.system(size: 18, weight: .medium)).foregroundStyle(color).frame(width: 29, height: 29)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(repo.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                        Label(repo.branch.isEmpty ? "No branch" : repo.branch, systemImage: "arrow.triangle.branch")
                            .font(.system(size: 9)).foregroundStyle(Palette.muted).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Text(label).font(.system(size: 10, weight: .medium)).foregroundStyle(color).lineLimit(1).fixedSize()
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(Palette.muted).frame(width: 10)
                }.padding(.horizontal, 10).frame(height: 56).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(repo.name), \(label), branch \(repo.branch)")
                .accessibilityValue(expanded ? "Expanded" : "Collapsed")
            if expanded { repositoryDetails(repo).padding(.leading, 48).padding(.trailing, 12).padding(.bottom, 12) }
        }
    }
    private func repositoryDetails(_ repo: Repository) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Text("↓ \(repo.behind) incoming").foregroundStyle(Palette.violet)
                Text("↑ \(repo.ahead) outgoing").foregroundStyle(Palette.violet)
                Text("\(repo.changed) changed files").foregroundStyle(Palette.pink)
            }.font(.system(size: 9))
            if let error = repo.error {
                Text("Couldn’t verify updates. \(error)").foregroundStyle(Palette.amber).textSelection(.enabled)
            } else if repo.upstream.isEmpty {
                Text("Set a tracking branch in your editor to check for incoming commits.").foregroundStyle(Palette.muted)
            } else if repo.behind > 0 && !repo.canPull {
                Text(repo.ahead > 0 ? "Both branches have new commits. Review in your editor before pulling." : "Commit or stash your local edits in your editor before pulling.").foregroundStyle(Palette.amber)
            } else if repo.changed > 0 {
                Text("You have uncommitted work.").foregroundStyle(Palette.muted)
            }
            ForEach(repo.files.prefix(100)) { file in
                VStack(alignment: .leading, spacing: 4) {
                    rule
                    HStack(alignment: .top, spacing: 6) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(file.path).font(.system(size: 10, design: .monospaced)).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                            Text(file.location).font(.system(size: 9)).foregroundStyle(Palette.muted)
                        }
                        Spacer(minLength: 0)
                        Text(file.meaning).font(.system(size: 9)).foregroundStyle(Palette.pink)
                        if !file.code.contains("D") {
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: repo.path).appendingPathComponent(file.path)]) } label: {
                                Image(systemName: "arrow.up.forward.square").foregroundStyle(Palette.muted)
                            }.buttonStyle(.plain).help("Show \(file.path) in Finder").accessibilityLabel("Show \(file.path) in Finder")
                        }
                    }
                }
            }
            if repo.files.count > 100 { Text("Showing 100 of \(repo.files.count) files. Open your editor for all.").foregroundStyle(Palette.muted) }
            HStack(spacing: 8) {
                Menu {
                    Button("Open in T3 Code · copy project path") { model.openT3(repo) }
                    Button("Open in VS Code") { model.openVSCode(repo) }
                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: repo.path)) }
                    if let url = repo.remoteURL { Button("View on GitHub") { NSWorkspace.shared.open(url) } }
                } label: { Text("Open project ↗").font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.lime) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                Spacer()
                if repo.behind > 0 {
                    Button(model.pulling == repo.path ? "Pulling…" : "Review pull") { pendingPull = repo }
                        .buttonStyle(NeonButtonStyle()).disabled(!repo.canPull || model.refreshing || model.pulling != nil)
                }
            }
            if let checked = repo.checked { Text("Remote checked \(checked, style: .relative) ago").font(.system(size: 9)).foregroundStyle(Palette.muted) }
            else { Text("Remote not verified").font(.system(size: 9)).foregroundStyle(Palette.muted) }
        }.font(.system(size: 10))
    }
    private var memoryNudge: some View {
        Button { tab = 1; sortMemory = true } label: {
            HStack(spacing: 8) {
                Image(systemName: "memorychip").font(.system(size: 16)).foregroundStyle(Palette.amber)
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.performance.memoryLevel == 4 ? "Memory pressure is high" : "Memory is under pressure")
                        .font(.system(size: 10, weight: .medium)).foregroundStyle(Palette.amber)
                    Text("See the largest memory users").font(.system(size: 9)).foregroundStyle(Palette.muted)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 9)).foregroundStyle(Palette.amber)
            }.padding(10).background(Palette.surface, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Palette.line))
        }.buttonStyle(.plain)
    }
    private func legend(_ title: String, _ meaning: String, _ color: Color) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(title).foregroundStyle(color).frame(width: 95, alignment: .leading)
            Text(meaning).foregroundStyle(Palette.muted).frame(maxWidth: .infinity, alignment: .leading)
        }.font(.system(size: 10))
    }
    private var performance: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.performance.memoryLevel >= 2 ? "Memory is worth a look." : "What’s using your Mac?")
                    .font(.system(size: 13, weight: .semibold))
                Text("Only likely contributors with resource evidence appear here.").font(.system(size: 10)).foregroundStyle(Palette.muted)
            }
            HStack(spacing: 10) {
                HStack(spacing: 5) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Palette.muted)
                    TextField("Find an app or process", text: $search).textFieldStyle(.plain).font(.system(size: 10))
                }.padding(7).background(Palette.surface, in: RoundedRectangle(cornerRadius: 6))
                Picker("Sort contributors", selection: $sortMemory) { Text("CPU").tag(false); Text("Memory").tag(true) }
                    .pickerStyle(.segmented).frame(width: 113).controlSize(.mini).labelsHidden()
            }
            if let error = model.performance.error { Text(error).font(.system(size: 10)).foregroundStyle(Palette.amber) }
            if filteredApps.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(search.isEmpty ? "No clear contributor identified" : "No matching contributors", systemImage: "checkmark.circle").foregroundStyle(Palette.mint)
                    Text("Watching for sustained CPU usage and large memory users when pressure is elevated.").font(.system(size: 10)).foregroundStyle(Palette.muted)
                }.padding(12).frame(maxWidth: .infinity, alignment: .leading).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            } else {
                LazyVStack(spacing: 8) { ForEach(filteredApps.prefix(40)) { usage in processCard(usage) } }
            }
            Text("These are likely contributors, not a confirmed cause. Memory bars compare shown apps, not total RAM. Process CPU: 100% = one core. Swap: \(model.performance.swapGB, specifier: "%.1f") GB; swap alone doesn’t mean your Mac is currently struggling.")
                .font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize(horizontal: false, vertical: true)
            Button("Open Activity Monitor ↗") { model.activityMonitor() }.buttonStyle(NeonButtonStyle())
            Text("Quit controls are for your non-system desktop apps. Inspect other processes in Activity Monitor.").font(.system(size: 9)).foregroundStyle(Palette.muted)
        }
    }
    private var filteredApps: [AppUsage] {
        model.contributors.filter { search.isEmpty || $0.name.localizedCaseInsensitiveContains(search) || $0.processes.contains { $0.command.localizedCaseInsensitiveContains(search) || String($0.pid).contains(search) } }
            .sorted { sortMemory ? $0.memoryMB > $1.memoryMB : $0.cpu > $1.cpu }
    }
    private func processCard(_ usage: AppUsage) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 8) {
                if let icon = usage.icon { Image(nsImage: icon).resizable().frame(width: 26, height: 26) }
                else { Image(systemName: "terminal").font(.system(size: 18)).foregroundStyle(Palette.violet).frame(width: 26, height: 26) }
                Text(usage.name).font(.system(size: 11, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 4)
                Text(sortMemory ? memoryAmount(usage.memoryMB) : String(format: "%.1f%%", usage.cpu))
                    .font(.system(size: 12, weight: .semibold)).foregroundStyle(sortMemory ? Palette.pink : Palette.lime).fixedSize()
            }
            GeometryReader { geo in
                RoundedRectangle(cornerRadius: 2).fill(Palette.line).overlay(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(sortMemory ? Palette.pink : Palette.lime)
                        .frame(width: geo.size.width * min(1, max(0.005, sortMemory ? usage.memoryMB / max(1, filteredApps.first?.memoryMB ?? 1) : usage.cpu / Double(ProcessInfo.processInfo.processorCount * 100))))
                }
            }.frame(height: 3).accessibilityHidden(true)
            ForEach(model.reasons(for: usage), id: \.self) { reason in Text(reason).font(.system(size: 10)).foregroundStyle(Palette.muted) }
            HStack {
                Text(sortMemory ? String(format: "%.1f%% CPU · %d processes", usage.cpu, usage.processes.count) : "\(memoryAmount(usage.memoryMB)) · \(usage.processes.count) processes")
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
                Spacer()
                if usage.canQuit { Button("Review quit") { forceQuit = false; pendingQuit = usage }.buttonStyle(NeonButtonStyle()) }
            }
            Button { expandedApp = expandedApp == usage.id ? nil : usage.id } label: {
                Label("See process details", systemImage: expandedApp == usage.id ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9)).foregroundStyle(Palette.muted)
            }.buttonStyle(.plain).accessibilityValue(expandedApp == usage.id ? "Expanded" : "Collapsed")
            if expandedApp == usage.id {
                ForEach(usage.processes.sorted { sortMemory ? $0.memoryMB > $1.memoryMB : $0.cpu > $1.cpu }.prefix(30)) { process in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(process.name).font(.system(size: 10, weight: .medium))
                            Text("PID \(process.pid) · \(process.command)").font(.system(size: 9)).foregroundStyle(Palette.muted)
                                .lineLimit(2).textSelection(.enabled).help(process.command)
                        }
                        Spacer()
                        Text(sortMemory ? memoryAmount(process.memoryMB) : String(format: "%.1f%%", process.cpu)).font(.system(size: 9)).foregroundStyle(Palette.muted).fixedSize()
                    }
                }
                if usage.processes.count > 30 { Text("Showing 30 of \(usage.processes.count) processes. See Activity Monitor for all.").font(.system(size: 9)).foregroundStyle(Palette.muted) }
                Text("Memory totals may count shared pages more than once.").font(.system(size: 9)).foregroundStyle(Palette.muted)
                if usage.canQuit { Button("Force quit…") { forceQuit = true; pendingQuit = usage }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(Palette.amber) }
            }
        }.padding(12).background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Palette.line))
    }
    private func memoryAmount(_ mb: Double) -> String { mb >= 1024 ? String(format: "%.1f GB", mb / 1024) : String(format: "%.0f MB", mb) }
    private var memoryColor: Color { model.performance.memoryLevel == 1 ? Palette.mint : model.performance.memoryLevel == 0 ? Palette.muted : Palette.amber }
    private var footer: some View {
        HStack(spacing: 8) {
            Button { showCPU.toggle() } label: {
                HStack(spacing: 7) {
                    Text("CPU").foregroundStyle(Palette.muted)
                    Sparkline(values: model.history).frame(width: 44, height: 18).foregroundStyle(Palette.lime)
                    Text(model.history.isEmpty ? "…" : "\(Int(model.performance.cpu))%").fontWeight(.semibold).foregroundStyle(Palette.lime).monospacedDigit()
                }.font(.system(size: 10))
            }.buttonStyle(.plain).accessibilityLabel("CPU \(Int(model.performance.cpu)) percent. Show activity details")
                .popover(isPresented: $showCPU) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("CPU: \(Int(model.performance.cpu))% of your Mac’s capacity").font(.system(size: 12, weight: .semibold))
                        Sparkline(values: model.history).frame(height: 60).foregroundStyle(Palette.lime)
                        Text("Recent samples across all cores. Memory pressure is a separate signal. Samples are about 3 seconds apart while open and 15 seconds apart otherwise.")
                            .font(.system(size: 10)).foregroundStyle(Palette.muted)
                    }.padding(16).frame(width: 300).background(Palette.canvas).preferredColorScheme(.dark)
                }
            Spacer(minLength: 8)
            Rectangle().fill(Palette.line).frame(width: 1, height: 14)
            Spacer(minLength: 8)
            Button { tab = 1; sortMemory = true } label: {
                HStack(spacing: 6) {
                    HStack(spacing: 2) {
                        ForEach(0..<4) { index in
                            RoundedRectangle(cornerRadius: 1.5).fill(memorySegmentActive(index) ? memoryColor : Palette.line).frame(width: 4, height: 9)
                        }
                    }.accessibilityHidden(true)
                    Text("Memory").foregroundStyle(Palette.muted)
                    Text(model.memoryTitle).foregroundStyle(memoryColor)
                    Image(systemName: "chevron.right").font(.system(size: 8)).foregroundStyle(Palette.muted)
                }.font(.system(size: 9))
            }.buttonStyle(.plain).accessibilityLabel("Memory \(model.memoryTitle). Show memory contributors")
        }.padding(.horizontal, 16).frame(height: 48).background(Palette.surface)
            .overlay(alignment: .top) { rule }
    }
    private func memorySegmentActive(_ index: Int) -> Bool {
        switch model.performance.memoryLevel { case 1: return index == 0; case 2: return index < 3; case 4: return true; default: return false }
    }
    private var rule: some View { Rectangle().fill(Palette.line).frame(height: 1) }
}

private struct NeonButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 10, weight: .semibold))
            .foregroundStyle(enabled ? Color.black : Palette.muted)
            .padding(.horizontal, 8).padding(.vertical, 6)
            .background(enabled ? Palette.lime.opacity(configuration.isPressed ? 0.8 : 1) : Palette.line, in: RoundedRectangle(cornerRadius: 6))
    }
}

struct Sparkline: View {
    let values: [Double]
    var body: some View {
        GeometryReader { geo in
            Path { path in
                guard values.count > 1 else { return }
                for (index, value) in values.enumerated() {
                    let point = CGPoint(x: CGFloat(index) / CGFloat(values.count - 1) * geo.size.width, y: geo.size.height * (1 - min(100, max(0, value)) / 100))
                    if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
                }
            }.stroke(style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
        }.accessibilityLabel("Recent CPU usage: \(Int(values.last ?? 0)) percent")
    }
}
