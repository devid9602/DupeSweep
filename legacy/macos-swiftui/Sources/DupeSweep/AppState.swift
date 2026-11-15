import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Fingerprint cache shared by all scans (~/Library/Caches/DupeSweep).
enum AppCache {
    static let url = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/DupeSweep/fingerprints.bin")
    static let shared = FingerprintCache(url: url)
}

/// Detection settings remembered between launches.
enum SettingsStore {
    private static let key = "DetectionSettings"
    static func load() -> DetectionSettings {
        guard let d = UserDefaults.standard.data(forKey: key),
              let s = try? JSONDecoder().decode(DetectionSettings.self, from: d) else { return DetectionSettings() }
        return s
    }
    static func save(_ s: DetectionSettings) {
        if let d = try? JSONEncoder().encode(s) { UserDefaults.standard.set(d, forKey: key) }
    }
}

/// Only confirmed, high-confidence duplicates in groups whose original is certain are pre-selected.
func autoMarks(_ r: DuplicateGroupResult) -> Set<Int> {
    guard !r.manualReview else { return [] }
    let orig = r.members.first { $0.label == .original }?.imageIndex
    return Set(r.members.filter { $0.label.isConfirmedDuplicate && $0.confidence >= .high && $0.imageIndex != orig }
        .map { $0.imageIndex })
}

@MainActor
final class AppState: ObservableObject {
    // Inputs
    @Published var folders: [FolderEntry] = []
    @Published var settings = SettingsStore.load() { didSet { SettingsStore.save(settings) } }
    @Published var rule: OriginalRule = .recommended
    @Published var preferredFolder: URL?

    // Scan state
    @Published var isScanning = false
    @Published var isPaused = false
    @Published var progress = ScanProgress()
    @Published var statusMessage: String?

    // Results
    @Published var images: [ScannedImage] = []
    @Published var groups: [DuplicateGroup] = []
    @Published var folderSummaries: [FolderSummary] = []
    @Published var stats: ScanStats?
    @Published var mode: ResultsMode = .groups
    @Published var filter: ResultsFilter = .all
    @Published var searchText = ""
    @Published var selectedFolder: String?
    @Published var onlyFoldersWithDuplicates = true

    // Actions
    @Published var pendingAction: PendingAction?
    @Published var showQuarantine = false
    /// Safe Mode: scanning and reviewing only. No file can be moved or deleted while it is on.
    @Published var safeMode = (UserDefaults.standard.object(forKey: "SafeMode") as? Bool) ?? true {
        didSet { UserDefaults.standard.set(safeMode, forKey: "SafeMode") }
    }

    private func blockedBySafeMode() -> Bool {
        guard safeMode else { return false }
        statusMessage = "Safe Mode is on – no files were moved. Turn it off (bottom left) when you are ready to act."
        return true
    }
    @Published var quarantineItems: [QuarantineItem] = []

    let quarantine = QuarantineStore()
    private var control: ScanControl?
    private var relabeler: Relabeler?


    init() { quarantineItems = quarantine.items }

    var markedCount: Int { groups.reduce(0) { $0 + $1.markedForDeletion.count } }
    var markedBytes: Int64 {
        groups.reduce(0) { sum, g in sum + g.markedForDeletion.reduce(Int64(0)) { $0 + images[$1].size } }
    }

    func resetSettings() { settings = DetectionSettings() }

    /// Settings with the thresholds kept in order (high ≥ medium ≥ low).
    private var effectiveSettings: DetectionSettings {
        var s = settings
        s.mediumThreshold = min(s.mediumThreshold, s.highThreshold)
        s.lowThreshold = min(s.lowThreshold, s.mediumThreshold)
        return s
    }

    func clearCache() {
        AppCache.shared.clear()
        statusMessage = "Cache cleared – the next scan analyses every image again."
    }

    // MARK: Folders

