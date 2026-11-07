// SPDX-License-Identifier: MIT
import Foundation

final class TestTrace: @unchecked Sendable {
    private let queue = DispatchQueue(label: "Reprojection trace", qos: .utility)
    private let file: FileHandle
    private var pending = Data()
    private var lastFlush = ProcessInfo.processInfo.systemUptime
    let sessionID = UUID().uuidString
    init() throws {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("reprojection-latest.jsonl")
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.moveItem(at: url, to: docs.appendingPathComponent("reprojection-\(UUID().uuidString).jsonl"))
        }
        FileManager.default.createFile(atPath: url.path, contents: nil)
        file = try FileHandle(forWritingTo: url)
    }
    func event(_ name: String, _ fields: [String: Any] = [:]) {
        let wall = Date().timeIntervalSince1970
        let uptime = ProcessInfo.processInfo.systemUptime
        queue.async {
            var row = fields
            row["event"] = name; row["unix_s"] = wall; row["uptime_s"] = uptime; row["session"] = self.sessionID
            guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
            self.pending.append(data); self.pending.append(10)
            if uptime - self.lastFlush >= 1 || self.pending.count >= 65536 {
                self.file.write(self.pending); self.pending.removeAll(keepingCapacity: true); self.lastFlush = uptime
            }
        }
    }
    func flush() {
        queue.sync { file.write(pending); pending.removeAll(keepingCapacity: true) }
    }
    deinit { try? file.close() }
}

final class CompletionCounts: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: (count: Int, missed: Int, failed: Int, gpuMS: Double)] = [:]
    func add(key: String, gpuMS: Double, late: Bool, failed: Bool) {
        lock.lock(); defer { lock.unlock() }
        var e = entries[key] ?? (0,0,0,0)
        e.count += 1; e.missed += late ? 1 : 0; e.failed += failed ? 1 : 0; e.gpuMS += max(0,gpuMS)
        entries[key] = e
    }
    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return entries.mapValues { e in
            ["completed": Double(e.count), "gpu_deadline_exceedances": Double(e.missed),
             "failed": Double(e.failed), "gpu_span_ms_mean": e.count > 0 ? e.gpuMS/Double(e.count) : 0]
        }
    }
}
