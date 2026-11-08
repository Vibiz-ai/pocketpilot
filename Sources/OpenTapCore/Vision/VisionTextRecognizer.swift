import CoreGraphics
import Foundation
import Vision

/// Owner: capture. VNRecognizeTextRequest (.accurate) -> RecognizedText in the input image's pixel space, top-left origin.
public final class VisionTextRecognizer: TextRecognizer {
    public init() {}
    public func recognize(in image: CGImage) async throws -> [RecognizedText] {
        throw OpenTapError.notImplemented("Text recognition", module: "Vision")
    }
}
