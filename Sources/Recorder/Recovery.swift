import Foundation

/// Disk space and crash recovery for takes.
enum DiskSpace {
    static func free(at url: URL) -> Int64 {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 { probe.deleteLastPathComponent() }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey])
        return values?.volumeAvailableCapacityForImportantUsage ?? Int64(values?.volumeAvailableCapacity ?? 0)
    }
    /// 48 kHz × 3 bytes (24-bit) per channel.
    static func bytesPerSecond(channels: Int) -> Int64 { Int64(Formats.rate) * 3 * Int64(channels) }
    static let reserve: Int64 = 300_000_000           // never fill the disk past this
    static let stopBelow: Int64 = 150_000_000         // stop a take below this
}

/// What's being recorded right now, written next to project.json so a crash can be undone.
struct PendingRecording: Codable {
    struct Take: Codable { var trackID: UUID; var file: String; var start: Double }
    var takes: [Take]
    static let fileName = "recording-in-progress.json"
}

enum WAVRepair {
    /// A WAV whose writer died never gets its sizes filled in. Sets the RIFF and data chunk
    /// sizes from the file's real length. Returns false if it isn't a WAV it understands.
    @discardableResult
    static func repair(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forUpdating: url) else { return false }
        defer { try? handle.close() }
        guard let fileSize = try? handle.seekToEnd(), fileSize > 44 else { return false }
        try? handle.seek(toOffset: 0)
        guard let head = try? handle.read(upToCount: 4096), head.count >= 12,
              head.prefix(4) == Data("RIFF".utf8), head[8..<12] == Data("WAVE".utf8) else { return false }
        func u32(_ o: Int) -> UInt32 { head[o..<o + 4].withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) } }
        func u16(_ o: Int) -> UInt16 { head[o..<o + 2].withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) } }
        var offset = 12, blockAlign: UInt64 = 1
        while offset + 8 <= head.count {
            let id = String(decoding: head[offset..<offset + 4], as: UTF8.self)
            let size = Int(u32(offset + 4))
            if id == "fmt ", offset + 22 <= head.count { blockAlign = UInt64(max(1, u16(offset + 20))) }
            if id == "data" {
                let dataStart = UInt64(offset + 8)
                var dataSize = fileSize - dataStart
                dataSize -= dataSize % blockAlign
                var d = UInt32(min(dataSize, UInt64(UInt32.max))).littleEndian
                var r = UInt32(min(fileSize - 8, UInt64(UInt32.max))).littleEndian
                try? handle.seek(toOffset: UInt64(offset + 4)); handle.write(Data(bytes: &d, count: 4))
                try? handle.seek(toOffset: 4); handle.write(Data(bytes: &r, count: 4))
                return true
            }
            offset += 8 + size + (size & 1)
        }
        return false
    }
}
