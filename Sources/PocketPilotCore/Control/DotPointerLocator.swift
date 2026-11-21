import CoreGraphics
import Foundation

/// Owner: control. Finds the round grey AssistiveTouch pointer dot.
///
/// Two detectors, both scale-free (sizes are fractions of the screen width):
/// 1. **Frame difference** (when `previous` is given, e.g. a frame from just before a small move):
///    the changed pixels form two blobs, the old and the new dot position. The new one is the blob whose
///    *current* pixels contrast with their surroundings (at the old spot the current frame shows plain background).
///    It is then refined to the full dot with detector 2 in a small window.
/// 2. **Blob detector**: pixels that differ from their local mean (darker or lighter, so light and dark mode
///    both work), grouped into connected blobs, scored on roundness, size, uniform fill and closeness to `hint`.
///
/// The large translucent AssistiveTouch button, text, bars and photos are rejected by size and shape.
public final class DotPointerLocator: PointerLocator {
    public struct Config: Sendable {
        /// Width the frame is downscaled to for detection.
        public var workingWidth: Int = 600
        /// Accepted dot diameter range, as a fraction of the screen width (pointer ~4.6%, the AssistiveTouch
        /// button ~15% and its inner disc ~9%).
        public var minDiameter: Double = 0.018
        public var maxDiameter: Double = 0.07
        public var expectedDiameter: Double = 0.046
        /// Grey-level contrast against the local background needed to count as "dot".
        public var contrastThreshold: Double = 22
        /// Grey-level change needed between frames to count as "changed".
        public var diffThreshold: Double = 18
        /// The pointer is neutral grey; blobs more colourful than this (mean max-min of RGB) are rejected.
        public var maxChroma: Double = 50
        public init() {}
    }

    public var config: Config
    public init(config: Config = Config()) { self.config = config }

    public func locate(in image: CGImage, hint: CGPoint?, previous: CGImage?) -> PointerDetection? {
        guard let cur = PointerGrayImage(image, maxWidth: config.workingWidth) else { return nil }
        let k = Double(cur.width) / Double(image.width)
        let hintW = hint.map { CGPoint(x: $0.x * k, y: $0.y * k) }
        let rgb = PointerRGBImage(image, width: cur.width, height: cur.height)
        let ctx = Context(cur: cur, config: config, rgb: rgb)

        var found: (CGPoint, Double)?
        if let previous, previous.width == image.width, previous.height == image.height,
           let prev = PointerGrayImage(previous, width: cur.width, height: cur.height) {
            found = ctx.diffDetect(prev: prev, hint: hintW)
        }
        if found == nil, let h = hintW {
            let r = Int(Double(cur.width) * 0.22)
            found = ctx.blobDetect(rect: (Int(h.x) - r, Int(h.y) - r, Int(h.x) + r + 1, Int(h.y) + r + 1), hint: h)
        }
        if found == nil { found = globalSearch(image, ctx: ctx, hint: hintW) }
        if found == nil {
            // Same brightness as what's under it (grey dot on a yellow icon): try the colour channels.
            for ch in [2, 0, 1] where found == nil {
                guard let g = rgb?.channel(ch) else { continue }
                let cctx = Context(cur: g, config: config, rgb: rgb)
                if let h = hintW {
                    let r = Int(Double(cur.width) * 0.22)
                    found = cctx.blobDetect(rect: (Int(h.x) - r, Int(h.y) - r, Int(h.x) + r + 1, Int(h.y) + r + 1), hint: h)
                }
                if found == nil { found = globalSearch(image, ctx: cctx, hint: hintW, coarse: g) }
                if let f = found { found = (f.0, f.1 * 0.9) }
            }
        }
        guard let (p, conf) = found else { return nil }
        return PointerDetection(point: CGPoint(x: (p.x + 0.5) / k, y: (p.y + 0.5) / k), confidence: min(1, max(0, conf)))
    }

