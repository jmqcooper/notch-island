import AppKit

enum Metrics {
    static let noticeWidth: CGFloat = 400
    static let noticeHeight: CGFloat = 50
    static let openWidth: CGFloat = 640
    static let openBodyHeight: CGFloat = 170
    static let dropWidth: CGFloat = 640
    static let dropBodyHeight: CGFloat = 124
    static let windowPadding: CGFloat = 24
}

struct NotchGeometry {
    let screen: NSScreen
    let notchSize: CGSize

    /// Prefers the built-in display with a camera housing. Other displays get a
    /// menu-bar-height pill so the island still has somewhere to live.
    static func current() -> NotchGeometry? {
        if let screen = NSScreen.screens.first(where: { $0.safeAreaInsets.top > 0 }),
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            let width = screen.frame.width - left.width - right.width
            return NotchGeometry(screen: screen, notchSize: CGSize(width: width, height: screen.safeAreaInsets.top))
        }
        guard let screen = NSScreen.main else { return nil }
        let menuBarHeight = max(screen.frame.maxY - screen.visibleFrame.maxY, 24)
        return NotchGeometry(screen: screen, notchSize: CGSize(width: 180, height: menuBarHeight))
    }
}
