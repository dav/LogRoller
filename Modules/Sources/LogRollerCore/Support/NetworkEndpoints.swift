import Foundation
import Darwin

public enum LogRollerNetwork {
    public static func primaryIngestBaseURL(port: UInt16) -> String {
        ingestBaseURLs(port: port).first ?? "https://localhost:\(port)"
    }

    public static func ingestBaseURLs(port: UInt16) -> [String] {
        let addresses = localInterfaceAddresses()
        var hosts: [String] = []

        // Prefer a LAN-reachable IPv4 on common Wi-Fi interfaces first.
        let preferredIPv4 = addresses
            .filter { $0.family == AF_INET }
            .sorted { lhs, rhs in
                interfacePriority(lhs.name) < interfacePriority(rhs.name)
            }
            .map(\.address)

        hosts.append(contentsOf: preferredIPv4)

        if let hostName = Host.current().name, isUsableHostName(hostName) {
            hosts.append(hostName)
        }

        hosts.append("localhost")

        let preferredIPv6 = addresses
            .filter { $0.family == AF_INET6 }
            .sorted { lhs, rhs in
                interfacePriority(lhs.name) < interfacePriority(rhs.name)
            }
            .map(\.address)
        hosts.append(contentsOf: preferredIPv6)

        var seen: Set<String> = []
        let uniqueHosts = hosts.filter { host in
            seen.insert(host).inserted
        }

        return uniqueHosts.map { host in
            if host.contains(":") {
                // RFC 6874: scope zone ID in IPv6 literals must escape "%" as "%25" in URIs.
                let escapedHost = host.replacingOccurrences(of: "%", with: "%25")
                return "https://[\(escapedHost)]:\(port)"
            }
            return "https://\(host):\(port)"
        }
    }

    public static func certificateHosts() -> [String] {
        var hosts: [String] = ["localhost", "127.0.0.1", "::1"]

        if let hostName = Host.current().name, isUsableHostName(hostName) {
            hosts.append(hostName)
        }

        let ipv4Addresses = localInterfaceAddresses()
            .filter { $0.family == AF_INET }
            .map(\.address)
        hosts.append(contentsOf: ipv4Addresses)

        var seen: Set<String> = []
        return hosts.filter { host in
            seen.insert(host).inserted
        }
    }

    private static func interfacePriority(_ name: String) -> Int {
        switch name {
        case "en0":
            return 0
        case "en1":
            return 1
        case "bridge100":
            return 2
        default:
            return 50
        }
    }

    private static func isUsableHostName(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && !trimmed.contains(" ")
    }

    private static func localInterfaceAddresses() -> [InterfaceAddress] {
        var pointer: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&pointer) == 0, let first = pointer else {
            return []
        }
        defer { freeifaddrs(first) }

        var result: [InterfaceAddress] = []
        var current: UnsafeMutablePointer<ifaddrs>? = first
        while let interface = current?.pointee {
            defer { current = interface.ifa_next }

            let flags = Int32(interface.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            let interfaceName = String(cString: interface.ifa_name)
            guard isUp, !isLoopback, let addressPointer = interface.ifa_addr else {
                continue
            }
            guard isReachableClientInterface(interfaceName) else {
                continue
            }

            let family = Int32(addressPointer.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else {
                continue
            }

            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let addressLength: socklen_t = family == AF_INET
                ? socklen_t(MemoryLayout<sockaddr_in>.size)
                : socklen_t(MemoryLayout<sockaddr_in6>.size)

            let status = getnameinfo(
                addressPointer,
                addressLength,
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )

            guard status == 0 else {
                continue
            }

            let terminatorIndex = hostBuffer.firstIndex(of: 0) ?? hostBuffer.count
            let addressBytes = hostBuffer[..<terminatorIndex].map { UInt8(bitPattern: $0) }
            let address = String(decoding: addressBytes, as: UTF8.self)
            guard !address.isEmpty else {
                continue
            }

            result.append(InterfaceAddress(name: interfaceName, address: address, family: family))
        }

        return result
    }

    private static func isReachableClientInterface(_ interfaceName: String) -> Bool {
        interfaceName.hasPrefix("en") || interfaceName == "bridge100"
    }

    private struct InterfaceAddress {
        var name: String
        var address: String
        var family: Int32
    }
}
