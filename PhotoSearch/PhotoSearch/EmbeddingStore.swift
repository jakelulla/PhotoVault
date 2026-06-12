import CoreGraphics
import Foundation

// MARK: - Little-endian Data helpers

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }
}

/// Sequential reader over a Data buffer. Returns nil past the end rather than
/// trapping, so a truncated file (e.g. interrupted write) degrades gracefully.
private struct DataCursor {
    let data: Data
    var offset: Int

    init(_ data: Data) { self.data = data; offset = data.startIndex }

    mutating func readLE<T: FixedWidthInteger>(_ type: T.Type) -> T? {
        let size = MemoryLayout<T>.size
        guard offset + size <= data.endIndex else { return nil }
        var v: T = 0
        _ = withUnsafeMutableBytes(of: &v) { data.copyBytes(to: $0, from: offset..<offset + size) }
        offset += size
        return T(littleEndian: v)
    }

    mutating func readBytes(_ count: Int) -> Data? {
        guard count >= 0, offset + count <= data.endIndex else { return nil }
        defer { offset += count }
        return data.subdata(in: offset..<offset + count)
    }

    mutating func readFloats(_ count: Int) -> [Float]? {
        guard let raw = readBytes(count * 4) else { return nil }
        return raw.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }

    mutating func readDoubles(_ count: Int) -> [Double]? {
        guard let raw = readBytes(count * 8) else { return nil }
        return raw.withUnsafeBytes { Array($0.bindMemory(to: Double.self)) }
    }
}

// MARK: - Binary embedding map codec

/// Flat binary serialization for `[String: [Float]]` embedding maps.
/// Replaces JSON, which at tens of thousands of 512-dim vectors meant
/// 100MB+ text encodes on every persist and a slow parse on every launch.
///
/// Format (little-endian):
///   [UInt32 magic][UInt32 entryCount]
///   per entry: [UInt16 keyLen][key UTF-8][UInt32 floatCount][floats]
enum BinaryEmbeddingCodec {
    private static let magic: UInt32 = 0x5053_4531  // "PSE1"

    static func encode(_ dict: [String: [Float]]) -> Data {
        var data = Data()
        data.reserveCapacity(16 + dict.count * (64 + 512 * 4))
        data.appendLE(magic)
        data.appendLE(UInt32(dict.count))
        for (key, values) in dict {
            let kb = Data(key.utf8)
            data.appendLE(UInt16(kb.count))
            data.append(kb)
            data.appendLE(UInt32(values.count))
            values.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        }
        return data
    }

    static func decode(_ data: Data) -> [String: [Float]]? {
        var cur = DataCursor(data)
        guard cur.readLE(UInt32.self) == magic,
              let count = cur.readLE(UInt32.self) else { return nil }
        var dict = [String: [Float]](minimumCapacity: Int(count))
        for _ in 0..<count {
            guard let keyLen = cur.readLE(UInt16.self),
                  let keyData = cur.readBytes(Int(keyLen)),
                  let key = String(data: keyData, encoding: .utf8),
                  let floatCount = cur.readLE(UInt32.self),
                  let values = cur.readFloats(Int(floatCount)) else { return nil }
            dict[key] = values
        }
        return dict
    }
}

// MARK: - Face embedding log

/// One indexed photo's faces: per-face ArcFace embedding + normalized rect.
struct FaceRecord {
    let assetID: String
    let faces: [(embedding: [Float], rect: [Double])]
}

/// Append-only binary log of per-photo face embeddings, kept on disk only —
/// it is read in a single pass for global re-clustering and never held
/// resident (tens of MB at large libraries).
///
/// Record format (little-endian):
///   [UInt16 keyLen][assetID UTF-8][UInt16 faceCount]
///   per face: [UInt32 dim][dim floats][4 Float64 rect x,y,w,h]
///
/// The reader stops at the first malformed record, so a write truncated by
/// a crash loses at most the tail.
final class FaceEmbeddingLog: @unchecked Sendable {
    private let url: URL

    init(url: URL) { self.url = url }

    func append(assetID: String, embeddings: [[Float]], rects: [CGRect]) {
        guard !embeddings.isEmpty else { return }
        var record = Data()
        let kb = Data(assetID.utf8)
        record.appendLE(UInt16(kb.count))
        record.append(kb)
        record.appendLE(UInt16(embeddings.count))
        for (i, emb) in embeddings.enumerated() {
            record.appendLE(UInt32(emb.count))
            emb.withUnsafeBufferPointer { record.append(Data(buffer: $0)) }
            let r = i < rects.count ? rects[i] : .zero
            var rect: [Double] = [r.minX, r.minY, r.width, r.height]
            rect.withUnsafeBufferPointer { record.append(Data(buffer: $0)) }
        }

        if !FileManager.default.fileExists(atPath: url.path) {
            try? record.write(to: url)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: record)
    }

    func readAll() -> [FaceRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        var cur = DataCursor(data)
        var records: [FaceRecord] = []
        while true {
            guard let keyLen = cur.readLE(UInt16.self),
                  let keyData = cur.readBytes(Int(keyLen)),
                  let assetID = String(data: keyData, encoding: .utf8),
                  let faceCount = cur.readLE(UInt16.self) else { break }
            var faces: [(embedding: [Float], rect: [Double])] = []
            var ok = true
            for _ in 0..<faceCount {
                guard let dim = cur.readLE(UInt32.self),
                      let emb = cur.readFloats(Int(dim)),
                      let rect = cur.readDoubles(4) else { ok = false; break }
                faces.append((embedding: emb, rect: rect))
            }
            guard ok else { break }
            records.append(FaceRecord(assetID: assetID, faces: faces))
        }
        return records
    }

    func reset() {
        try? FileManager.default.removeItem(at: url)
    }
}