    /// Whole-screen search on a half-resolution copy (4x cheaper), refined at working resolution.
    private func globalSearch(_ image: CGImage, ctx: Context, hint: CGPoint?, coarse source: PointerGrayImage? = nil) -> (CGPoint, Double)? {
        let cur = ctx.cur
        let coarseWidth = cur.width / 2, coarseHeight = max(1, cur.height / 2)
        let small = source.map { $0.halved() } ?? PointerGrayImage(image, width: coarseWidth, height: coarseHeight)
        guard coarseWidth >= 160, let small else {
            return ctx.blobDetect(rect: (0, 0, cur.width, cur.height), hint: hint)
        }
        let sx = Double(cur.width) / Double(small.width), sy = Double(cur.height) / Double(small.height)
        let coarse = Context(cur: small, config: config, rgb: ctx.rgb)
        let coarseHint = hint.map { CGPoint(x: $0.x / sx, y: $0.y / sy) }
        // Refine the few best coarse candidates at full working resolution and keep the best refined one.
        var best: (point: CGPoint, score: Double, confidence: Double)?
        for c in coarse.blobCandidates(rect: (0, 0, small.width, small.height), hint: coarseHint).prefix(6) {
            let p = CGPoint(x: (c.point.x + 0.5) * sx - 0.5, y: (c.point.y + 0.5) * sy - 0.5)
            let r = Int(ctx.maxD * 1.6)
            let refined = ctx.blobCandidates(rect: (Int(p.x) - r, Int(p.y) - r, Int(p.x) + r + 1, Int(p.y) + r + 1),
                                             hint: hint, near: p, nearRadius: ctx.maxD).first
            // A candidate that fails the full-resolution checks (shape, surround, rings) is dropped.
            guard let cand = refined else { continue }
            if best == nil || cand.score > best!.score { best = cand }
        }
        return best.map { ($0.point, $0.confidence) }
    }

    /// Per-call working state.
    private struct Context {
        let cur: PointerGrayImage
        let integral: PointerIntegralImage
        let minD, maxD, expD: Double
        let radius: Int
        let config: Config
        /// Colour image at working resolution (for the neutral-grey check), and its px per `cur` px.
        let rgb: PointerRGBImage?
        let rgbScale: Double

        init(cur: PointerGrayImage, config: Config, rgb: PointerRGBImage?) {
            self.cur = cur; self.config = config; self.rgb = rgb
            rgbScale = rgb.map { Double($0.width) / Double(cur.width) } ?? 1
            integral = PointerIntegralImage(cur)
            let w = Double(cur.width)
            minD = max(3, config.minDiameter * w); maxD = max(minD + 2, config.maxDiameter * w)
            expD = config.expectedDiameter * w
            radius = Int(maxD.rounded(.up))
        }

        func hintFactor(_ p: CGPoint, _ hint: CGPoint?) -> Double {
            guard let h = hint else { return 1 }
            let d = hypot(p.x - h.x, p.y - h.y)
            return 0.45 + 0.55 * exp(-d / (0.15 * Double(cur.width)))
        }

        func sizeScore(_ d: Double) -> Double { max(0, 1 - abs(d - expD) / (expD * 1.2)) }

        /// Blob detector inside `rect` (working px). Returns centre + confidence.
        func blobDetect(rect: (Int, Int, Int, Int), hint: CGPoint?, near: CGPoint? = nil, nearRadius: Double = 0) -> (CGPoint, Double)? {
            blobCandidates(rect: rect, hint: hint, near: near, nearRadius: nearRadius).first.map { ($0.point, $0.confidence) }
        }

