import SwiftUI
import AppKit
import ImageIO
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HSplitView {
            SidebarView()
                .frame(minWidth: 300, idealWidth: 330, maxWidth: 430)
            ResultsView()
                .frame(minWidth: 640)
        }
        .sheet(item: $state.pendingAction) { action in
            ConfirmActionSheet(action: action)
                .environmentObject(state)
        }
        .background(
            Color.clear.sheet(isPresented: $state.showQuarantine) {
                QuarantineView()
                    .environmentObject(state)
            }
        )
    }
}

// MARK: - Sidebar (folders, options, scan)

struct SidebarView: View {
    @EnvironmentObject var state: AppState
    @State private var showThresholds = false

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    GroupBox("Folders to scan") {
                        VStack(alignment: .leading, spacing: 8) {
                            if state.folders.isEmpty {
                                Text("Add folders, or drag them here.").foregroundStyle(.secondary)
                            }
                            ForEach(state.folders) { entry in
                                HStack {
                                    Image(systemName: "folder.fill").foregroundColor(.blue)
                                    VStack(alignment: .leading, spacing: 1) {
                                        Text(entry.url.lastPathComponent).lineLimit(1)
                                        Text(entry.url.path).font(.caption).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                        Toggle("Include subfolders", isOn: Binding(
                                            get: { entry.recursive },
                                            set: { state.setRecursive(entry.url, $0) }))
                                            .toggleStyle(.checkbox)
                                            .controlSize(.small)
                                    }
                                    Spacer()
                                    Button { state.removeFolder(entry.url) } label: {
                                        Image(systemName: "minus.circle")
                                    }
                                    .buttonStyle(.borderless)
                                }
                                .disabled(state.isScanning)
                            }
                            Button { state.addFolders() } label: { Label("Add Folder…", systemImage: "plus") }
                                .disabled(state.isScanning)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }

                    GroupBox("Matching") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Exact duplicates (identical files) are always found.")
                                .font(.caption).foregroundStyle(.secondary)
                            Toggle("Also find edited, resized, converted, cropped or rotated versions",
                                   isOn: $state.settings.findSimilar)
                            if state.settings.findSimilar {
                                Toggle("Detect rotated versions (90° / 180°)", isOn: $state.settings.detectRotation)
                                DisclosureGroup("Detection thresholds", isExpanded: $showThresholds) {
                                    ThresholdsView()
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                    .disabled(state.isScanning)

                    GroupBox("Pick the original by") {
                        VStack(alignment: .leading, spacing: 6) {
                            Picker("Rule", selection: $state.rule) {
                                ForEach(OriginalRule.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .labelsHidden()
                            .onChange(of: state.rule) { _ in state.applyRuleToAll() }

                            if state.rule == .recommended {
                                Text("Prefers highest resolution, least compression, camera EXIF and unedited files. Unclear cases are marked MANUAL REVIEW.")
                                    .font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            if state.rule == .preferredFolder {
                                Button(state.preferredFolder == nil ? "Choose Preferred Folder…" : "Change Folder…") {
                                    state.choosePreferredFolder()
                                }
                                if let p = state.preferredFolder {
                                    Text(p.path).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(4)
                    }
                }
                .padding()
            }
            .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
                let st = state
                for provider in providers {
                    _ = provider.loadObject(ofClass: URL.self) { url, _ in
                        guard let url = url else { return }
                        Task { @MainActor in st.addDropped([url]) }
                    }
                }
                return true
            }

            Divider()
            VStack(alignment: .leading, spacing: 4) {
                Toggle("Safe Mode (preview only)", isOn: $state.safeMode)
                    .toggleStyle(.checkbox)
                Text(state.safeMode ? "On: nothing can be moved or deleted. Scanning only reads your photos."
                                    : "Off: Quarantine and Trash are enabled. Every action still asks for confirmation.")
                    .font(.caption2)
                    .foregroundColor(state.safeMode ? .green : .orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal).padding(.top, 8)
            ScanControlsView().padding()
        }
    }
}

struct ThresholdsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            thresholdRow("High confidence (same photograph)", value: $state.settings.highThreshold, range: 0.70...0.98)
            thresholdRow("Medium (likely – verify)", value: $state.settings.mediumThreshold, range: 0.60...0.95)
            thresholdRow("Low (possible match)", value: $state.settings.lowThreshold, range: 0.50...0.90)
            VStack(alignment: .leading, spacing: 2) {
                Text("Crop tolerance: up to \(Int((state.settings.maxCrop * 100).rounded()))% per side").font(.caption)
                Slider(value: $state.settings.maxCrop, in: 0.05...0.35, step: 0.01)
            }
            Text("Only high-confidence matches are pre-selected for removal. Raising thresholds = fewer, safer matches.")
                .font(.caption2).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Reset to Defaults") { state.resetSettings() }
                Spacer()
                Button("Clear Cache") { state.clearCache() }
                    .help("Forget cached fingerprints so every image is analysed again")
            }
            .controlSize(.small)
        }
        .padding(.top, 4)
    }

    private func thresholdRow(_ title: String, value: Binding<Float>, range: ClosedRange<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(title): \(Int((value.wrappedValue * 100).rounded()))%").font(.caption)
            Slider(value: value, in: range, step: 0.01)
        }
    }
}

