import CoreGraphics
import Foundation

/// Owner: control. 8-bit luminance buffer (row 0 = top) plus the small image-processing helpers the pointer
/// locator needs: integral-image box means and connected components.
struct PointerGrayImage {
    let width: Int
    let height: Int
    var pixels: [UInt8]

    init(width: Int, height: Int, pixels: [UInt8]) {
        self.width = width; self.height = height; self.pixels = pixels
    }

    /// Draws `image` into a grey context of exactly `width` x `height`.
    init?(_ image: CGImage, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: width * height)
        let ok: Bool = buf.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.setFillColor(gray: 1, alpha: 1)
            ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.init(width: width, height: height, pixels: buf)
    }

    /// Downscaled so the width is at most `maxWidth` (never upscaled).
    init?(_ image: CGImage, maxWidth: Int) {
        let w = min(image.width, maxWidth)
        guard image.width > 0 else { return nil }
        let h = max(1, Int((Double(image.height) * Double(w) / Double(image.width)).rounded()))
        self.init(image, width: w, height: h)
    }

    /// Half size (2x2 box average).
    func halved() -> PointerGrayImage? {
        let w = width / 2, h = height / 2
        guard w > 0, h > 0 else { return nil }
        var out = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                let i = 2 * y * width + 2 * x
                let s = Int(pixels[i]) + Int(pixels[i + 1]) + Int(pixels[i + width]) + Int(pixels[i + width + 1])
                out[y * w + x] = UInt8(s / 4)
            }
        }
        return PointerGrayImage(width: w, height: h, pixels: out)
    }

    @inline(__always) func at(_ x: Int, _ y: Int) -> Int { Int(pixels[y * width + x]) }
}

/// 8-bit RGBX buffer (row 0 = top), for colour checks and per-channel detection.
struct PointerRGBImage {
    let width: Int
    let height: Int
    let pixels: [UInt8]   // 4 bytes per pixel

    init?(_ image: CGImage, width: Int, height: Int) {
        guard width > 0, height > 0 else { return nil }
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }
        self.width = width; self.height = height; pixels = rgba
    }

    /// One colour channel (0 = red, 1 = green, 2 = blue) as a grey image.
    func channel(_ c: Int) -> PointerGrayImage {
        var out = [UInt8](repeating: 0, count: width * height)
        pixels.withUnsafeBufferPointer { src in
            for i in 0..<(width * height) { out[i] = src[i * 4 + c] }
        }
        return PointerGrayImage(width: width, height: height, pixels: out)
    }

    /// Mean chroma (max - min of R, G, B; 0 = neutral grey) inside the circle of radius `r` around (x, y).
    func meanChroma(x: Double, y: Double, radius r: Double) -> Double {
        let x0 = max(0, Int(x - r)), x1 = min(width - 1, Int(x + r)), y0 = max(0, Int(y - r)), y1 = min(height - 1, Int(y + r))
        guard x0 <= x1, y0 <= y1 else { return 0 }
        var sum = 0, n = 0
        for yy in y0...y1 {
            for xx in x0...x1 {
                let dx = Double(xx) - x, dy = Double(yy) - y
                guard dx * dx + dy * dy <= r * r else { continue }
                let i = (yy * width + xx) * 4
                let a = Int(pixels[i]), b = Int(pixels[i + 1]), c = Int(pixels[i + 2])
                sum += max(a, b, c) - min(a, b, c); n += 1
            }
        }
        return n > 0 ? Double(sum) / Double(n) : 0
    }
}

/// Summed-area table for O(1) box means.
struct PointerIntegralImage {
    let width: Int
    let height: Int
    /// (width+1) x (height+1)
    let sums: [Int64]

    init(_ g: PointerGrayImage) {
        width = g.width; height = g.height
        let stride = width + 1
        var s = [Int64](repeating: 0, count: stride * (height + 1))
        for y in 0..<height {
            var row: Int64 = 0
            for x in 0..<width {
                row += Int64(g.pixels[y * width + x])
                s[(y + 1) * stride + x + 1] = s[y * stride + x + 1] + row
            }
        }
        sums = s
    }

    /// Mean over the box centred at (x, y) with the given radius, clipped to the image.
    func mean(x: Int, y: Int, radius r: Int) -> Double {
        let x0 = max(0, x - r), y0 = max(0, y - r), x1 = min(width, x + r + 1), y1 = min(height, y + r + 1)
        let area = (x1 - x0) * (y1 - y0)
        guard area > 0 else { return 0 }
        let st = width + 1
        let total = sums[y1 * st + x1] - sums[y0 * st + x1] - sums[y1 * st + x0] + sums[y0 * st + x0]
        return Double(total) / Double(area)
    }
}

struct PointerBlob {
    var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
    var area = 0
    var sumX = 0.0, sumY = 0.0, sumW = 0.0
    var sumV = 0.0, sumV2 = 0.0

    var bboxWidth: Int { maxX - minX + 1 }
    var bboxHeight: Int { maxY - minY + 1 }
    var diameter: Double { Double(bboxWidth + bboxHeight) / 2 }
    var aspect: Double { Double(bboxWidth) / Double(max(1, bboxHeight)) }
    /// Fraction of the bounding box covered; a filled disc is pi/4 ~= 0.785.
    var fill: Double { Double(area) / Double(max(1, bboxWidth * bboxHeight)) }
    var center: CGPoint { sumW > 0 ? CGPoint(x: sumX / sumW, y: sumY / sumW) : CGPoint(x: Double(minX + maxX) / 2, y: Double(minY + maxY) / 2) }
    var meanValue: Double { area > 0 ? sumV / Double(area) : 0 }
    var stdValue: Double { area > 0 ? sqrt(max(0, sumV2 / Double(area) - meanValue * meanValue)) : 0 }

