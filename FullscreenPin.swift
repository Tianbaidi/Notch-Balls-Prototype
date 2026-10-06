import AppKit
import SwiftUI

struct CapsuleLayoutSnapshot: Equatable {
    let selected: Int?
    let reminders: Bool
    let notes: Bool
    let music: Bool
    let pomodoro: Bool
    let timelineLevel: Int
    var selectedPinned = false
}

/// A temporary presentation never changes the user's Pin or desktop expansion preferences.
struct FullscreenPinSession {
    private(set) var active = false
    private(set) var expanded = false
    private(set) var desktop: CapsuleLayoutSnapshot?
    mutating func update(active next: Bool, snapshot: CapsuleLayoutSnapshot) -> CapsuleLayoutSnapshot? {
        guard next != active else { return nil }
        active = next
        expanded = false
        if next { desktop = snapshot; return nil }
        let restore = desktop
        desktop = nil
        return restore
    }
    mutating func expand() { if active { expanded = true } }
    mutating func collapse() { expanded = false }
}

struct FullscreenPinGeometry: Equatable {
    let left: CGRect?
    let right: CGRect
    var usesWings: Bool { left != nil }
    static func resolve(screen: CGRect, safeTop: CGFloat, notchLeft: CGFloat?, notchRight: CGFloat?) -> Self {
        let height = floor(min(28, max(24, safeTop - 2)))
        if safeTop >= 24, let left = notchLeft, let right = notchRight,
           left.isFinite, right.isFinite, left < right,
           left - screen.minX >= 52, screen.maxX - right >= 76 {
            // WindowServer rounds panel origins. Align explicitly without entering the camera gap.
            let y = max(ceil(screen.maxY - safeTop), floor(screen.maxY - safeTop / 2 - height / 2))
            return Self(left: CGRect(x: floor(left) - 40, y: y, width: 40, height: height),
                        right: CGRect(x: ceil(right), y: y, width: 64, height: height))
        }
        // No real notch geometry: keep a small visible capsule, never invent a camera cutout.
        let width = min(148, max(80, screen.width - 24))
        return Self(left: nil, right: CGRect(x: floor(screen.midX - width / 2),
            y: floor(screen.maxY - max(8, safeTop + 6) - 28), width: width, height: 28))
    }
}

struct FullscreenPinStatus: Equatable {
    let moduleID: String
    let value: String
    let symbol: String?
    let progress: Double?
    let accessibility: String
}

enum FullscreenPinPart { case left, right, capsule }

struct FullscreenPinSurface: View {
    let status: FullscreenPinStatus
    let part: FullscreenPinPart
    let action: () -> Void
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var accent: Color { CapsuleTheme.accent(status.moduleID) }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if part != .right {
                    Circle().fill(LinearGradient(colors: [accent.opacity(0.85), accent],
                        startPoint: .topLeading, endPoint: .bottomTrailing))
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .frame(width: 13, height: 13)
                }
                if part != .left {
                    if let symbol = status.symbol {
                        Image(systemName: symbol).font(.system(size: 9, weight: .medium))
                    }
                    Text(status.value).font(.system(size: 11, weight: .medium)).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.9)
                }
            }
            .foregroundStyle(Color(white: 0.94))
            .padding(.horizontal, part == .left ? 0 : 7)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background {
                UnevenRoundedRectangle(topLeadingRadius: part == .right ? 0 : 10,
                    bottomLeadingRadius: part == .right ? 0 : 10,
                    bottomTrailingRadius: part == .left ? 0 : 10,
                    topTrailingRadius: part == .left ? 0 : 10)
                    .fill(Color(white: hovered ? 0.10 : 0.025))
            }
            .overlay(alignment: .bottom) {
                if part != .left, let progress = status.progress {
                    GeometryReader { geometry in
                        Capsule().fill(accent.opacity(0.8))
                            .frame(width: max(0, geometry.size.width * min(1, max(0, progress))), height: 1.5)
                    }.frame(height: 1.5).padding(.horizontal, 8).padding(.bottom, 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.15), value: hovered)
        .accessibilityLabel(status.accessibility)
        .accessibilityHint("点击展开，收回后仍保持固定")
    }
}

private final class FullscreenPinPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    // The frame is computed inside the physical screen, including its safe notch band.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect { frameRect }
}

private final class FullscreenPinHostingView: NSHostingView<FullscreenPinSurface> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Separate panels leave the hardware gap and every other pixel click-through.
final class FullscreenPinController {
    var open: (() -> Void)?
    private(set) var leftPanel: NSPanel?
    private(set) var rightPanel: NSPanel?
    private var previousStatus: FullscreenPinStatus?
    private var previousGeometry: FullscreenPinGeometry?
    var windowNumbers: Set<CGWindowID> {
        Set([leftPanel, rightPanel].compactMap { $0.map { CGWindowID($0.windowNumber) } })
    }
    func update(status: FullscreenPinStatus, geometry: FullscreenPinGeometry, menuTracking: Bool) {
        if rightPanel == nil { rightPanel = makePanel() }
        if geometry.usesWings && leftPanel == nil { leftPanel = makePanel() }
        let changed = status != previousStatus || geometry != previousGeometry
        for (panel, frame, part) in [(leftPanel, geometry.left, FullscreenPinPart.left),
                                    (rightPanel, Optional(geometry.right), geometry.usesWings ? .right : .capsule)] {
            guard let panel else { continue }
            guard let frame else { panel.orderOut(nil); continue }
            if panel.frame != frame { panel.setFrame(frame, display: true) }
            if changed {
                let root = FullscreenPinSurface(status: status, part: part) { [weak self] in self?.open?() }
                if let host = panel.contentView as? NSHostingView<FullscreenPinSurface> { host.rootView = root }
                else {
                    let host = FullscreenPinHostingView(rootView: root)
                    host.sizingOptions = []
                    panel.contentView = host
                }
            }
            panel.ignoresMouseEvents = menuTracking
            if !panel.isVisible { panel.orderFrontRegardless() }
        }
        previousStatus = status
        previousGeometry = geometry
    }
    func pauseInteraction(_ paused: Bool) {
        leftPanel?.ignoresMouseEvents = paused
        rightPanel?.ignoresMouseEvents = paused
    }
    func hide() { leftPanel?.orderOut(nil); rightPanel?.orderOut(nil) }
    private func makePanel() -> NSPanel {
        let panel = FullscreenPinPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }
}
