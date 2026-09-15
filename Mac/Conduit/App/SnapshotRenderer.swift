//
//  SnapshotRenderer.swift
//  Conduit
//
//  Debug builds only. Renders the interfaces with preview data and writes
//  PNGs, so layout can be reviewed without Screen Recording permission:
//
//      Conduit.app/Contents/MacOS/Conduit --render-snapshots <directory>
//
//  MEASURED: `cacheDisplay` and `CALayer.render(in:)` leave list, table and
//  form content blank, and a transparent window's capture keeps its
//  transparency. So each view is hosted in an ordinary, opaque window placed
//  behind every other window and ignoring the mouse, and its pixels are read
//  back from the window server — which a process may always do for its own
//  windows.
//

#if DEBUG
import AppKit
import ConduitState
import SwiftUI

@MainActor
enum SnapshotRenderer {

    /// Returns true when snapshot mode was requested and handled.
    static func runIfRequested() -> Bool {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "--render-snapshots"), flag + 1 < arguments.count else {
            return false
        }
        let directory = URL(fileURLWithPath: arguments[flag + 1], isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            let suffix = appearance == .aqua ? "light" : "dark"

            for scenario in ConduitStore.PreviewScenario.allCases {
                render(MenuBarPanel().environment(ConduitStore.preview(scenario)).environment(WorkspaceRouter()),
                       size: CGSize(width: 320, height: 560), appearance: appearance, titled: false,
                       to: directory.appendingPathComponent("menubar-\(scenario.rawValue)-\(suffix).png"))
            }

            for section in [WorkspaceRouter.Section.overview, .phoneScreen, .clipboard, .activity, .devices, .settings, .calls] {
                let router = WorkspaceRouter()
                router.section = section
                render(WorkspaceView().environment(ConduitStore.preview(.connected)).environment(router),
                       size: CGSize(width: 1000, height: 700), appearance: appearance, titled: true,
                       to: directory.appendingPathComponent("workspace-\(section.rawValue)-\(suffix).png"))
            }
        }

        render(PhoneWindowView().environment(ConduitStore.preview(.waitingForPhone)),
               size: CGSize(width: 400, height: 820), appearance: .darkAqua, titled: true,
               to: directory.appendingPathComponent("phone-window-waiting.png"))

        render(WorkspaceView().environment(ConduitStore.preview(.empty)).environment(WorkspaceRouter()),
               size: CGSize(width: 1000, height: 700), appearance: .aqua, titled: true,
               to: directory.appendingPathComponent("workspace-overview-empty-light.png"))
        return true
    }

    /// The window's own pixels from the window server. A process may always
    /// read its own windows; `CGWindowListCreateImage` is looked up at run
    /// time because the macOS 15 SDK no longer exposes it to Swift.
    private static func windowServerImage(of window: NSWindow) -> CGImage? {
        typealias Capture = @convention(c) (CGRect, UInt32, UInt32, UInt32) -> Unmanaged<CGImage>?
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "CGWindowListCreateImage") else { return nil }
        let capture = unsafeBitCast(symbol, to: Capture.self)
        let includingWindow: UInt32 = 1 << 3
        let boundsIgnoreFraming: UInt32 = 1 << 0, bestResolution: UInt32 = 1 << 3
        return capture(.null, includingWindow, UInt32(window.windowNumber), boundsIgnoreFraming | bestResolution)?
            .takeRetainedValue()
    }

    private static func render<Content: View>(_ view: Content, size: CGSize, appearance: NSAppearance.Name,
                                              titled: Bool, to url: URL) {
        let style: NSWindow.StyleMask = titled
            ? [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            : [.borderless]
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: style,
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.ignoresMouseEvents = true
        window.contentView = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height)
            .background(titled ? Color.clear : Color(nsColor: .windowBackgroundColor)))

        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        window.setFrameOrigin(CGPoint(x: screen.minX + 20, y: screen.minY + 20))
        window.orderBack(nil)

        // Let SwiftUI lay out lists and forms, resolve the toolbar and apply
        // the appearance.
        RunLoop.current.run(until: Date().addingTimeInterval(1.5))

        if let image = windowServerImage(of: window) {
            try? NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }
}
#endif