struct ScanControlsView: View {
    @EnvironmentObject var state: AppState

    private var p: ScanProgress { state.progress }

    var body: some View {
        VStack(spacing: 8) {
            if state.isScanning {
                Text(p.stage > 0 ? "Stage \(p.stage) of 5 · \(p.stageName)" : p.stageName)
                    .font(.callout.weight(.semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                if p.total > 0 {
                    ProgressView(value: Double(min(p.done, p.total)), total: Double(p.total))
                    Text("\(p.done) of \(p.total) processed")
                        .font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ProgressView().controlSize(.small)
                    if p.done > 0 {
                        Text("\(p.done) images found").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if !p.currentFolder.isEmpty {
                    Text(p.folderCount > 0 && p.folderIndex > 0
                         ? "Folder \(p.folderIndex) of \(p.folderCount): \(p.currentFolder)"
                         : "Folder: \(p.currentFolder)")
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.head)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(p.currentFolder)
                }
                HStack {
                    Text("Elapsed \(Fmt.duration(p.elapsed))")
                    Spacer()
                    if state.isPaused {
                        Text("Paused").foregroundColor(.orange)
                    } else if let eta = p.stageETA {
                        Text("~\(Fmt.duration(eta)) left in this stage")
                    }
                }
                .font(.caption).foregroundStyle(.secondary)
                HStack {
                    if state.isPaused {
                        Button { state.resumeScan() } label: { Label("Resume", systemImage: "play.fill") }
                    } else {
                        Button { state.pauseScan() } label: { Label("Pause", systemImage: "pause.fill") }
                    }
                    Spacer()
                    Button("Cancel") { state.cancelScan() }
                }
            } else {
                Button { state.startScan() } label: {
                    Label("Scan for Duplicates", systemImage: "magnifyingglass")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.folders.isEmpty)
            }
            if let msg = state.statusMessage {
                Text(msg).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Results

struct ResultsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            if !state.groups.isEmpty || !state.folderSummaries.isEmpty {
                header
                Divider()
            }
            if state.groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: state.isScanning ? "hourglass" : "photo.on.rectangle.angled")
                        .font(.system(size: 48)).foregroundStyle(.secondary)
                    Text(state.isScanning ? "Scanning…"
                         : (state.stats != nil ? "No duplicates found." : "Add folders on the left, then click Scan."))
                        .foregroundStyle(.secondary)
                    if !state.quarantineItems.isEmpty && !state.isScanning {
                        Button("Open Quarantine (\(state.quarantineItems.count))…") { state.showQuarantine = true }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.mode == .folders {
                FolderModeView()
            } else {
                GroupListView(groups: state.visibleGroups, highlightFolder: nil)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(state.groups.count) duplicate groups").font(.headline)
                    Text("\(state.markedCount) selected · \(Fmt.bytes(state.markedBytes)) to free")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Picker("View", selection: $state.mode) {
                    ForEach(ResultsMode.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                Button(role: .destructive) { state.requestQuarantine() } label: {
                    Label("Quarantine \(state.markedCount)…", systemImage: "archivebox")
                }
                .buttonStyle(.borderedProminent)
                .tint(.red)
                .disabled(state.markedCount == 0 || state.safeMode)
                .help(state.safeMode ? "Turn off Safe Mode (bottom left) to enable" : "Move the selected files to the quarantine folder")
            }
            HStack(spacing: 10) {
                Picker("Show", selection: $state.filter) {
                    ForEach(ResultsFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 210)
                TextField("Filter by path", text: $state.searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(minWidth: 140, maxWidth: 240)
                Spacer()
                Menu("Select") {
                    Button("Select All Confirmed Duplicates") { state.selectAllConfirmed() }
                    Button("Clear All Selections") { state.clearAllSelections() }
                }
                .frame(width: 80)
                Button("Export CSV…") { state.exportCSV() }
                Button { state.showQuarantine = true } label: {
                    Label("Quarantine (\(state.quarantineItems.count))", systemImage: "tray.full")
                }
                Button { state.requestTrash() } label: { Label("Trash", systemImage: "trash") }
                    .disabled(state.markedCount == 0 || state.safeMode)
                    .help("Move the selected files to the macOS Trash instead of the quarantine folder")
            }
            .controlSize(.small)
        }
        .padding()
    }
}

struct GroupListView: View {
    @EnvironmentObject var state: AppState
    let groups: [DuplicateGroup]
    let highlightFolder: String?

    var body: some View {
        if groups.isEmpty {
            Text("No groups match the current filter.")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    ForEach(Array(groups.enumerated()), id: \.element.id) { n, g in
                        GroupCard(group: g, number: n + 1, highlightFolder: highlightFolder)
                    }
                }
                .padding()
            }
        }
    }
}

struct FolderModeView: View {
    @EnvironmentObject var state: AppState

    private func depth(_ path: String) -> Int {
        let roots = state.folders.map { $0.url.path }
        let root = roots.filter { path.hasPrefix($0) }.max { $0.count < $1.count } ?? ""
        return max(0, path.dropFirst(root.count).split(separator: "/").count)
    }

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 0) {
                Toggle("Only folders with duplicates", isOn: $state.onlyFoldersWithDuplicates)
                    .toggleStyle(.checkbox).controlSize(.small)
                    .padding(8)
                Divider()
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(state.visibleFolders, id: \.path) { f in
                            Button { state.selectedFolder = f.path } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder").foregroundColor(f.duplicateCount > 0 ? .orange : .secondary)
                                    VStack(alignment: .leading, spacing: 0) {
                                        Text((f.path as NSString).lastPathComponent).lineLimit(1)
                                        Text("\(f.imageCount) images · \(f.duplicateCount) duplicates")
                                            .font(.caption2).foregroundStyle(.secondary)
                                    }
                                    Spacer()
                                }
                                .padding(.leading, CGFloat(depth(f.path)) * 12)
                                .padding(.vertical, 3).padding(.horizontal, 6)
                                .background(RoundedRectangle(cornerRadius: 5)
                                    .fill(state.selectedFolder == f.path ? Color.accentColor.opacity(0.2) : Color.clear))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help(f.path)
                            .contextMenu {
                                Button("Scan Only This Folder") { state.startScan(roots: [ScanRoot(url: URL(fileURLWithPath: f.path), recursive: false)]) }
                                Button("Scan This Folder and Subfolders") { state.startScan(roots: [ScanRoot(url: URL(fileURLWithPath: f.path), recursive: true)]) }
                                Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) }
                            }
                        }
                    }
                    .padding(6)
                }
            }
            .frame(width: 280)
            Divider()
            VStack(spacing: 0) {
                if let folder = state.selectedFolder {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text((folder as NSString).lastPathComponent).font(.headline)
                            Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        Button("Select Confirmed Duplicates Here") { state.selectConfirmed(inFolder: folder) }
                        Button("Clear") { state.clearSelection(inFolder: folder) }
                    }
                    .controlSize(.small)
                    .padding(10)
                    Divider()
                    GroupListView(groups: state.groups(inFolder: folder), highlightFolder: folder)
                } else {
                    Text("Select a folder to see the duplicates found in it.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.caption2.bold())
            .foregroundColor(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(Capsule().fill(color))
    }
}

extension MemberLabel {
    var color: Color {
        switch self {
        case .original: return .green
        case .exact: return .red
        case .visual: return .orange
        case .edited: return .purple
        case .possible: return .gray
        }
    }
}

struct GroupCard: View {
    @EnvironmentObject var state: AppState
    let group: DuplicateGroup
    let number: Int
    let highlightFolder: String?

    private let columns = [GridItem(.adaptive(minimum: 220, maximum: 270), spacing: 12, alignment: .top)]

    private var reclaimable: Int64 { group.markedForDeletion.reduce(Int64(0)) { $0 + state.images[$1].size } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Group \(number)").font(.headline)
                if group.result.manualReview { Badge(text: "MANUAL REVIEW", color: .yellow.opacity(0.9)) }
                Text(group.result.scope.rawValue)
                    .font(.caption)
                    .padding(.horizontal, 8).padding(.vertical, 2)
                    .background(Capsule().fill(Color.blue.opacity(0.15)))
                Text("\(group.members.count) files").foregroundStyle(.secondary)
                Spacer()
                if reclaimable > 0 { Text("Frees \(Fmt.bytes(reclaimable))").foregroundStyle(.secondary) }
                Button("Select All Duplicates") { state.selectAllDuplicates(in: group.id) }
                Button("Clear") { state.clearSelection(in: group.id) }
                if group.isUserOverride {
                    Button("Reset to Recommended") { state.resetToRecommended(group.id) }
                }
            }
            .controlSize(.small)

            if group.result.manualReview, let why = group.result.reviewReason {
                Label(why + ". Nothing in this group was pre-selected – choose the original yourself.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundColor(.orange)
            } else if !group.isUserOverride && !group.result.originalReasons.isEmpty {
                Text("Recommended original: " + group.result.originalReasons.joined(separator: ", "))
                    .font(.caption).foregroundStyle(.secondary)
            }

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                ForEach(group.members, id: \.imageIndex) { m in
                    FileCard(
                        image: state.images[m.imageIndex],
                        member: m,
                        isOriginal: group.originalIndex == m.imageIndex,
                        isMarked: group.markedForDeletion.contains(m.imageIndex),
                        dimmed: highlightFolder != nil && state.images[m.imageIndex].folder != highlightFolder,
                        onKeep: { state.setOriginal(m.imageIndex, in: group.id) },
                        onToggle: { state.toggleDelete(m.imageIndex, in: group.id) }
                    )
                }
            }
        }
        .padding()
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(group.result.manualReview ? Color.yellow : Color.clear, lineWidth: 1.5))
    }
}

