import AppKit
import SwiftUI

// One vocabulary for the compact overlay and its expanded controls.
enum CapsuleTheme {
    static func accent(_ id: String) -> Color {
        switch id {
        case "reminders": return Color(red: 0.36, green: 0.64, blue: 1)
        case "notes": return Color(red: 0.96, green: 0.71, blue: 0.30)
        case "music": return Color(red: 0.77, green: 0.49, blue: 0.93)
        default: return Color(red: 0.33, green: 0.76, blue: 0.65)
        }
    }
    static func symbol(_ id: String) -> String {
        switch id {
        case "reminders": return "checklist"
        case "notes": return "note.text"
        case "music": return "music.note"
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

struct CapsuleButtonStyle: ButtonStyle {
    var prominent = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration, prominent: prominent, reduceMotion: reduceMotion, enabled: enabled)
    }
    private struct Surface: View {
        let configuration: ButtonStyleConfiguration
        let prominent: Bool
        let reduceMotion: Bool
        let enabled: Bool
        @State private var hovered = false
        var body: some View {
            configuration.label
                .foregroundStyle(prominent ? Color.black.opacity(0.85) : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .fill(prominent ? Color.accentColor.opacity(configuration.isPressed ? 0.7 : 0.9)
                              : Color.primary.opacity(configuration.isPressed ? 0.14 : hovered ? 0.08 : 0.035))
                }
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(.primary.opacity(hovered ? 0.12 : 0.04), lineWidth: 0.5))
                .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
                .opacity(enabled ? 1 : 0.38)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.14), value: configuration.isPressed)
                .animation(.easeOut(duration: 0.14), value: hovered)
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
        return CGFloat(1 - pow(1 - t, 3))
    }
    func animate(duration: Double = 0.28, step: @escaping (CGFloat) -> Void,
                 completion: @escaping () -> Void = {}) {
        cancel()
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion || duration <= 0 {
            step(1); completion(); return
        }
        let start = ProcessInfo.processInfo.systemUptime
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { timer in
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            step(Self.progress(elapsed, duration: duration))
            if elapsed >= duration { timer.invalidate(); completion() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }
}
