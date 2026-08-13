import Foundation

/// CLIP BPE tokenizer — Swift port of open_clip's SimpleTokenizer.
/// Loads vocab.json + merges.txt from the bundle and produces the
/// (1, 77) token sequence the CLIPText encoder expects:
/// [SOT, tokens…, EOT, 0-padding].
final class CLIPTokenizer {
    static let contextLength = 77
    private let sotToken = 49406
    private let eotToken = 49407

    private let encoder: [String: Int]          // BPE token → id
    private let bpeRanks: [Pair: Int]           // merge pair → rank
    private let byteEncoder: [UInt8: Character] // byte → unicode char (GPT-2 byte encoding)
    private var cache: [String: [String]] = [:]

    private struct Pair: Hashable { let a: String; let b: String }

    convenience init?() {
        guard
            let vocabURL  = Bundle.main.url(forResource: "vocab",  withExtension: "json"),
            let mergesURL = Bundle.main.url(forResource: "merges", withExtension: "txt")
        else { return nil }
        self.init(vocabURL: vocabURL, mergesURL: mergesURL)
    }

    init?(vocabURL: URL, mergesURL: URL) {
        guard
            let vocabData = try? Data(contentsOf: vocabURL),
            let vocab     = try? JSONDecoder().decode([String: Int].self, from: vocabData),
            let mergesRaw = try? String(contentsOf: mergesURL, encoding: .utf8)
        else { return nil }

        encoder = vocab

        var ranks: [Pair: Int] = [:]
        // First line is the "#version" header; CLIP uses the first 48894 merges.
        let lines = mergesRaw.split(separator: "\n").dropFirst()
        for (i, line) in lines.enumerated() {
            let parts = line.split(separator: " ")
            guard parts.count == 2 else { continue }
            ranks[Pair(a: String(parts[0]), b: String(parts[1]))] = i
        }
        bpeRanks = ranks

        // GPT-2 bytes→unicode mapping (identical in CLIP): printable bytes map
        // to themselves; the rest map to 256+n in registration order.
        var be: [UInt8: Character] = [:]
        let printable: [Int] = Array(33...126) + Array(161...172) + Array(174...255)
        var extra = 0
        for b in 0...255 {
            if printable.contains(b) {
                be[UInt8(b)] = Character(UnicodeScalar(b)!)
            } else {
                be[UInt8(b)] = Character(UnicodeScalar(256 + extra)!)
                extra += 1
            }
        }
        byteEncoder = be
    }

    /// Tokenize a query into a fixed-length (77) id array.
    func encode(_ text: String) -> [Int32] {
        var bpeTokens: [Int] = []
        for word in words(from: text) {
            // Bytes→unicode, then BPE merge, then vocab lookup.
            let mapped = String(Array(word.utf8).compactMap { byteEncoder[$0] })
            for tok in bpe(mapped) {
                if let id = encoder[tok] { bpeTokens.append(id) }
            }
        }
        // SOT + tokens + EOT, truncated so EOT always fits, padded with 0.
        let maxBody = Self.contextLength - 2
        if bpeTokens.count > maxBody { bpeTokens = Array(bpeTokens.prefix(maxBody)) }
        var ids: [Int32] = [Int32(sotToken)]
        ids.append(contentsOf: bpeTokens.map(Int32.init))
        ids.append(Int32(eotToken))
        while ids.count < Self.contextLength { ids.append(0) }
        return ids
    }

    // MARK: - Pre-tokenization

    /// CLIP's regex: contractions | letter runs | digit runs | other-symbol runs,
    /// applied to lowercased, whitespace-collapsed text.
    private func words(from text: String) -> [String] {
        let cleaned = text
            .lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        // Note: digits match ONE AT A TIME ([\p{N}], not +) — matching CLIP's
        // reference pattern, where "100" → three separate tokens.
        let pattern = "'s|'t|'re|'ve|'m|'ll|'d|[\\p{L}]+|[\\p{N}]|[^\\s\\p{L}\\p{N}]+"
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [cleaned] }
        let ns = cleaned as NSString
        return re.matches(in: cleaned, range: NSRange(location: 0, length: ns.length))
            .map { ns.substring(with: $0.range) }
    }

    // MARK: - BPE

    /// CLIP's BPE: the word's last symbol gets the "</w>" end-of-word marker,
    /// then merge the lowest-ranked adjacent pair until none remain.
    private func bpe(_ token: String) -> [String] {
        if let hit = cache[token] { return hit }
        var word: [String] = token.map { String($0) }
        guard !word.isEmpty else { return [] }
        word[word.count - 1] += "</w>"

        while word.count > 1 {
            var best: (rank: Int, idx: Int)? = nil
            for i in 0..<(word.count - 1) {
                if let r = bpeRanks[Pair(a: word[i], b: word[i + 1])] {
                    if best == nil || r < best!.rank { best = (r, i) }
                }
            }
            guard let (_, i) = best else { break }
            word.replaceSubrange(i...(i + 1), with: [word[i] + word[i + 1]])
        }
        cache[token] = word
        return word
    }
}
