//
//  WorkspaceRouter.swift
//  Conduit
//
//  Which workspace section is showing. Shared by the menu bar (which can
//  open the workspace at a section) and the workspace itself.
//

import ConduitProtocol
import Observation
import SwiftUI

@Observable
final class WorkspaceRouter {

    static let windowID = "workspace"

    enum Section: String, CaseIterable, Identifiable, Hashable {
        case overview, phoneScreen, trackpad, camera, calls, links, clipboard, activity, devices, settings

        var id: String { rawValue }

        var title: String {
            switch self {
            case .overview: "Overview"
            case .phoneScreen: "Phone Screen"
            case .trackpad: "Trackpad"
            case .camera: "Camera"
            case .calls: "Calls"
            case .links: "Link Sharing"
            case .clipboard: "Clipboard"
            case .activity: "Activity"
            case .devices: "Devices"
            case .settings: "Settings"
            }
        }

        var symbol: String {
            switch self {
            case .overview: "square.grid.2x2"
            case .phoneScreen: "rectangle.on.rectangle"
            case .trackpad: "hand.point.up.left"
            case .camera: "camera"
            case .calls: "phone"
            case .links: "link"
            case .clipboard: "doc.on.clipboard"
            case .activity: "clock.arrow.circlepath"
            case .devices: "smartphone"
            case .settings: "gearshape"
            }
        }

        /// The feature whose availability this section reflects, if any.
        var feature: FeatureID? {
            switch self {
            case .phoneScreen: .mirroring
            case .trackpad: .trackpad
            case .camera: .camera
            case .calls: .calls
            case .links: .links
            case .clipboard: .clipboard
            default: nil
            }
        }

        /// ⌘1…⌘9. Settings has none here: ⌘, opens the Settings window.
        var shortcut: KeyEquivalent? {
            switch self {
            case .overview: "1"
            case .phoneScreen: "2"
            case .trackpad: "3"
            case .camera: "4"
            case .calls: "5"
            case .links: "6"
            case .clipboard: "7"
            case .activity: "8"
            case .devices: "9"
            case .settings: nil
            }
        }
    }

    var section: Section = .overview
}

/// ⌘1…⌘9 jump between sections, as in other sidebar-driven Mac apps.
struct WorkspaceCommands: Commands {
    let router: WorkspaceRouter

    var body: some Commands {
        CommandMenu("Go") {
            ForEach(WorkspaceRouter.Section.allCases.filter { $0.shortcut != nil }) { section in
                Button(section.title) { router.section = section }
                    .keyboardShortcut(section.shortcut!, modifiers: .command)
            }
        }
    }
}
