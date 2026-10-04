import AppKit
import SwiftUI

// One vocabulary for the compact overlay and its expanded controls.
enum CapsuleTheme {
    static func accent(_ id: String) -> Color {
        switch id {
        case "reminders": return Color(red: 0.36, green: 0.64, blue: 1)
        case "notes": return Color(red: 0.96, green: 0.71, blue: 0.30)
        case "music": return Color(red: 0.77, green: 0.49, blue: 0.93)
        case "timeline": return Color(red: 0.39, green: 0.68, blue: 0.86)
        default: return Color(red: 0.33, green: 0.76, blue: 0.65)
        }
    }
    static func symbol(_ id: String) -> String {
        switch id {
        case "reminders": return "checklist"
        case "notes": return "note.text"
        case "music": return "music.note"
        case "timeline": return "calendar.day.timeline.left"
        default: return "timer"
        }
    }
    static func controlLabel(_ symbol: String) -> String {
        switch symbol {
        case "pin": return "固定此模块"
        case "pin.fill": return "取消固定"
        case "xmark": return "关闭此模块"
        case "play.fill": return "开始或继续"
        case "pause.fill": return "暂停"
        case "stop.fill": return "结束并记录"
        case "backward.end.fill": return "上一首"
        case "forward.end.fill": return "下一首"
        case "chevron.down", "arrow.up.left.and.arrow.down.right": return "展开详情"
        case "chevron.up", "arrow.down.right.and.arrow.up.left": return "收起详情"
        case "plus": return "添加"
        case "arrow.clockwise": return "刷新"
        default: return "操作"
        }
    }
}

/// Shared surfaces keep every module's cards and inputs in the same visual family.
struct CapsuleCard: ViewModifier {
    var accent: Color = .clear
    var corner: CGFloat = 12
    @Environment(\.colorScheme) private var scheme
    func body(content: Content) -> some View {
        content.background {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(.primary.opacity(scheme == .dark ? 0.035 : 0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .fill(LinearGradient(colors: [accent.opacity(0.075), accent.opacity(0.018)],
                                             startPoint: .topLeading, endPoint: .bottomTrailing))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: corner, style: .continuous)
                        .strokeBorder(.primary.opacity(scheme == .dark ? 0.055 : 0.04), lineWidth: 0.5)
                }
        }
    }
}

struct CapsuleGlyph: View {
    let moduleID: String
    var size: CGFloat = 30
    var body: some View {
        let accent = CapsuleTheme.accent(moduleID)
        Image(systemName: CapsuleTheme.symbol(moduleID))
            .font(.system(size: size * 0.46, weight: .medium))
            .foregroundStyle(accent)
            .frame(width: size, height: size)
            .modifier(CapsuleCard(accent: accent, corner: size * 0.3))
            .accessibilityHidden(true)
    }
}

enum CapsuleMotion {
    static func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * t * (t * (t * 6 - 15) + 10)
    }
}

/// Native menus own pointer tracking; overlay work resumes after the last submenu closes.
struct MenuTrackingState {
    private(set) var depth = 0
    var isActive: Bool { depth > 0 }
    mutating func begin() { depth += 1 }
    @discardableResult mutating func end() -> Bool {
        guard depth > 0 else { return false }
        depth -= 1
        return depth == 0
    }
}

struct CapsuleInkPalette {
    var lightFraction: Double
    var primary: Color { Color(white: 0.10 + 0.85 * lightFraction) }
    var secondary: Color { primary.opacity(0.68) }
    var nsColor: NSColor { NSColor(white: 0.10 + 0.85 * lightFraction, alpha: 1) }
}

private struct CapsuleInkKey: EnvironmentKey {
    static let defaultValue: CapsuleInkPalette? = nil
}
extension EnvironmentValues {
    var capsuleInk: CapsuleInkPalette? {
        get { self[CapsuleInkKey.self] }
        set { self[CapsuleInkKey.self] = newValue }
    }
}

final class CapsuleForeground: ObservableObject {
    @Published private(set) var lightFraction: Double
    @Published var tracksBackdrop = false
    private var target: Bool
    private let animator = CapsuleAnimator()
    var palette: CapsuleInkPalette { CapsuleInkPalette(lightFraction: lightFraction) }

    init(isDark: Bool = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua) {
        target = isDark
        lightFraction = isDark ? 1 : 0
    }

    func adapt(isDark: Bool, animated: Bool = true) {
        guard target != isDark || !animated else { return }
        target = isDark
        let start = lightFraction
        let end: Double = isDark ? 1 : 0
        animator.animate(duration: animated ? 0.26 : 0) { [weak self] progress in
            self?.lightFraction = start + (end - start) * Double(progress)
        }
    }
}

struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false
    var subtle = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    @Environment(\.capsuleInk) private var ink
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, prominent: prominent, subtle: subtle,
                reduceMotion: reduceMotion, enabled: enabled, ink: ink)
    }
    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let subtle: Bool
        let reduceMotion: Bool
        let enabled: Bool
        let ink: CapsuleInkPalette?
        @State private var hovered = false
        var body: some View {
            configuration.label
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : ink?.primary ?? Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(prominent ? Color.accentColor.opacity(configuration.isPressed ? 0.74 : hovered ? 0.98 : 0.90)
                              : Color.primary.opacity(configuration.isPressed ? 0.10 : hovered ? 0.065 : subtle ? 0 : 0.022))
                        .overlay {
                            if prominent {
                                RoundedRectangle(cornerRadius: 9, style: .continuous)
                                    .fill(LinearGradient(colors: [.white.opacity(0.16), .clear],
                                                         startPoint: .top, endPoint: .bottom))
                            }
                        }
                }
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.primary.opacity(subtle && !hovered ? 0 : hovered ? 0.085 : 0.035), lineWidth: 0.5))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.97 : 1)
                .offset(y: hovered && !configuration.isPressed && !reduceMotion && enabled ? -0.5 : 0)
                .opacity(enabled ? 1 : 0.36)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: configuration.isPressed)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovered)
                .onHover { hovered = $0 }
        }
    }
}

/// Interruptible geometry transitions. Common run-loop mode keeps motion running
/// during button tracking; uptime prevents a system clock correction causing jumps.
final class CapsuleAnimator {
    private var timer: Timer?
    func cancel() { timer?.invalidate(); timer = nil }
    deinit { timer?.invalidate() }
    static func progress(_ elapsed: Double, duration: Double) -> CGFloat {
        guard duration > 0 else { return 1 }
        let t = min(1, max(0, elapsed / duration))
        return CGFloat(CapsuleMotion.smooth(t))
    }
    func animate(duration: Double = 0.28, timing: ((Double) -> CGFloat)? = nil, step: @escaping (CGFloat) -> Void,
                 completion: @escaping () -> Void = {}) {
        cancel()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || duration <= 0 {
            step(1); completion(); return
        }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            step(timing?(min(1, max(0, elapsed / duration))) ?? Self.progress(elapsed, duration: duration))
            if elapsed >= duration { timer.invalidate(); completion() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}

/// Stable layout decisions must depend on container size, never changing text.
enum MusicPresentation {
    static func usesFullCompact(width: CGFloat) -> Bool { width >= 420 }
    static func usesFullDetail(width: CGFloat) -> Bool { width >= 440 }
}
