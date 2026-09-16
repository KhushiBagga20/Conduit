//
//  PairingSheet.swift
//  Conduit
//
//  The six digits both people compare before a phone and this Mac trust each
//  other. They come from both devices' keys and nonces, so a device in the
//  middle cannot make them agree.
//

import ConduitDesign
import ConduitState
import SwiftUI

struct PairingSheet: View {
    @Environment(ConduitStore.self) private var store
    let request: LinkPairingRequest

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "iphone.and.arrow.forward")
                .font(.system(size: 34))
                .foregroundStyle(.tint)

            VStack(spacing: 4) {
                Text("Pair with \(request.deviceName)")
                    .font(.title3.weight(.semibold))
                Text("Check that the phone shows these digits too.")
                    .foregroundStyle(.secondary)
            }

            Text(spaced(request.code))
                .font(.system(size: 34, weight: .semibold, design: .monospaced))
                .textSelection(.enabled)
                .padding(.vertical, 6)

            HStack {
                Button("Don't Pair") { store.commands?.rejectLinkPairing() }
                Button("Pair") { store.commands?.confirmLinkPairing() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(28)
        .frame(width: 360)
    }

    /// 123 456 reads more easily than 123456.
    private func spaced(_ code: String) -> String {
        guard code.count == 6 else { return code }
        let middle = code.index(code.startIndex, offsetBy: 3)
        return "\(code[code.startIndex ..< middle]) \(code[middle...])"
    }
}
