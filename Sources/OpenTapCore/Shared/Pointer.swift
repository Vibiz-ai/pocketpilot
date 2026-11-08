import CoreGraphics
import Foundation

public struct PointerDetection: Equatable, Sendable {
    /// Centre of the pointer dot, pixels in the image given to `locate`, origin top-left.
    public var point: CGPoint
    /// 0...1
    public var confidence: Double
    public init(point: CGPoint, confidence: Double) { self.point = point; self.confidence = confidence }
}

/// Finds the AssistiveTouch pointer dot in a frame. Implemented by Control/ (and usable on Mock frames).
public protocol PointerLocator: AnyObject {
    /// `hint` = where the pointer probably is (search there first); `previous` = an earlier frame for differencing.
    func locate(in image: CGImage, hint: CGPoint?, previous: CGImage?) -> PointerDetection?
}