    func addFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Add"
        if panel.runModal() == .OK { for u in panel.urls { addFolder(u) } }
    }

    func addDropped(_ urls: [URL]) {
        for u in urls where (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
            addFolder(u)
        }
    }

    private func addFolder(_ url: URL) {
        let u = url.standardizedFileURL
        if !folders.contains(where: { $0.url == u }) { folders.append(FolderEntry(url: u)) }
    }

    func removeFolder(_ url: URL) { folders.removeAll { $0.url == url } }

    func setRecursive(_ url: URL, _ on: Bool) {
        if let i = folders.firstIndex(where: { $0.url == url }) { folders[i].recursive = on }
    }

    func choosePreferredFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Use as Preferred"
        if panel.runModal() == .OK, let u = panel.url {
            preferredFolder = u.standardizedFileURL
            applyRuleToAll()
        }
    }

    // MARK: Scanning

    func startScan(roots custom: [ScanRoot]? = nil) {
        let roots = custom ?? folders.map { ScanRoot(url: $0.url, recursive: $0.recursive) }
        guard !roots.isEmpty, !isScanning else { return }
        isScanning = true
        isPaused = false
        groups = []
        images = []
        folderSummaries = []
        stats = nil
        relabeler = nil
        selectedFolder = nil
        statusMessage = nil
        var p = ScanProgress()
        p.stageName = "Starting…"
        progress = p

        let control = ScanControl()
        self.control = control
        let settings = effectiveSettings
        let cache = AppCache.shared
        let me = self
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let engine = ScanEngine(provider: ImageIOProvider(), settings: settings, cache: cache)
            let report = engine.run(roots: roots, control: control) { p in
                Task { @MainActor in me.progress = p }
            }
            let secs = control.activeTime(since: started)
            Task { @MainActor in me.finish(report, seconds: secs) }
        }
    }

    func pauseScan() { control?.pause(); isPaused = true }
    func resumeScan() { control?.resume(); isPaused = false }
    func cancelScan() { control?.resume(); control?.cancel() }

    private func finish(_ report: ScanReport, seconds: Double) {
        isScanning = false
        isPaused = false
        control = nil
        images = report.images
        stats = report.stats
        folderSummaries = report.folders
        if report.cancelled {
            statusMessage = "Scan cancelled. Work done so far is cached, so the next scan resumes faster."
            return
        }
        relabeler = report.relabeler
        groups = report.groups.map { r in
            var g = DuplicateGroup(result: r, originalIndex: r.recommendedIndex)
            g.markedForDeletion = autoMarks(r)
            return g
        }
        if rule != .recommended { applyRuleToAll() }
        recountFolders()
        let review = groups.filter { $0.result.manualReview }.count
        statusMessage = "Scanned \(report.stats.valid) images in \(Fmt.duration(seconds)) · \(groups.count) groups"
            + (review > 0 ? " (\(review) need review)" : "")
            + " · \(Fmt.bytes(markedBytes)) can be freed"
            + (report.stats.cacheHits > 0 ? " · \(report.stats.cacheHits) unchanged images reused from cache" : "")
    }

    // MARK: Results helpers

    var visibleGroups: [DuplicateGroup] {
        groups.filter { g in
            switch filter {
            case .all: break
            case .review:
                if !(g.result.manualReview || g.members.contains { $0.label == .possible }) { return false }
            case .confirmed:
                if g.result.manualReview || !g.members.contains(where: { $0.label.isConfirmedDuplicate }) { return false }
            case .crossFolder:
                if g.result.scope == .sameFolder { return false }
            }
            if searchText.isEmpty { return true }
            return g.imageIndices.contains { images[$0].path.localizedCaseInsensitiveContains(searchText) }
        }
    }

    func groups(inFolder folder: String) -> [DuplicateGroup] {
        visibleGroups.filter { g in g.imageIndices.contains { images[$0].folder == folder } }
    }

    var visibleFolders: [FolderSummary] {
        onlyFoldersWithDuplicates ? folderSummaries.filter { $0.duplicateCount > 0 } : folderSummaries
    }

    private func recountFolders() {
        var dup: [String: Int] = [:]
        var count: [String: Int] = [:]
        for img in images { count[img.folder, default: 0] += 1 }
        for g in groups {
            for i in g.imageIndices where i != g.originalIndex { dup[images[i].folder, default: 0] += 1 }
        }
        folderSummaries = folderSummaries.map { FolderSummary(path: $0.path, imageCount: count[$0.path] ?? 0, duplicateCount: dup[$0.path] ?? 0) }
    }

    // MARK: Choosing originals

    func applyRuleToAll() {
        for i in groups.indices {
            if rule == .recommended {
                relabel(at: i, original: nil)
            } else if let pick = rule.pick(groups[i].imageIndices, images: images, preferredFolder: preferredFolder) {
                relabel(at: i, original: pick)
            }
        }
        recountFolders()
    }

    func setOriginal(_ imageIndex: Int, in groupID: UUID) {
        if let i = groups.firstIndex(where: { $0.id == groupID }) { relabel(at: i, original: imageIndex); recountFolders() }
    }

    func resetToRecommended(_ groupID: UUID) {
        if let i = groups.firstIndex(where: { $0.id == groupID }) { relabel(at: i, original: nil); recountFolders() }
    }

    /// Re-describes every member relative to the chosen original and re-applies the safe pre-selection.
    private func relabel(at i: Int, original: Int?) {
        guard let R = relabeler else { return }
        let rec = groups[i].result.recommendedIndex
        let forced = (original == nil || original == rec) ? nil : original
        let r = R.buildGroup(groups[i].imageIndices, forcedOriginal: forced)
        groups[i].result = r
        groups[i].originalIndex = forced ?? r.recommendedIndex
        groups[i].markedForDeletion = autoMarks(r)
    }

    // MARK: Selection

    func toggleDelete(_ imageIndex: Int, in groupID: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }),
              imageIndex != groups[i].originalIndex else { return }      // the original can never be selected
        if groups[i].markedForDeletion.contains(imageIndex) {
            groups[i].markedForDeletion.remove(imageIndex)
        } else {
            groups[i].markedForDeletion.insert(imageIndex)
        }
    }

    func selectAllDuplicates(in groupID: UUID) {
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].markedForDeletion = Set(groups[i].imageIndices.filter { $0 != groups[i].originalIndex })
    }

    func clearSelection(in groupID: UUID) {
        if let i = groups.firstIndex(where: { $0.id == groupID }) { groups[i].markedForDeletion = [] }
    }

    /// Selects confirmed duplicates (exact / visual / edited, high confidence) located in `folder`.
    func selectConfirmed(inFolder folder: String) {
        for i in groups.indices {
            for m in groups[i].members where m.imageIndex != groups[i].originalIndex
                && images[m.imageIndex].folder == folder && m.label.isConfirmedDuplicate && m.confidence >= .high {
                groups[i].markedForDeletion.insert(m.imageIndex)
            }
        }
    }

    func clearSelection(inFolder folder: String) {
        for i in groups.indices {
            groups[i].markedForDeletion = groups[i].markedForDeletion.filter { images[$0].folder != folder }
        }
    }

    func selectAllConfirmed() {
        for i in groups.indices {
            for m in groups[i].members where m.imageIndex != groups[i].originalIndex
                && m.label.isConfirmedDuplicate && m.confidence >= .high {
                groups[i].markedForDeletion.insert(m.imageIndex)
            }
        }
    }

    func clearAllSelections() { for i in groups.indices { groups[i].markedForDeletion = [] } }

    // MARK: Actions (always confirmed first)

    private func markedFiles() -> [(url: URL, size: Int64, kept: URL?)] {
        var out: [(url: URL, size: Int64, kept: URL?)] = []
        for g in groups {
            let kept = images[g.originalIndex].url
            for i in g.markedForDeletion.sorted() where i != g.originalIndex {
                out.append((images[i].url, images[i].size, kept))
            }
        }
        return out
    }

    func requestQuarantine() {
        if blockedBySafeMode() { return }
        let f = markedFiles()
        guard !f.isEmpty else { return }
        pendingAction = PendingAction(kind: .quarantine, paths: f.map { $0.url.path }, totalBytes: f.reduce(0) { $0 + $1.size })
    }

    func requestTrash() {
        if blockedBySafeMode() { return }
        let f = markedFiles()
        guard !f.isEmpty else { return }
        pendingAction = PendingAction(kind: .trash, paths: f.map { $0.url.path }, totalBytes: f.reduce(0) { $0 + $1.size })
    }

    func requestPermanentDelete(_ ids: Set<UUID>) {
        if blockedBySafeMode() { return }
        let items = quarantineItems.filter { ids.contains($0.id) }
        guard !items.isEmpty else { return }
        pendingAction = PendingAction(kind: .deletePermanently, paths: items.map { $0.originalPath },
                                      totalBytes: items.reduce(0) { $0 + $1.size }, quarantineIDs: items.map { $0.id })
    }

    func perform(_ action: PendingAction) {
        pendingAction = nil
        if blockedBySafeMode() { return }
        switch action.kind {
        case .quarantine:
            let files = markedFiles()
            let (moved, failures) = quarantine.quarantine(files)
            quarantineItems = quarantine.items
            removeFromResults(Set(moved.map { $0.originalPath }))
            statusMessage = "Moved \(moved.count) files to quarantine (\(quarantine.root.path)). You can restore them any time."
            showFailures(failures)
        case .trash:
            trashFiles(markedFiles())
        case .deletePermanently:
            let (n, failures) = quarantine.deletePermanently(Set(action.quarantineIDs))
            quarantineItems = quarantine.items
            statusMessage = "Permanently deleted \(n) quarantined files."
            showFailures(failures)
        }
    }

    private func trashFiles(_ files: [(url: URL, size: Int64, kept: URL?)]) {
        var trashed = Set<String>()
        var log: [(URL, URL)] = []
        var failures: [String] = []
        for f in files {
            // Safety: never trash if the original has vanished meanwhile.
            if let kept = f.kept, !FileManager.default.fileExists(atPath: kept.path) {
                failures.append("\(f.url.path): original missing, skipped")
                continue
            }
            do {
                try FileManager.default.trashItem(at: f.url, resultingItemURL: nil)
                trashed.insert(f.url.path)
                if let kept = f.kept { log.append((f.url, kept)) }
            } catch {
                failures.append("\(f.url.path): \(error.localizedDescription)")
            }
        }
        removeFromResults(trashed)
        let logPath = writeTrashLog(log)
        statusMessage = "Moved \(trashed.count) files to Trash." + (logPath.map { " Log: \($0)" } ?? "")
        showFailures(failures)
    }

    private func showFailures(_ failures: [String]) {
        guard !failures.isEmpty else { return }
        let a = NSAlert()
        a.messageText = "\(failures.count) files could not be processed"
        a.informativeText = failures.prefix(8).joined(separator: "\n")
        a.runModal()
    }

    /// Drops moved files from the results and rebuilds the affected groups.
    private func removeFromResults(_ paths: Set<String>) {
        guard !paths.isEmpty else { return }
        var next: [DuplicateGroup] = []
        for g in groups {
            let remaining = g.imageIndices.filter { !paths.contains(images[$0].path) }
            if remaining.count == g.imageIndices.count { next.append(g); continue }
            guard remaining.count > 1, let R = relabeler else { continue }
            // Keep the user's own choice of original; otherwise let the engine recommend again.
            let forced: Int? = (g.isUserOverride && remaining.contains(g.originalIndex)) ? g.originalIndex : nil
            let r = R.buildGroup(remaining, forcedOriginal: forced)
            var ng = DuplicateGroup(result: r, originalIndex: forced ?? r.recommendedIndex)
            ng.markedForDeletion = g.markedForDeletion.filter { remaining.contains($0) }
            next.append(ng)
        }
        groups = next
        var count: [String: Int] = [:]
        for img in images where !paths.contains(img.path) { count[img.folder, default: 0] += 1 }
        recountFolders()
        folderSummaries = folderSummaries.map { FolderSummary(path: $0.path, imageCount: count[$0.path] ?? 0, duplicateCount: $0.duplicateCount) }
    }

    /// Writes ~/Library/Logs/DupeSweep/trash-<date>.csv so you always know what was removed and which copy was kept.
    private func writeTrashLog(_ rows: [(URL, URL)]) -> String? {
        guard !rows.isEmpty else { return nil }
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/DupeSweep", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let file = dir.appendingPathComponent("trash-\(stamp).csv")
        var lines = ["trashed_path,kept_original_path"]
        lines += rows.map { csv($0.0.path) + "," + csv($0.1.path) }
        do {
            try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
            return file.path
        } catch { return nil }
    }

    // MARK: Quarantine manager

    func restore(_ ids: Set<UUID>) {
        let (restored, failures) = quarantine.restore(ids)
        quarantineItems = quarantine.items
        statusMessage = "Restored \(restored.count) files to their original folders."
        showFailures(failures)
    }

    func chooseQuarantineFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Use for Quarantine"
        if panel.runModal() == .OK, let u = panel.url {
            quarantine.setRoot(u)
            quarantineItems = quarantine.items
        }
    }

    func revealQuarantine() {
        try? FileManager.default.createDirectory(at: quarantine.root, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([quarantine.root])
    }

    // MARK: Export

    func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "DupeSweep-report.csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let iso = ISO8601DateFormatter()
        var lines = ["group,group_status,scope,label,action,confidence,similarity_pct,detection_method,notes,"
            + "filename,folder,path,format,width,height,size_bytes,modified,kept_original_path"]
        for (n, g) in groups.enumerated() {
            let status = g.result.manualReview ? "MANUAL REVIEW: " + (g.result.reviewReason ?? "") : "OK"
            let kept = images[g.originalIndex].path
            for m in g.members {
                let img = images[m.imageIndex]
                let action = m.imageIndex == g.originalIndex ? "KEEP (original)"
                    : (g.markedForDeletion.contains(m.imageIndex) ? "SELECTED FOR REMOVAL" : "KEEP")
                lines.append([
                    String(n + 1), status, g.result.scope.rawValue, m.label.rawValue, action, m.confidence.title,
                    String(Int((m.similarity * 100).rounded())), m.method, m.notes.joined(separator: "; "),
                    img.name, img.folder, img.path, img.meta.format, String(img.meta.pixelWidth), String(img.meta.pixelHeight),
                    String(img.size), img.modified.map { iso.string(from: $0) } ?? "", kept,
                ].map { csv($0) }.joined(separator: ","))
            }
        }
        do {
            // UTF-8 BOM so Excel opens non-English paths correctly.
            var data = Data([0xEF, 0xBB, 0xBF])
            data.append(Data(lines.joined(separator: "\r\n").utf8))
            try data.write(to: url, options: .atomic)
            statusMessage = "Report saved to \(url.path)"
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    private func csv(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
}
