import Foundation

#if os(macOS)
import Darwin

public enum NetworkIdentity {
    public static func localHostName() -> String {
        Host.current().localizedName ?? Host.current().name ?? "Mac"
    }

    public static func primaryLANAddress() -> String {
        var address: String?
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else {
            return "127.0.0.1"
        }
        defer { freeifaddrs(interfaces) }

        for interfacePointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = interfacePointer.pointee
            guard interface.ifa_addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            let name = String(cString: interface.ifa_name)
            guard !name.hasPrefix("lo") else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                interface.ifa_addr,
                socklen_t(interface.ifa_addr.pointee.sa_len),
                &hostname,
                socklen_t(hostname.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if result == 0 {
                let candidate = hostname.withUnsafeBufferPointer { buffer in
                    String(cString: buffer.baseAddress!)
                }
                if candidate.hasPrefix("192.168.") || candidate.hasPrefix("10.") || candidate.hasPrefix("172.") {
                    return candidate
                }
                address = address ?? candidate
            }
        }
        return address ?? "127.0.0.1"
    }
}
#endif