struct FileCard: View {
    let image: ScannedImage
    let member: GroupMember
    let isOriginal: Bool
    let isMarked: Bool
    let dimmed: Bool
    let onKeep: () -> Void
    let onToggle: () -> Void

    private var borderColor: Color { isOriginal ? .green : (isMarked ? .red : .clear) }

    private var details: String {
        var parts: [String] = [image.meta.format]
        if image.meta.pixelWidth > 0 { parts.append("\(image.meta.pixelWidth)×\(image.meta.pixelHeight)") }
        parts.append(Fmt.bytes(image.size))
        if let d = image.modified { parts.append(Fmt.date.string(from: d)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ZStack(alignment: .topLeading) {
                ThumbnailView(url: image.url)
                    .frame(maxWidth: .infinity)
                    .frame(height: 150)
                    .background(Color.black.opacity(0.06))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                VStack(alignment: .leading, spacing: 3) {
                    Badge(text: isOriginal ? MemberLabel.original.rawValue : member.label.rawValue,
                          color: isOriginal ? MemberLabel.original.color : member.label.color)
                    if isMarked { Badge(text: "SELECTED", color: .red) }
                }
                .padding(6)
            }
            .contentShape(Rectangle())
            .onTapGesture(count: 2) { NSWorkspace.shared.open(image.url) }

            Text(image.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)
            Text(image.folder)
                .font(.caption).foregroundStyle(.secondary)
                .lineLimit(2)
                .textSelection(.enabled)
                .help(image.path)
            Text(details).font(.caption2).foregroundStyle(.secondary)
            if !isOriginal {
                Text("Similarity \(Int((member.similarity * 100).rounded()))% · \(member.confidence.title) confidence")
                    .font(.caption2.weight(.semibold))
                    .foregroundColor(member.confidence >= .high ? .primary : .orange)
                Text(member.method).font(.caption2).foregroundStyle(.secondary).lineLimit(1).help(member.method)
                if !member.notes.isEmpty {
                    Text(member.notes.joined(separator: ", "))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(2)
                        .help(member.notes.joined(separator: "\n"))
                }
            }

            HStack {
                Button(isOriginal ? "Original" : "Keep as Original", action: onKeep)
                    .disabled(isOriginal)
                Spacer()
                Toggle("Delete", isOn: Binding(get: { isMarked }, set: { _ in onToggle() }))
                    .toggleStyle(.checkbox)
                    .disabled(isOriginal)
            }
            .controlSize(.small)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(nsColor: .windowBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 10).stroke(borderColor, lineWidth: 2))
        .opacity(dimmed ? 0.55 : 1)
        .contextMenu {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([image.url]) }
            Button("Open") { NSWorkspace.shared.open(image.url) }
            Button("Copy Path") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(image.path, forType: .string)
            }
        }
    }
}

