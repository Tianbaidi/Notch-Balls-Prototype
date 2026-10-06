import AppKit

enum DockPosition: Int, CaseIterable {
    case automatic, left, right, notchLeft
    var title: String {
        switch self {
        case .automatic: return "刘海下方（默认）"
        case .left: return "固定在左侧"
        case .right: return "固定在右侧"
        case .notchLeft: return "固定在刘海左侧"
        }
    }
}

struct DockGeometry {
    let overlay: CGRect
    let trigger: CGRect
    let alignment: Int
    let notchBandHeight: CGFloat

    static func resolve(screen: CGRect, safeTop: CGFloat, height: CGFloat,
                        position: DockPosition, fullscreen: Bool, maximumHeight: CGFloat = 444, notchLeftEdge: CGFloat? = nil) -> DockGeometry {
        let besideNotch = !fullscreen && position == .notchLeft
        if besideNotch {
            let boundary = min(screen.maxX - 80, max(screen.minX + 240, notchLeftEdge ?? screen.midX - 90))
            let width = min(640, boundary - screen.minX - 24)
            let band = max(28, safeTop)
            return DockGeometry(overlay: CGRect(x: boundary - 8 - width, y: screen.maxY - height, width: width, height: height),
                trigger: CGRect(x: boundary - 44, y: screen.maxY - band / 2 - 4, width: 32, height: 8),
                alignment: 1, notchBandHeight: band)
        }
        let width = min(640, screen.width - 24)
        let side = fullscreen ? 0 : position == .left ? -1 : position == .right ? 1 : 0
        let top: CGFloat
        let x: CGFloat
        let trigger: CGRect
        if side == 0 {
            top = screen.maxY - max(30, safeTop)
            x = screen.midX - width / 2
            trigger = CGRect(x: screen.midX - 80, y: top, width: 160, height: max(30, safeTop))
        } else {
            top = min(screen.maxY - max(30, safeTop) - 48,
                      max(screen.minY + max(height, maximumHeight) + 24, screen.midY + 20))
            x = side < 0 ? screen.minX + 12 : screen.maxX - width - 12
            trigger = CGRect(x: side < 0 ? screen.minX : screen.maxX - 6,
                             y: top - 44, width: 6, height: 48)
        }
        return DockGeometry(overlay: CGRect(x: x, y: top - height, width: width, height: height),
                            trigger: trigger, alignment: side, notchBandHeight: 0)
    }

    static func coversFullscreen(_ window: CGRect, screen: CGRect, safeTop: CGFloat) -> Bool {
        abs(window.minX - screen.minX) <= 4 && abs(window.maxX - screen.maxX) <= 4 &&
        abs(window.minY - screen.minY) <= 4 && window.maxY >= screen.maxY - max(30, safeTop) - 4
    }
}
