//
//  ClipboardPage.swift
//  Conduit
//
//  Clipboard sync as it works today: through the mirroring session, in both
//  directions. Conduit keeps no clipboard history — clipboards hold
//  passwords and codes, and the safest history is none.
//

import ConduitDesign
import ConduitMedia
import ConduitState
import SwiftUI

struct ClipboardPage: View {
    @Environment(ConduitStore.self) private var store
    @Environment(WorkspaceRouter.self) private var router

    var body: some View {
        let controlReady = store.mirroring.session?.control.state == .connected

        PageScroll {
            SectionHeading(title: "Clipboard",
                           detail: "Copy on one device, paste on the other.")

            VStack(alignment: .leading, spacing: DesignTokens.Spacing.m) {
                HStack(spacing: DesignTokens.Spacing.s) {
                    StatusDot(controlReady && store.preferences.clipboardSync ? .connected : .idle, size: 8)
                    Text(statusText(controlReady: controlReady))
                        .font(DesignTokens.Typography.headline.font)
                }

                directionRow(symbol: "smartphone", title: "Phone → Mac",
                             detail: "Text you copy on the phone appears on this Mac's clipboard.",
                             enabled: store.preferences.clipboardSync)
                directionRow(symbol: "laptopcomputer", title: "Mac → Phone",
                             detail: "Press ⌘V over the phone screen to paste, or send the clipboard now.",
                             enabled: true)

                HStack {
                    Button {
                        store.commands?.sendMacClipboardToPhone()
                    } label: {
                        Label(DesignTokens.Term.sendClipboard, systemImage: "doc.on.clipboard")
                    }
                    .disabled(!controlReady)

                    if !store.mirroring.status.isActive {
                        Button("Start Mirroring") {
                            router.section = .phoneScreen
                            store.commands?.startMirroring(phoneID: nil)
                        }
                        .disabled(store.activePhone?.connection.isConnected != true)
                    }

                    Spacer()

                    Toggle("Sync phone clipboard", isOn: Binding(
                        get: { store.preferences.clipboardSync },
                        set: { value in store.commands?.updatePreferences { $0.clipboardSync = value } }))
                    .toggleStyle(.switch)
                }
            }
            .conduitCard(padding: DesignTokens.Spacing.xl)

            HStack(alignment: .top, spacing: DesignTokens.Spacing.m) {
                Image(systemName: "lock.shield")
                    .foregroundStyle(DesignTokens.Color.statusWorking.color)
                Text("Clipboards often hold passwords and one-time codes. Conduit syncs them only while mirroring, never keeps a history, and never writes clipboard text to its logs.")
                    .font(DesignTokens.Typography.callout.font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .navigationTitle("Clipboard")
    }

    private func statusText(controlReady: Bool) -> String {
        if !store.mirroring.status.isActive { return "Syncing starts when mirroring starts" }
        if !controlReady { return "Connecting…" }
        return store.preferences.clipboardSync ? "Syncing both ways" : "Mac → phone only"
    }

    private func directionRow(symbol: String, title: String, detail: String, enabled: Bool) -> some View {
        HStack(spacing: DesignTokens.Spacing.m) {
            Image(systemName: symbol)
                .frame(width: 22)
                .foregroundStyle(enabled ? DesignTokens.Color.accent.color : DesignTokens.Color.textTertiary.color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(DesignTokens.Typography.body.font)
                Text(detail)
                    .font(DesignTokens.Typography.callout.font)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