// MARK: - Confirmation

struct ConfirmActionSheet: View {
    @EnvironmentObject var state: AppState
    let action: PendingAction

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: action.kind == .deletePermanently ? "exclamationmark.octagon.fill" : "archivebox.fill")
                    .font(.largeTitle)
                    .foregroundColor(action.kind == .deletePermanently ? .red : .orange)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.headline)
                    Text("\(Fmt.bytes(action.totalBytes)) in \(action.byFolder.count) folder\(action.byFolder.count == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            }
            Text(explanation).font(.callout).fixedSize(horizontal: false, vertical: true)
            Text("Locations").font(.subheadline.weight(.semibold))
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(action.byFolder, id: \.folder) { f in
                        VStack(alignment: .leading, spacing: 1) {
                            Text("\(f.count) × \(f.folder)").font(.caption.weight(.semibold)).textSelection(.enabled)
                            ForEach(action.paths.filter { ($0 as NSString).deletingLastPathComponent == f.folder }, id: \.self) { p in
                                Text("   " + (p as NSString).lastPathComponent).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 160, maxHeight: 320)
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .textBackgroundColor)))
            HStack {
                Spacer()
                Button("Cancel") { state.pendingAction = nil }
                    .keyboardShortcut(.cancelAction)
                Button(action.confirmTitle, role: .destructive) { state.perform(action) }
                    .buttonStyle(.borderedProminent)
                    .tint(action.kind == .deletePermanently ? .red : .orange)
            }
        }
        .padding(20)
        .frame(width: 620)
    }

    private var explanation: String {
        switch action.kind {
        case .quarantine:
            return "The files are moved to \(state.quarantine.root.path), keeping their folder structure. The original of every group stays where it is. You can restore them at any time from Quarantine."
        case .trash:
            return "The files are moved to the macOS Trash. The original of every group stays where it is. A log is written to ~/Library/Logs/DupeSweep."
        case .deletePermanently:
            return "These quarantined files will be erased permanently. This cannot be undone."
        }
    }
}

