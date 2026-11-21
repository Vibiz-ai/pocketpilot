import CoreGraphics
import Foundation
import Vision

/// Owner: capture. VNRecognizeTextRequest (.accurate) -> RecognizedText in the input image's pixel space, top-left origin.
///
/// Results are sorted in reading order (top-to-bottom, then left-to-right for items on the same line),
/// matching `[RecognizedText].find`. Vision runs fully on-device; no network is used.
public final class VisionTextRecognizer: TextRecognizer {
    public enum Granularity: Sendable {
        /// One item per recognized line (what Vision returns natively).
        case lines
        /// One item per whitespace-separated word, each with its own box, so a tap on a word in a wide line lands on it.
        case words
    }

    public var granularity: Granularity
    public var languages: [String]
    public var usesLanguageCorrection: Bool
    /// Items below this confidence (0...1) are dropped.
    public var minimumConfidence: Double

    public init(granularity: Granularity = .lines, languages: [String] = ["en-US"],
                usesLanguageCorrection: Bool = true, minimumConfidence: Double = 0.3) {
        self.granularity = granularity; self.languages = languages
        self.usesLanguageCorrection = usesLanguageCorrection; self.minimumConfidence = minimumConfidence
    }

    public func recognize(in image: CGImage) async throws -> [RecognizedText] {
        guard image.width > 0, image.height > 0 else { return [] }
        let granularity = granularity, languages = languages
        let correction = usesLanguageCorrection, minConf = minimumConfidence
        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let request = VNRecognizeTextRequest()
                    request.recognitionLevel = .accurate
                    request.usesLanguageCorrection = correction
                    if !languages.isEmpty { request.recognitionLanguages = languages }
                    let handler = VNImageRequestHandler(cgImage: image, orientation: .up, options: [:])
                    try handler.perform([request])
                    let observations = request.results ?? []
                    let size = CGSize(width: image.width, height: image.height)
                    var items: [RecognizedText] = []
                    for obs in observations {
                        guard let cand = obs.topCandidates(1).first, Double(cand.confidence) >= minConf else { continue }
                        let text = cand.string.trimmingCharacters(in: .whitespacesAndNewlines)
                        guard !text.isEmpty else { continue }
                        if granularity == .words, let words = Self.words(in: cand, imageSize: size), words.count > 1 {
                            items.append(contentsOf: words)
                        } else {
                            items.append(Self.item(text, box: obs.boundingBox, confidence: Double(cand.confidence), imageSize: size))
                        }
                    }
                    cont.resume(returning: Self.readingOrder(items))
                } catch {
                    cont.resume(throwing: PocketPilotError(.internalError, what: "Couldn't read the text on the iPhone screen",
                                                       why: "Vision text recognition failed: \(error.localizedDescription)",
                                                       fix: "Try again; screenshots still work without text (include_text: false)"))
                }
            }
        }
    }

    // MARK: - Geometry helpers (public for tests / other modules)

    /// Converts a Vision normalized rect (origin bottom-left, 0...1) to a pixel rect with top-left origin.
    public static func pixelRect(fromNormalized r: CGRect, imageSize: CGSize) -> CGRect {
        CGRect(x: r.minX * imageSize.width,
               y: (1 - r.maxY) * imageSize.height,
               width: r.width * imageSize.width,
               height: r.height * imageSize.height)
    }

    static func item(_ text: String, box: CGRect, confidence: Double, imageSize: CGSize) -> RecognizedText {
        let r = pixelRect(fromNormalized: box, imageSize: imageSize)
        return RecognizedText(text: text, x: Double(r.midX), y: Double(r.midY),
                              width: Double(r.width), height: Double(r.height), confidence: confidence)
    }

    private static func words(in cand: VNRecognizedText, imageSize: CGSize) -> [RecognizedText]? {
        let s = cand.string
        var out: [RecognizedText] = []
        var idx = s.startIndex
        while idx < s.endIndex {
            guard let start = s[idx...].firstIndex(where: { !$0.isWhitespace }) else { break }
            let end = s[start...].firstIndex(where: { $0.isWhitespace }) ?? s.endIndex
            guard let box = try? cand.boundingBox(for: start..<end)?.boundingBox else { return nil }
            out.append(item(String(s[start..<end]), box: box, confidence: Double(cand.confidence), imageSize: imageSize))
            idx = end
        }
        return out
    }

    /// Top-to-bottom; items whose centres are within half a line height of each other count as one row, left-to-right.
    public static func readingOrder(_ items: [RecognizedText]) -> [RecognizedText] {
        let byY = items.sorted { $0.y < $1.y }
        var rows: [[RecognizedText]] = []
        for it in byY {
            if let last = rows.last?.last {
                let tol = max(4, min(last.height, it.height) / 2)
                if abs(it.y - (rows.last!.map(\.y).reduce(0, +) / Double(rows.last!.count))) <= tol {
                    rows[rows.count - 1].append(it); continue
                }
            }
            rows.append([it])
        }
        return rows.flatMap { $0.sorted { $0.x < $1.x } }
    }
}
