import CoreGraphics
import Foundation

/// One measurement: sending a single mouse report of `step` HID units moved the pointer `pixelsPerStep` px.
public struct CurveSample: Codable, Equatable, Sendable {
    public var step: Int
    public var pixelsPerStep: Double
    public init(step: Int, pixelsPerStep: Double) { self.step = step; self.pixelsPerStep = pixelsPerStep }
}

/// iOS pointer acceleration for one axis: step size (HID units per report) -> pixels moved per report.
public struct AxisCurve: Codable, Equatable, Sendable {
    /// Sorted by `step` ascending; steps are positive (the sign is applied by the caller).
    public var samples: [CurveSample]

    public init(samples: [CurveSample]) { self.samples = samples.sorted { $0.step < $1.step } }

    public var isUsable: Bool { samples.count >= 2 && samples.allSatisfy { $0.pixelsPerStep > 0 } }

    /// Linear interpolation; extrapolates proportionally outside the measured range.
    public func pixels(forStep step: Int) -> Double {
        let s = abs(step)
        guard let first = samples.first, let last = samples.last else { return 0 }
        if s <= first.step { return first.pixelsPerStep * Double(s) / Double(max(first.step, 1)) }
        if s >= last.step { return last.pixelsPerStep * Double(s) / Double(max(last.step, 1)) }
        for (a, b) in zip(samples, samples.dropFirst()) where s >= a.step && s <= b.step {
            let t = Double(s - a.step) / Double(max(b.step - a.step, 1))
            return a.pixelsPerStep + t * (b.pixelsPerStep - a.pixelsPerStep)
        }
        return last.pixelsPerStep
    }
}

public enum ParkCorner: String, Codable, Sendable { case topLeft, topRight, bottomLeft, bottomRight }

public struct CalibrationData: Codable, Equatable, Sendable {
    public static let currentVersion = 1
    public var version: Int
    public var createdAt: Date
    /// Which iPhone this was measured on (nil if unknown).
    public var deviceUDID: String?
    /// The screenshot-space size the pixel values refer to.
    public var screenshotSize: CGSize
    public var park: ParkCorner
    /// Delay between consecutive mouse reports used while measuring (keep the same when moving).
    public var reportIntervalMs: Int
    public var x: AxisCurve
    public var y: AxisCurve

    public init(version: Int = CalibrationData.currentVersion, createdAt: Date = Date(), deviceUDID: String?,
                screenshotSize: CGSize, park: ParkCorner = .topLeft, reportIntervalMs: Int = 8,
                x: AxisCurve, y: AxisCurve) {
        self.version = version; self.createdAt = createdAt; self.deviceUDID = deviceUDID
        self.screenshotSize = screenshotSize; self.park = park; self.reportIntervalMs = reportIntervalMs
        self.x = x; self.y = y
    }
}

public protocol CalibrationStore: AnyObject {
    func load() throws -> CalibrationData?
    func save(_ data: CalibrationData) throws
    func clear() throws
}

/// ~/Library/Application Support/OpenTap/calibration.json
public final class FileCalibrationStore: CalibrationStore {
    public let url: URL

    public static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OpenTap/calibration.json")
    }

    public init(url: URL = FileCalibrationStore.defaultURL) { self.url = url }

    public func load() throws -> CalibrationData? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        do {
            let dec = JSONDecoder(); dec.dateDecodingStrategy = .iso8601
            return try dec.decode(CalibrationData.self, from: Data(contentsOf: url))
        } catch {
            throw OpenTapError(.io, what: "Couldn't read the saved calibration",
                               why: "\(url.path) is unreadable or from an older version (\(error.localizedDescription))",
                               fix: "Run Calibrate again; it will overwrite the file")
        }
    }

    public func save(_ data: CalibrationData) throws {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let enc = JSONEncoder(); enc.dateEncodingStrategy = .iso8601; enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(data).write(to: url, options: .atomic)
        } catch {
            throw OpenTapError(.io, what: "Couldn't save the calibration",
                               why: "Writing \(url.path) failed: \(error.localizedDescription)",
                               fix: "Check that your user can write to ~/Library/Application Support/OpenTap")
        }
    }

    public func clear() throws {
        if FileManager.default.fileExists(atPath: url.path) { try? FileManager.default.removeItem(at: url) }
    }
}

public final class InMemoryCalibrationStore: CalibrationStore {
    private var data: CalibrationData?
    public init(_ data: CalibrationData? = nil) { self.data = data }
    public func load() throws -> CalibrationData? { data }
    public func save(_ data: CalibrationData) throws { self.data = data }
    public func clear() throws { data = nil }
}
