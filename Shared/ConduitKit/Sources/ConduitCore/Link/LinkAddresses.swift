//
//  LinkAddresses.swift
//  ConduitCore
//
//  This Mac's IPv4 addresses, to tell a phone where Conduit Link listens.
//

import Darwin
import Foundation

nonisolated enum LinkAddresses {

    /// Up, non-loopback IPv4 addresses, Wi-Fi and Ethernet first — the ones a
    /// phone on the same network or on its own hotspot can reach.
    static func ipv4() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var found: [(interface: String, address: String)] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            let flags = Int32(entry.ifa_flags)
            guard let socket = entry.ifa_addr, socket.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0
            else { continue }

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(socket, socklen_t(socket.pointee.sa_len), &host, socklen_t(host.count),
                              nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let address = String(cString: host)
            // Link-local addresses only work on a cable between the two.
            guard !address.hasPrefix("169.254.") else { continue }
            found.append((String(cString: entry.ifa_name), address))
        }
        return found
            .sorted { ($0.interface.hasPrefix("en") ? 0 : 1) < ($1.interface.hasPrefix("en") ? 0 : 1) }
            .map(\.address)
    }
}
