import AppKit
import SwiftUI
import ScreenCaptureKit

struct BackdropRegion: Equatable {
    let frame: CGRect
    let screenFrame: CGRect
    let displayID: CGDirectDisplayID
    let excludedWindows: Set<CGWindowID>
    var sourceRect: CGRect {
        CGRect(x: frame.minX - screenFrame.minX, y: screenFrame.maxY - frame.maxY,
               width: frame.width, height: frame.height)
    }
}

/// Hysteresis and a short hold reject noise around the light/dark boundary.
struct BackdropTone {
    private(set) var isDark: Bool?
    private var pending: Bool?
    private var since: TimeInterval = 0
    mutating func ingest(_ luminance: Double, time: TimeInterval) -> Bool? {
        guard luminance.isFinite, (0...1).contains(luminance) else { return nil }
        guard let current = isDark else {
            isDark = luminance < 0.18
            return isDark
        }
        let next = current ? luminance < 0.24 : luminance < 0.13
        guard next != current else { pending = nil; return nil }
        guard pending == next else { pending = next; since = time; return nil }
        guard time - since >= 0.20 else { return nil }
        isDark = next
        pending = nil
        return next
    }

    static func luminance(of image: CGImage) -> Double? {
        let width = 48, height = 24
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        return pixels.withUnsafeMutableBytes { bytes in
            guard let space = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            func linear(_ byte: UInt8) -> Double {
                let s = Double(byte) / 255
                return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
            }
            let data = bytes.bindMemory(to: UInt8.self)
            var values: [Double] = []
            for pixel in stride(from: 0, to: data.count, by: 4) where data[pixel + 3] > 240 {
                values.append(0.2126 * linear(data[pixel]) + 0.7152 * linear(data[pixel + 1])
                    + 0.0722 * linear(data[pixel + 2]))
            }
            guard !values.isEmpty else { return nil }
            values.sort()
            return values[values.count / 2]
        }
    }
}

// UI state is accessed on the main thread; the asynchronous capture service does
// its image work off the UI actor. Only sampleNow crosses asynchronous boundaries.
final class BackdropContrastStore: ObservableObject {
    @Published private(set) var enabled: Bool
    @Published private(set) var ready = false
    var paused = false { didSet { if paused != oldValue { revision += 1; lastSample = -.infinity } } }
    var region: (() -> BackdropRegion?)?
    var statusChanged: (() -> Void)?
    private let defaults: UserDefaults
    private let foreground: CapsuleForeground
    private let authorization: () -> Bool
    private let requestAuthorization: () -> Bool
    private let capture: (BackdropRegion) async throws -> Double?
    private var tone = BackdropTone()
    private var timer: Timer?
    private var sampling = false
    private var lastSample: TimeInterval = -.infinity
    private var retryAfter: TimeInterval = 0
    private var revision = 0
    private let enabledKey = "notch.backdrop.enabled.v1"
    private let askedKey = "notch.backdrop.permissionAsked.v1"

    init(foreground: CapsuleForeground, defaults: UserDefaults = .standard,
         startTimer: Bool = true, authorization: @escaping () -> Bool = CGPreflightScreenCaptureAccess,
         requestAuthorization: @escaping () -> Bool = CGRequestScreenCaptureAccess,
         capture: @escaping (BackdropRegion) async throws -> Double? = BackdropContrastStore.captureLuminance) {
        self.foreground = foreground
        self.defaults = defaults
        self.authorization = authorization
        self.requestAuthorization = requestAuthorization
        self.capture = capture
        enabled = defaults.object(forKey: enabledKey) == nil || defaults.bool(forKey: enabledKey)
        ready = authorization()
        if startTimer {
            let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
                Task { @MainActor in await self?.sampleNow() }
            }
            self.timer = timer
            // Sampling never runs in the native menu tracking mode.
            RunLoop.main.add(timer, forMode: .default)
        }
    }

    func stop() { timer?.invalidate(); timer = nil; revision += 1 }
    deinit { timer?.invalidate() }

    func setEnabled(_ value: Bool) {
        guard value != enabled else { return }
        enabled = value
        defaults.set(value, forKey: enabledKey)
        revision += 1
        tone = BackdropTone()
        if !value { useSystemAppearance() }
        statusChanged?()
    }

    private func useSystemAppearance() {
        if foreground.tracksBackdrop { foreground.tracksBackdrop = false }
        foreground.adapt(isDark: NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
    }

    @MainActor func sampleNow() async {
        guard enabled, !paused, !sampling, let area = region?(),
              area.frame.width >= 4, area.frame.height >= 4 else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= retryAfter, now - lastSample >= (ProcessInfo.processInfo.isLowPowerModeEnabled ? 1.2 : 0.4) else { return }
        var authorized = authorization()
        if !authorized && !defaults.bool(forKey: askedKey) {
            defaults.set(true, forKey: askedKey)
            authorized = requestAuthorization() || authorization()
        }
        if ready != authorized { ready = authorized; statusChanged?() }
        guard authorized else { useSystemAppearance(); return }
        sampling = true
        lastSample = now
        let generation = revision
        defer { sampling = false }
        do {
            guard let luminance = try await capture(area), generation == revision,
                  enabled, !paused, region?() == area else { return }
            let changed = tone.ingest(luminance, time: ProcessInfo.processInfo.systemUptime)
            if let dark = changed ?? tone.isDark {
                if !foreground.tracksBackdrop { foreground.tracksBackdrop = true }
                foreground.adapt(isDark: dark)
            }
        } catch {
            guard generation == revision, enabled, !paused, region?() == area else { return }
            retryAfter = now + 4
            tone = BackdropTone()
            useSystemAppearance()
        }
    }

    private static func captureLuminance(_ region: BackdropRegion) async throws -> Double? {
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first(where: { $0.displayID == region.displayID }) else { return nil }
        let excluded = content.windows.filter { region.excludedWindows.contains($0.windowID) }
        let filter = SCContentFilter(display: display, excludingWindows: excluded)
        if #available(macOS 14.2, *) { filter.includeMenuBar = true }
        let config = SCStreamConfiguration()
        config.sourceRect = region.sourceRect
        config.width = 48
        config.height = 24
        config.showsCursor = false
        config.capturesAudio = false
        config.ignoreShadowsDisplay = true
        config.colorSpaceName = CGColorSpace.sRGB
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        // Only this downsampled local region is inspected. Nothing is retained or written to disk.
        return BackdropTone.luminance(of: image)
    }
}