        /// All dot-like blobs in `rect`, best first.
        func blobCandidates(rect: (Int, Int, Int, Int), hint: CGPoint?, near: CGPoint? = nil,
                            nearRadius: Double = 0) -> [(point: CGPoint, score: Double, confidence: Double)] {
            let w = cur.width, h = cur.height
            let x0 = max(0, rect.0), y0 = max(0, rect.1), x1 = min(w, rect.2), y1 = min(h, rect.3)
            guard x0 < x1, y0 < y1 else { return [] }
            // Work in window-sized buffers (local coordinates), offset back at the end.
            let rw = x1 - x0, rh = y1 - y0, n = rw * rh
            var signed = [Float](repeating: 0, count: n)
            var weight = [Float](repeating: 0, count: n)
            var crop = [UInt8](repeating: 0, count: n)
            let t = config.contrastThreshold
            let r = radius, st = w + 1
            cur.pixels.withUnsafeBufferPointer { px in
                integral.sums.withUnsafeBufferPointer { S in
                    for y in 0..<rh {
                        let gy = y + y0
                        let ya = max(0, gy - r), yb = min(h, gy + r + 1)
                        for x in 0..<rw {
                            let gx = x + x0
                            let xa = max(0, gx - r), xb = min(w, gx + r + 1)
                            let sum = S[yb * st + xb] - S[ya * st + xb] - S[yb * st + xa] + S[ya * st + xa]
                            let mean = Double(sum) / Double((xb - xa) * (yb - ya))
                            let i = y * rw + x
                            let v = px[gy * w + gx]
                            crop[i] = v
                            let c = Double(v) - mean
                            weight[i] = Float(abs(c))
                            signed[i] = Float(c)
                        }
                    }
                }
            }
            let local = PointerGrayImage(width: rw, height: rh, pixels: crop)
            let minArea = Int(0.5 * Double.pi / 4 * minD * minD)
            let maxArea = Int(1.2 * maxD * maxD)
            var found: [(point: CGPoint, score: Double, confidence: Double)] = []
            // Opening removes thin text strokes / separators so a dot sitting on text stays round.
            let open = max(1, Int((minD * 0.4).rounded()))
            // Several contrast levels (like MSER): at a higher level a dot that touches a fainter shape of the
            // same polarity separates from it.
            var masks: [[UInt8]] = []
            for level in [t, 2 * t, 3.5 * t] {
                let l = Float(level)
                masks.append(signed.map { $0 < -l ? 1 : 0 })
                masks.append(signed.map { $0 > l ? 1 : 0 })
            }
            for raw in masks {
                let mask = PointerMorphology.open(raw, width: rw, height: rh, radius: open)
                let blobs = PointerComponents.find(mask: mask, width: rw, height: rh, in: (0, 0, rw, rh),
                                                   weight: weight, value: local, minArea: minArea, maxArea: maxArea)
                for b in blobs {
                    let d = b.diameter
                    guard d >= minD, d <= maxD else { continue }
                    let round = b.roundness
                    guard round > 0.35 else { continue }
                    let lc = b.center
                    let c = CGPoint(x: lc.x + CGFloat(x0), y: lc.y + CGFloat(y0))
                    if let n = near, hypot(c.x - n.x, c.y - n.y) > nearRadius { continue }
                    guard surroundContrast(c, radius: d / 2, interior: b.meanValue) >= 0.75,
                          !isConcentric(c, radius: d / 2) else { continue }
                    if let rgb, rgb.meanChroma(x: (Double(c.x) + 0.5) * rgbScale - 0.5, y: (Double(c.y) + 0.5) * rgbScale - 0.5,
                                               radius: d / 2 * 0.6 * rgbScale) > config.maxChroma { continue }
                    // Re-measure the real outline from the pixel values (the contrast map blurs shapes).
                    guard let seg = segment(c, radius: d / 2) else { continue }
                    let d2 = seg.diameter
                    let round2 = max(0, min(1, (seg.iou - 0.8) / 0.12))
                    let uniform = max(0, 1 - b.stdValue / 45)
                    let base = 0.5 * min(round, round2) + 0.2 * uniform + 0.3 * sizeScore(d2)
                    let center = seg.center
                    guard base > 0.4 else { continue }
                    let score = base * hintFactor(center, hint)
                    found.append((center, score, 0.3 + 0.45 * base))
                }
            }
            return found.sorted { $0.score > $1.score }
        }

        /// Grey value at a point (working px), nil outside the image.
        func sample(_ x: Double, _ y: Double) -> Double? {
            let xi = Int(x.rounded()), yi = Int(y.rounded())
            guard xi >= 0, yi >= 0, xi < cur.width, yi < cur.height else { return nil }
            return Double(cur.pixels[yi * cur.width + xi])
        }

