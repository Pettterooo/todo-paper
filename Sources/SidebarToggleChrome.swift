import AppKit

/// macOS 26 draws system toolbar items — including the sidebar toggle — inside
/// an `NSGlassEffectView` platter. Custom toolbar items can opt out of the
/// capsule with `.sharedBackgroundVisibility(.hidden)`, but the system item has
/// no equivalent switch.
///
/// So: lift the button's content out of the glass and hide the glass. The item
/// is still the system item, so its position (sidebar trailing edge / leading
/// edge when collapsed), its action and ⌃⌘S all keep working; only the capsule
/// is gone.
///
/// This is presentation-only and fails safe: if AppKit's toolbar hierarchy ever
/// changes, nothing matches and the stock look is left untouched.
enum SidebarToggleChrome {
    private static var observersInstalled = false

    /// Idempotent. Call when a document window appears; it also re-applies when
    /// a window becomes key so newly opened windows are covered.
    static func install() {
        applyToAllWindows()
        guard !observersInstalled else { return }
        observersInstalled = true
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification,
                     NSWindow.didBecomeMainNotification,
                     NSWindow.didResizeNotification,
                     NSApplication.didBecomeActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                applyToAllWindows()
            }
        }
    }

    private static func applyToAllWindows() {
        for window in NSApp.windows {
            apply(to: window)
        }
    }

    private static func apply(to window: NSWindow) {
        guard let toolbar = window.toolbar,
              let item = toolbar.items.first(where: {
                  $0.itemIdentifier.rawValue.lowercased().hasSuffix("togglesidebar")
              }),
              let itemView = item.view else { return }

        var node: NSView? = itemView
        while let current = node {
            if let glass = current as? NSGlassEffectView {
                strip(glass: glass, itemView: itemView)
                return
            }
            node = current.superview
        }
    }

    private static func strip(glass: NSGlassEffectView, itemView: NSView) {
        guard let platter = glass.superview,
              let holder = glass.subviews.first(where: { $0 !== itemView && contains($0, itemView) }) else {
            return
        }

        let size = glass.frame.size
        holder.removeFromSuperview()
        holder.translatesAutoresizingMaskIntoConstraints = true
        holder.frame = NSRect(origin: .zero, size: size)
        platter.addSubview(holder)
        glass.isHidden = true

        // Safety net: if the content ended up detached from the window, undo.
        if holder.window !== glass.window {
            holder.removeFromSuperview()
            glass.addSubview(holder)
            holder.frame = NSRect(origin: .zero, size: size)
            glass.isHidden = false
        }
    }

    private static func contains(_ root: NSView, _ target: NSView) -> Bool {
        if root === target { return true }
        return root.subviews.contains { contains($0, target) }
    }
}