// MARK: - Quarantine manager

struct QuarantineView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var selection = Set<UUID>()

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Quarantine").font(.title2.bold())
                    Text("\(state.quarantineItems.count) files · \(Fmt.bytes(state.quarantineItems.reduce(Int64(0)) { $0 + $1.size }))")
                        .foregroundStyle(.secondary)
                    Text(state.quarantine.root.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button("Change Folder…") { state.chooseQuarantineFolder() }
                Button("Show in Finder") { state.revealQuarantine() }
            }
            .controlSize(.small)
            Divider()
            if state.quarantineItems.isEmpty {
                Text("Nothing in quarantine.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Button("Select All") { selection = Set(state.quarantineItems.map { $0.id }) }
                    Button("Select None") { selection = [] }
                    Spacer()
                    Text("\(selection.count) selected").foregroundStyle(.secondary)
                }
                .controlSize(.small)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 4) {
                        ForEach(state.quarantineItems.sorted { $0.date > $1.date }) { item in
                            HStack(alignment: .top) {
                                Toggle("", isOn: Binding(
                                    get: { selection.contains(item.id) },
                                    set: { on in if on { selection.insert(item.id) } else { selection.remove(item.id) } }))
                                    .toggleStyle(.checkbox)
                                    .labelsHidden()
                                VStack(alignment: .leading, spacing: 1) {
                                    Text((item.originalPath as NSString).lastPathComponent).font(.callout)
                                    Text("from " + (item.originalPath as NSString).deletingLastPathComponent)
                                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                    if let kept = item.keptOriginalPath {
                                        Text("original kept: " + kept).font(.caption2).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                }
                                Spacer()
                                Text(Fmt.date.string(from: item.date)).font(.caption).foregroundStyle(.secondary)
                                Text(Fmt.bytes(item.size)).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                }
            }
            Divider()
            HStack {
                Button("Restore Selected") { state.restore(selection); selection = [] }
                    .disabled(selection.isEmpty)
                Button("Restore All") { state.restore(Set(state.quarantineItems.map { $0.id })); selection = [] }
                    .disabled(state.quarantineItems.isEmpty)
                Spacer()
                Button("Delete Permanently…", role: .destructive) {
                    let ids = selection
                    selection = []
                    dismiss()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { state.requestPermanentDelete(ids) }
                }
                .disabled(selection.isEmpty || state.safeMode)
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 720, height: 520)
    }
}

// MARK: - Thumbnails

struct ThumbnailView: View {
    let url: URL
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image = image {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fit)
            } else if failed {
                Image(systemName: "photo").font(.largeTitle).foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task(id: url) {
            image = await ThumbnailLoader.shared.image(for: url)
            failed = image == nil
        }
    }
}

@MainActor
final class ThumbnailLoader {
    static let shared = ThumbnailLoader()
    private let cache = NSCache<NSURL, NSImage>()

    private struct Box: @unchecked Sendable { let cg: CGImage? }

    init() { cache.countLimit = 600 }

    func image(for url: URL) async -> NSImage? {
        if let hit = cache.object(forKey: url as NSURL) { return hit }
        let box = await Task.detached(priority: .utility) { () -> Box in
            let opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 400,
            ]
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return Box(cg: nil) }
            return Box(cg: CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary))
        }.value
        guard let cg = box.cg else { return nil }
        let img = NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        cache.setObject(img, forKey: url as NSURL)
        return img
    }
}
