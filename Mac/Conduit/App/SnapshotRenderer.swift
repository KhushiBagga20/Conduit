//
//  SnapshotRenderer.swift
//  Conduit
//
//  Debug builds only. Renders the interfaces offscreen with preview data
//  and writes PNGs, so layout can be checked without screen capture:
//
//      Conduit.app/Contents/MacOS/Conduit --render-snapshots <directory>
//
//  Views are hosted in offscreen windows and drawn with cacheDisplay, which
//  needs no Screen Recording permission because it only reads Conduit's own
//  view hierarchy.
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
                let store = ConduitStore.preview(scenario)
                render(MenuBarPanel().environment(store).environment(WorkspaceRouter()),
                       size: CGSize(width: 340, height: 520), appearance: appearance,
                       to: directory.appendingPathComponent("menubar-\(scenario.rawValue)-\(suffix).png"))
            }

            // Scroll views and lists do not draw into offscreen captures, so
            // pages are rendered on their own without their scroll container
            // (see PageScroll). The sidebar and forms are stock controls.
            for section in [WorkspaceRouter.Section.overview, .phoneScreen, .devices, .clipboard, .calls] {
                for scenario in [ConduitStore.PreviewScenario.connected, .empty] {
                    let store = ConduitStore.preview(scenario)
                    render(page(section).environment(store).environment(WorkspaceRouter())
                               .environment(\.isRenderingSnapshot, true),
                           size: CGSize(width: 860, height: section == .overview ? 1180 : 720), appearance: appearance,
                           to: directory.appendingPathComponent("page-\(section.rawValue)-\(scenario.rawValue)-\(suffix).png"))
                }
            }
        }
        return true
    }

    @ViewBuilder
    private static func page(_ section: WorkspaceRouter.Section) -> some View {
        switch section {
        case .overview: OverviewPage()
        case .phoneScreen: PhoneScreenPage()
        case .devices: DevicesPage()
        case .clipboard: ClipboardPage()
        default: PlannedFeaturePage(section: section)
        }
    }

    private static func render<Content: View>(_ view: Content, size: CGSize,
                                              appearance: NSAppearance.Name, to url: URL) {
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: view
            .frame(width: size.width, height: size.height, alignment: .top)
            .background(Color(nsColor: .windowBackgroundColor)))
        window.setFrameOrigin(CGPoint(x: -10_000, y: -10_000))
        window.orderFrontRegardless()

        // Let SwiftUI lay out, resolve the toolbar and run appearance updates.
        RunLoop.current.run(until: Date().addingTimeInterval(1.2))

        guard let frameView = window.contentView?.superview else { return }
        let bounds = frameView.bounds
        if let rep = frameView.bitmapImageRepForCachingDisplay(in: bounds) {
            frameView.cacheDisplay(in: bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: url)
        }
        window.orderOut(nil)
    }
}
#endif