    /// Pixels inside the ellipse inscribed in the bounding box (set by `PointerComponents.find`).
    var insideEllipse = 0

    /// Intersection-over-union of the blob with the ellipse inscribed in its bounding box: ~0.95 for a disc,
    /// ~0.8 for a rounded square, much less for rings, corners and strokes.
    var ellipseIoU: Double {
        let ellipseArea = Double.pi / 4 * Double(bboxWidth * bboxHeight)
        let union = Double(area) + ellipseArea - Double(insideEllipse)
        return union > 0 ? Double(insideEllipse) / union : 0
    }

    /// 0...1: how much this looks like a filled round dot.
    var roundness: Double {
        let circle = max(0, min(1, (ellipseIoU - 0.78) / 0.15))
        let aspectScore = max(0, 1 - abs(log(aspect)) / 0.5)
        return circle * aspectScore
    }
}
enum PointerComponents {
    /// 4-connected components of `mask` (non-zero = set) inside `rect`. `weight` (same size) weights the centroid;
    /// `value` is the image whose mean/std inside each blob is recorded. Blobs larger than `maxArea` are dropped
    /// early (they are backgrounds, bars, the AssistiveTouch button...).
    static func find(mask: [UInt8], width: Int, height: Int, in rect: (x0: Int, y0: Int, x1: Int, y1: Int),
                     weight: [Float]? = nil, value: PointerGrayImage? = nil, minArea: Int, maxArea: Int) -> [PointerBlob] {
        var visited = [Bool](repeating: false, count: width * height)
        var blobs: [PointerBlob] = []
        var stack: [Int] = []
        let x0 = max(0, rect.x0), y0 = max(0, rect.y0), x1 = min(width, rect.x1), y1 = min(height, rect.y1)
        guard x0 < x1, y0 < y1 else { return [] }
        for sy in y0..<y1 {
            for sx in x0..<x1 {
                let si = sy * width + sx
                if mask[si] == 0 || visited[si] { continue }
                var b = PointerBlob(); var overflow = false
                var members: [Int] = []
                visited[si] = true; stack.append(si)
                while let i = stack.popLast() {
                    let x = i % width, y = i / width
                    if !overflow {
                        b.area += 1
                        members.append(i)
                        if b.area > maxArea { overflow = true }
                        b.minX = min(b.minX, x); b.maxX = max(b.maxX, x); b.minY = min(b.minY, y); b.maxY = max(b.maxY, y)
                        let w = Double(weight?[i] ?? 1)
                        b.sumX += Double(x) * w; b.sumY += Double(y) * w; b.sumW += w
                        if let v = value { let p = Double(v.pixels[i]); b.sumV += p; b.sumV2 += p * p }
                    }
                    if x > x0, mask[i - 1] != 0, !visited[i - 1] { visited[i - 1] = true; stack.append(i - 1) }
                    if x + 1 < x1, mask[i + 1] != 0, !visited[i + 1] { visited[i + 1] = true; stack.append(i + 1) }
                    if y > y0, mask[i - width] != 0, !visited[i - width] { visited[i - width] = true; stack.append(i - width) }
                    if y + 1 < y1, mask[i + width] != 0, !visited[i + width] { visited[i + width] = true; stack.append(i + width) }
                }
                if !overflow && b.area >= minArea {
                    let cx = Double(b.minX + b.maxX) / 2, cy = Double(b.minY + b.maxY) / 2
                    let rx = Double(b.bboxWidth) / 2, ry = Double(b.bboxHeight) / 2
                    for i in members {
                        let dx = (Double(i % width) - cx) / rx, dy = (Double(i / width) - cy) / ry
                        if dx * dx + dy * dy <= 1 { b.insideEllipse += 1 }
                    }
                    blobs.append(b)
                }
            }
        }
        return blobs
    }
}

enum PointerMorphology {
    /// Binary opening (erode then dilate) with a (2r+1)^2 square, via a summed-area table of the mask.
    static func open(_ mask: [UInt8], width w: Int, height h: Int, radius r: Int) -> [UInt8] {
        guard r > 0 else { return mask }
        return filter(filter(mask, w, h, r, erode: true), w, h, r, erode: false)
    }

    private static func filter(_ m: [UInt8], _ w: Int, _ h: Int, _ r: Int, erode: Bool) -> [UInt8] {
        let st = w + 1
        var s = [Int32](repeating: 0, count: st * (h + 1))
        var out = [UInt8](repeating: 0, count: w * h)
        let full = (2 * r + 1) * (2 * r + 1)
        m.withUnsafeBufferPointer { M in
            s.withUnsafeMutableBufferPointer { S in
                for y in 0..<h {
                    var row: Int32 = 0
                    for x in 0..<w {
                        row &+= M[y * w + x] != 0 ? 1 : 0
                        S[(y + 1) * st + x + 1] = S[y * st + x + 1] &+ row
                    }
                }
                out.withUnsafeMutableBufferPointer { O in
                    for y in 0..<h {
                        let y0 = max(0, y - r), y1 = min(h, y + r + 1)
                        for x in 0..<w {
                            let x0 = max(0, x - r), x1 = min(w, x + r + 1)
                            let c = Int(S[y1 * st + x1] - S[y0 * st + x1] - S[y1 * st + x0] + S[y0 * st + x0])
                            if erode {
                                // Outside the image counts as "set" so dots at the edge survive.
                                if c + (full - (x1 - x0) * (y1 - y0)) == full { O[y * w + x] = 1 }
                            } else if c > 0 {
                                O[y * w + x] = 1
                            }
                        }
                    }
                }
            }
        }
        return out
    }
}
