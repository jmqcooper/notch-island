import AppKit
import SwiftUI

/// Borderless panel that sits above the menu bar, on every Space, without
/// activating the app when clicked.
final class NotchPanel: NSPanel {
    init() {
        super.init(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isMovable = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        ignoresMouseEvents = true
        // Set last: other panel properties (like isFloatingPanel) reset the level.
        level = .mainMenu + 3
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// AppKit nudges windows below the menu bar; the island has to sit on top of it.
    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }
}

/// Lets the first click hit a button even though the panel is not key, and takes file drops
/// at the AppKit level, which works reliably in this borderless panel.
final class NotchHostingView<Content: View>: NSHostingView<Content> {
    var dropTarget: (NSPoint) -> DropTarget? = { _ in nil }
    var onDragTarget: (DropTarget?) -> Void = { _ in }
    var onDrop: ([URL], DropTarget) -> Void = { _, _ in }

    required init(rootView: Content) {
        super.init(rootView: rootView)
        registerForDraggedTypes([.fileURL, .URL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation { track(sender) }
    override func draggingExited(_ sender: NSDraggingInfo?) { onDragTarget(nil) }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let target = target(for: sender) else { return false }
        let urls = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self]) as? [URL] ?? []
        guard !urls.isEmpty else { return false }
        onDrop(urls, target)
        return true
    }

    private func track(_ sender: NSDraggingInfo) -> NSDragOperation {
        let target = target(for: sender)
        onDragTarget(target)
        return target == nil ? [] : .copy
    }

    private func target(for sender: NSDraggingInfo) -> DropTarget? {
        guard let window else { return nil }
        return dropTarget(window.convertPoint(toScreen: sender.draggingLocation))
    }
}
