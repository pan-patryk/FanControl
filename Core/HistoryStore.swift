import Foundation

/// Append-only JSONL store for the 24 h temperature history.
///
/// Records go to `~/Library/Application Support/FanCurve/history.jsonl`, one line
/// each, with a version field so the format can change without silently mis-reading
/// old files.
///
/// A JSONL file rather than a `UserDefaults` array because the whole 24 h series must
/// not be re-encoded on every sample: a 30 s cadence over 2800 records is hundreds of
/// KB per write, and every launch would decode the lot again.
final class HistoryStore {
    private struct Line: Codable {
        var v: Int
        var r: TempRecord
    }
    private static let version = 1

    let url: URL
    private let queue = DispatchQueue(label: "com.local.fancurve.app.history")
    private var handle: FileHandle?

    static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("FanCurve", isDirectory: true)
    }

    /// Opens (creating if needed) the store. Returns `nil` only if the file cannot be
    /// written at all, in which case history simply stops recording.
    static func open() -> HistoryStore? {
        let fm = FileManager.default
        let dir = directory
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return nil
        }
        let store = HistoryStore(url: dir.appendingPathComponent("history.jsonl"))
        return store.openFile() ? store : nil
    }

    private init(url: URL) { self.url = url }

    /// The `FileHandle` methods without `throws` (`seekToEndOfFile`, `closeFile`,
    /// `synchronizeFile`, `writeData(_:)` — imported as the *non-throwing*
    /// `write(_:)`) are deprecated and documented as "raising an
    /// Objective-C exception on failure" — and Swift cannot catch those, so a full
    /// disk or a revoked permission would terminate the app from inside a
    /// thermal-monitoring loop. Everything here uses the throwing variants and turns
    /// a failure into "history recording is off for this write".
    private func openFile() -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = FileHandle(forWritingAtPath: url.path) else { return false }
        do { try handle.seekToEnd() } catch { try? handle.close(); return false }
        self.handle = handle
        return true
    }

    /// Read everything, dropping the version header and any unparsable line.
    func load() -> [TempRecord] {
        queue.sync { readLocked() }
    }

    private func readLocked() -> [TempRecord] {
        guard let data = try? Data(contentsOf: url), !data.isEmpty else { return [] }
        var records: [TempRecord] = []
        for raw in data.split(separator: 0x0A) {
            if let line = try? JSONDecoder().decode(Line.self, from: Data(raw)) {
                if line.v == Self.version { records.append(line.r) }
            } else if let unwrapped = try? JSONDecoder().decode(TempRecord.self, from: Data(raw)) {
                records.append(unwrapped)   // pre-version line: accept, then rewrite
            }
        }
        return records
    }

    func append(_ record: TempRecord) {
        guard let data = try? JSONEncoder().encode(Line(v: Self.version, r: record)) else { return }
        queue.async { [weak self] in
            guard let self, let handle = self.handle else { return }
            do {
                try handle.write(contentsOf: data)
                try handle.write(contentsOf: Data([0x0A]))
            } catch {
                // Disk full / read-only: stop hammering a handle that cannot write.
                self.failed = true
            }
        }
    }

    /// Full rewrite (used after pruning).
    func rewrite(_ records: [TempRecord]) {
        queue.async {
            var data = Data()
            for record in records {
                if let line = try? JSONEncoder().encode(Line(v: Self.version, r: record)) {
                    data.append(line)
                    data.append(Data([0x0A]))
                }
            }
            try? data.write(to: self.url, options: .atomic)
            self.reopenHandle()
        }
    }

    private func rewriteLocked(_ records: [TempRecord]) {
        var data = Data()
        for record in records {
            if let line = try? JSONEncoder().encode(Line(v: Self.version, r: record)) {
                data.append(line)
                data.append(Data([0x0A]))
            }
        }
        try? data.write(to: url, options: .atomic)
        reopenHandle()
    }

    /// Close the handle and re-open the rewritten file for appending.
    private func reopenHandle() {
        if let handle { try? handle.close() }
        handle = FileHandle(forWritingAtPath: url.path)
        if let handle {
            do { try handle.seekToEnd() } catch { self.handle = nil; self.failed = true }
        }
    }

    /// Flush to durable storage (called on sleep and before quit).
    func synchronize() {
        guard !failed else { return }
        queue.sync { try? self.handle?.synchronize() }
    }

    /// Set after a write fails; keeps a full disk from being retried once per poll.
    private var failed = false

    deinit { if let handle { try? handle.close() } }
}
