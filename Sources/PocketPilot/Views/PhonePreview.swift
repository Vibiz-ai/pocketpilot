import PocketPilotCore
import SwiftUI

/// The live iPhone screen at its real aspect ratio, with the last tap drawn on top.
/// `onTap` receives the tapped point in full-resolution frame pixels.
struct PhonePreview: View {
    let image: CGImage?
    let frameSize: CGSize?
    var lastTap: CGPoint?        // screenshot space
    var lastTapAt: Date?
    var placeholder = "Waiting for the iPhone screen"
    var onTap: ((CGPoint) -> Void)?

    private var aspect: CGFloat {
        if let s = frameSize, s.height > 0 { return s.width / s.height }
        return 1179.0 / 2556.0
    }

    var body: some View {
        GeometryReader { geo in
            let size = fitted(in: geo.size)
            ZStack {
                RoundedRectangle(cornerRadius: size.width * 0.09, style: .continuous)
                    .fill(Color.black)
                if let image {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "iphone.gen3").font(.system(size: 34, weight: .ultraLight))
                        Text(placeholder).font(.callout).multilineTextAlignment(.center)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                    .padding()
                }
                if let tap = lastTap, let frameSize {
                    TapMarker(at: tap, frameSize: frameSize, viewSize: size, date: lastTapAt)
                }
            }
            .frame(width: size.width, height: size.height)
            .clipShape(RoundedRectangle(cornerRadius: size.width * 0.09, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: size.width * 0.09, style: .continuous)
                .strokeBorder(.white.opacity(0.18), lineWidth: 1))
            .shadow(color: .black.opacity(0.25), radius: 12, y: 4)
            .contentShape(Rectangle())
            .gesture(SpatialTapGesture().onEnded { value in
                guard let onTap, let frameSize else { return }
                let p = CGPoint(x: value.location.x / size.width * frameSize.width,
                                y: value.location.y / size.height * frameSize.height)
                onTap(p)
            }, including: onTap == nil ? .none : .all)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(aspect, contentMode: .fit)
        .accessibilityLabel(image == nil ? placeholder : "Live iPhone screen")
    }

    private func fitted(in container: CGSize) -> CGSize {
        let w = min(container.width, container.height * aspect)
        return CGSize(width: w, height: w / aspect)
    }
}

/// A ring at the last tap, fading out over a few seconds.
private struct TapMarker: View {
    let at: CGPoint
    let frameSize: CGSize
    let viewSize: CGSize
    let date: Date?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 20)) { ctx in
            let age = date.map { ctx.date.timeIntervalSince($0) } ?? 0
            let opacity = max(0.25, 1 - age / 4)
            let geo = ScreenGeometry(frameSize: frameSize)
            let x = at.x / geo.screenshotSize.width * viewSize.width
            let y = at.y / geo.screenshotSize.height * viewSize.height
            ZStack {
                Circle().strokeBorder(Color.accentColor, lineWidth: 2.5).frame(width: 28, height: 28)
                Circle().fill(Color.accentColor).frame(width: 6, height: 6)
            }
            .shadow(color: .black.opacity(0.5), radius: 2)
            .opacity(opacity)
            .position(x: x, y: y)
        }
        .allowsHitTesting(false)
    }
}