        /// Flood-fills the object at `c` using a threshold halfway between its inside and its surroundings, and
        /// returns its true centre, diameter and circularity; nil if it isn't a pointer-sized, round, closed shape.
        func segment(_ c: CGPoint, radius r: Double) -> (center: CGPoint, diameter: Double, iou: Double)? {
            let w = cur.width, h = cur.height
            let cx = Int(Double(c.x).rounded()), cy = Int(Double(c.y).rounded())
            guard cx >= 0, cy >= 0, cx < w, cy < h else { return nil }
            // Inside: mean of the central part.
            var inSum = 0.0, inN = 0.0
            let ir = max(1, Int(r * 0.4))
            for y in max(0, cy - ir)...min(h - 1, cy + ir) {
                for x in max(0, cx - ir)...min(w - 1, cx + ir) { inSum += Double(cur.pixels[y * w + x]); inN += 1 }
            }
            let inside = inSum / inN
            var gaps: [Double] = []
            for k in 0..<16 {
                let a = Double(k) * .pi / 8
                if let v = sample(Double(c.x) + cos(a) * r * 1.5, Double(c.y) + sin(a) * r * 1.5) { gaps.append(abs(v - inside)) }
            }
            guard gaps.count >= 6 else { return nil }
            gaps.sort()
            // Halfway to the *closest* surrounding shade, so a neighbour of similar grey is not swallowed.
            let tol = max(config.contrastThreshold * 0.5, gaps[gaps.count / 5] * 0.5)
            // Pixels like the inside, in a window; an opening cuts thin anti-aliased paths (text edges) that would
            // otherwise connect the dot to its surroundings. Touching the window edge = part of something bigger.
            let R = Int(maxD * 1.3) + 2
            let x0 = max(0, cx - R), x1 = min(w - 1, cx + R), y0 = max(0, cy - R), y1 = min(h - 1, cy + R)
            let ww = x1 - x0 + 1, wh = y1 - y0 + 1
            var like = [UInt8](repeating: 0, count: ww * wh)
            for y in y0...y1 {
                for x in x0...x1 where abs(Double(cur.pixels[y * w + x]) - inside) <= tol { like[(y - y0) * ww + (x - x0)] = 1 }
            }
            like = PointerMorphology.open(like, width: ww, height: wh, radius: max(1, Int(r * 0.25)))
            guard like[(cy - y0) * ww + (cx - x0)] != 0 else { return nil }
            var seen = [Bool](repeating: false, count: ww * wh)
            var stack = [(cx, cy)]; seen[(cy - y0) * ww + (cx - x0)] = true
            var area = 0, minX = cx, maxX = cx, minY = cy, maxY = cy, sx = 0.0, sy = 0.0
            var members: [(Int, Int)] = []
            while let (x, y) = stack.popLast() {
                area += 1; sx += Double(x); sy += Double(y); members.append((x, y))
                minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
                if (x == x0 && x0 > 0) || (x == x1 && x1 < w - 1) || (y == y0 && y0 > 0) || (y == y1 && y1 < h - 1) { return nil }
                for (nx, ny) in [(x - 1, y), (x + 1, y), (x, y - 1), (x, y + 1)] where nx >= x0 && nx <= x1 && ny >= y0 && ny <= y1 {
                    let j = (ny - y0) * ww + (nx - x0)
                    if seen[j] { continue }
                    seen[j] = true
                    if like[j] != 0 { stack.append((nx, ny)) }
                }
            }
            let bw = Double(maxX - minX + 1), bh = Double(maxY - minY + 1)
            let d = (bw + bh) / 2
            guard d >= minD, d <= maxD, bw / bh > 0.7, bw / bh < 1.43 else { return nil }
            let ex = Double(minX + maxX) / 2, ey = Double(minY + maxY) / 2
            var inEllipse = 0
            for (x, y) in members {
                let dx = (Double(x) - ex) / (bw / 2), dy = (Double(y) - ey) / (bh / 2)
                if dx * dx + dy * dy <= 1 { inEllipse += 1 }
            }
            let ellipseArea = Double.pi / 4 * bw * bh
            let iou = Double(inEllipse) / (Double(area) + ellipseArea - Double(inEllipse))
            guard iou >= 0.84 else { return nil }
            return (CGPoint(x: sx / Double(area), y: sy / Double(area)), d, iou)
        }

