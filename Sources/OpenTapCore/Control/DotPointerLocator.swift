import CoreGraphics
import Foundation

/// Owner: control. Finds the round grey AssistiveTouch pointer dot.
public final class DotPointerLocator: PointerLocator {
    public init() {}
    public func locate(in image: CGImage, hint: CGPoint?, previous: CGImage?) -> PointerDetection? { nil }
}
