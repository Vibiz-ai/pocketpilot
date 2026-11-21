import CoreGraphics
import Foundation

/// One recognized line/word. Coordinates are pixels in the image passed to `recognize`,
/// origin top-left. (x, y) is the centre of the text's bounding box.
public struct RecognizedText: Codable, Equatable, Sendable {
    public var text: String
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double
    public var confidence: Double

    public init(text: String, x: Double, y: Double, width: Double, height: Double, confidence: Double) {
        self.text = text; self.x = x; self.y = y; self.width = width; self.height = height; self.confidence = confidence
    }
}

/// OCR. Implemented by Vision/ (VNRecognizeTextRequest, accurate) and Mock/.
public protocol TextRecognizer: AnyObject {
    func recognize(in image: CGImage) async throws -> [RecognizedText]
}

public extension Array where Element == RecognizedText {
    /// Case-insensitive match: exact matches first, then "contains", in reading order (top-to-bottom, left-to-right).
    /// `occurrence` is 1-based.
    func find(_ query: String, occurrence: Int = 1) -> RecognizedText? {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty, occurrence >= 1 else { return nil }
        let ordered = sorted { abs($0.y - $1.y) > 8 ? $0.y < $1.y : $0.x < $1.x }
        let exact = ordered.filter { $0.text.lowercased() == q }
        let partial = ordered.filter { $0.text.lowercased() != q && $0.text.lowercased().contains(q) }
        let all = exact + partial
        return occurrence <= all.count ? all[occurrence - 1] : nil
    }
}