        /// Fraction of directions in which the pixels just outside the dot differ from its inside. A real dot
        /// stands out all the way round; the corner of an icon or a bar only on some sides.
        func surroundContrast(_ c: CGPoint, radius r: Double, interior: Double) -> Double {
            var hits = 0, total = 0
            for k in 0..<16 {
                let a = Double(k) * .pi / 8
                guard let v = sample(Double(c.x) + cos(a) * r * 1.45, Double(c.y) + sin(a) * r * 1.45) else { continue }
                total += 1
                if abs(v - interior) > config.contrastThreshold * 0.7 { hits += 1 }
            }
            return total >= 8 ? Double(hits) / Double(total) : 1   // at a screen corner: don't judge
        }

        /// True for a disc inside concentric rings (the AssistiveTouch button): around it the grey level changes
        /// with the distance but is the same in every direction.
        func isConcentric(_ c: CGPoint, radius r: Double) -> Bool {
            var means: [Double] = [], spreads: [Double] = []
            for f in [1.5, 1.8, 2.1, 2.4] {
                var vals: [Double] = []
                for k in 0..<16 {
                    let a = Double(k) * .pi / 8
                    if let v = sample(Double(c.x) + cos(a) * r * f, Double(c.y) + sin(a) * r * f) { vals.append(v) }
                }
                guard vals.count >= 12 else { return false }
                let m = vals.reduce(0, +) / Double(vals.count)
                means.append(m)
                spreads.append(sqrt(vals.reduce(0) { $0 + ($1 - m) * ($1 - m) } / Double(vals.count)))
            }
            // Only the radii where the grey level is the same all the way round count; if those differ from
            // each other, the dot sits inside rings.
            let uniform = zip(means, spreads).filter { $0.1 < 10 }.map(\.0)
            guard uniform.count >= 2 else { return false }
            return (uniform.max()! - uniform.min()!) > 20
        }

        /// Frame-difference detector; refines with the blob detector near the changed region.
        func diffDetect(prev: PointerGrayImage, hint: CGPoint?) -> (CGPoint, Double)? {
            let w = cur.width, h = cur.height
            var mask = [UInt8](repeating: 0, count: w * h)
            var weight = [Float](repeating: 0, count: w * h)
            let t = config.diffThreshold
            var changed = 0
            for i in 0..<(w * h) {
                let d = abs(Double(cur.pixels[i]) - Double(prev.pixels[i]))
                if d > t { mask[i] = 1; weight[i] = Float(d); changed += 1 }
            }
            guard changed > 0 else { return nil }
            // Whole screen changed (scroll, app switch): differencing tells us nothing.
            if Double(changed) > 0.25 * Double(w * h) { return nil }
            let minArea = max(3, Int(0.15 * minD * minD))
            let maxArea = Int(1.6 * maxD * maxD)
            let blobs = PointerComponents.find(mask: mask, width: w, height: h, in: (0, 0, w, h),
                                               weight: weight, value: cur, minArea: minArea, maxArea: maxArea)
            var best: (blob: PointerBlob, score: Double)?
            for b in blobs {
                let d = b.diameter
                guard d >= minD * 0.4, d <= maxD * 1.4, b.aspect > 0.33, b.aspect < 3 else { continue }
                let c = b.center
                // New position: the current pixels contrast with their surroundings.
                let contrast = abs(b.meanValue - integral.mean(x: Int(c.x), y: Int(c.y), radius: radius))
                guard contrast > config.contrastThreshold * 0.6 else { continue }
                let score = min(1, contrast / 80) * (0.5 + 0.5 * sizeScore(d)) * hintFactor(c, hint)
                if best == nil || score > best!.score { best = (b, score) }
            }
            guard let blob = best?.blob else { return nil }
            let c = blob.center
            let r = Int(maxD * 1.6)
            if let refined = blobDetect(rect: (Int(c.x) - r, Int(c.y) - r, Int(c.x) + r + 1, Int(c.y) + r + 1),
                                        hint: c, near: c, nearRadius: maxD) {
                return (refined.0, min(1, refined.1 + 0.3))
            }
            return blob.roundness > 0.3 ? (c, 0.45) : nil
        }
    }
}
