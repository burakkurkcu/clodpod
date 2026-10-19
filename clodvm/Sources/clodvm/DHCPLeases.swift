import Foundation

// Reads the lease database of the host's bootpd, which serves addresses to NAT attached VMs.
enum DHCPLeases {
    static let path = "/var/db/dhcpd_leases"

    static func address(for macAddress: String) throws -> String? {
        guard FileManager.default.fileExists(atPath: path) else {
            return nil
        }
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        let target = normalize(macAddress)

        var best: (address: String, lease: UInt64)?
        for block in contents.components(separatedBy: "}") {
            var fields: [String: String] = [:]
            for line in block.split(separator: "\n") {
                let parts = line.trimmingCharacters(in: .whitespaces).split(separator: "=", maxSplits: 1)
                if parts.count == 2 {
                    fields[String(parts[0])] = String(parts[1])
                }
            }
            // hw_address is "<type>,<mac>" with leading zeros stripped from each octet.
            guard let hardware = fields["hw_address"]?.split(separator: ",").last,
                  normalize(String(hardware)) == target,
                  let address = fields["ip_address"] else {
                continue
            }
            let lease = UInt64(fields["lease"]?.replacingOccurrences(of: "0x", with: "") ?? "", radix: 16) ?? 0
            if lease >= best?.lease ?? 0 {
                best = (address, lease)
            }
        }
        return best?.address
    }

    private static func normalize(_ macAddress: String) -> String {
        macAddress.lowercased()
            .split(separator: ":")
            .map { String(Int($0, radix: 16) ?? -1, radix: 16) }
            .joined(separator: ":")
    }
}
