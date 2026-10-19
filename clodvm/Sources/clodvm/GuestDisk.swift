import Foundation

// Attaches a stopped VM's disk image on the host and mounts the guest's APFS Data volume with ownership enabled.
final class GuestDisk {
    let mountPoint: URL
    private let wholeDisk: String
    private let dataDevice: String

    static func mount(_ vm: VMDirectory) throws -> GuestDisk {
        guard geteuid() == 0 else {
            throw CLIError("writing guest system files requires root; run with sudo")
        }
        try vm.ensureStopped()

        let output = try runTool("/usr/bin/hdiutil", [
            "attach", "-imagekey", "diskimage-class=CRawDiskImage", "-nomount", "-readwrite", vm.diskURL.path
        ])
        guard let wholeDisk = wholeDiskIdentifier(in: output) else {
            throw CLIError("could not find attached disk in hdiutil output: \(output)")
        }

        do {
            let dataDevice = try dataVolume(on: wholeDisk)
            let mountPoint = FileManager.default.temporaryDirectory
                .appendingPathComponent("clodvm-\(vm.name)-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: mountPoint, withIntermediateDirectories: true)
            try runTool("/usr/sbin/diskutil", [
                "mount", "nobrowse", "-mountOptions", "owners", "-mountPoint", mountPoint.path, dataDevice
            ])
            return GuestDisk(mountPoint: mountPoint, wholeDisk: wholeDisk, dataDevice: dataDevice)
        } catch {
            _ = try? runTool("/usr/bin/hdiutil", ["detach", "-force", "/dev/\(wholeDisk)"])
            throw error
        }
    }

    private init(mountPoint: URL, wholeDisk: String, dataDevice: String) {
        self.mountPoint = mountPoint
        self.wholeDisk = wholeDisk
        self.dataDevice = dataDevice
    }

    func unmount() throws {
        try runTool("/usr/sbin/diskutil", ["unmount", dataDevice])
        try FileManager.default.removeItem(at: mountPoint)

        // diskutil may still hold the device briefly after unmounting.
        for _ in 0..<5 {
            if (try? runTool("/usr/bin/hdiutil", ["detach", "/dev/\(wholeDisk)"])) != nil {
                return
            }
            Thread.sleep(forTimeInterval: 1)
        }
        try runTool("/usr/bin/hdiutil", ["detach", "-force", "/dev/\(wholeDisk)"])
    }

    func path(_ relative: String) -> URL {
        relative.split(separator: "/").reduce(mountPoint) { $0.appendingPathComponent(String($1)) }
    }

    private static func wholeDiskIdentifier(in hdiutilOutput: String) -> String? {
        for line in hdiutilOutput.split(separator: "\n") {
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if fields.count >= 2, fields[1] == "GUID_partition_scheme" {
                return fields[0].replacingOccurrences(of: "/dev/", with: "")
            }
        }
        return nil
    }

    private static func dataVolume(on wholeDisk: String) throws -> String {
        let list = try runToolPlist("/usr/sbin/diskutil", ["list", "-plist", wholeDisk])
        let partitions = (list["AllDisksAndPartitions"] as? [[String: Any]])?.first?["Partitions"] as? [[String: Any]] ?? []
        guard let mainPartition = partitions.first(where: { $0["Content"] as? String == "Apple_APFS" })?["DeviceIdentifier"] as? String else {
            throw CLIError("no main APFS partition on \(wholeDisk)")
        }

        let info = try runToolPlist("/usr/sbin/diskutil", ["info", "-plist", mainPartition])
        guard let container = info["APFSContainerReference"] as? String else {
            throw CLIError("no APFS container on \(mainPartition)")
        }

        let apfs = try runToolPlist("/usr/sbin/diskutil", ["apfs", "list", "-plist", container])
        for entry in apfs["Containers"] as? [[String: Any]] ?? [] {
            for volume in entry["Volumes"] as? [[String: Any]] ?? [] {
                if (volume["Roles"] as? [String] ?? []).contains("Data"), let device = volume["DeviceIdentifier"] as? String {
                    return device
                }
            }
        }
        throw CLIError("no APFS Data volume in \(container)")
    }

    // MARK: - File helpers

    struct Owner {
        let uid: uid_t
        let gid: gid_t

        static let root = Owner(uid: 0, gid: 0)
    }

    func readPlist(_ relative: String) throws -> [String: Any] {
        let url = path(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return [:]
        }
        guard let plist = try PropertyListSerialization.propertyList(from: Data(contentsOf: url), format: nil) as? [String: Any] else {
            throw CLIError("invalid plist \(relative)")
        }
        return plist
    }

    func writePlist(_ plist: [String: Any], to relative: String, owner: Owner, mode: Int, format: PropertyListSerialization.PropertyListFormat = .binary) throws {
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: format, options: 0)
        try write(data, to: relative, owner: owner, mode: mode)
    }

    // Existing files are rewritten in place so launchd/loginwindow pick them up and their xattrs survive.
    func write(_ data: Data, to relative: String, owner: Owner, mode: Int) throws {
        let url = path(relative)
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: data)
            try handle.close()
        } else {
            try data.write(to: url)
        }
        try apply(owner: owner, mode: mode, to: url)
    }

    func makeDirectory(_ relative: String, owner: Owner, mode: Int) throws {
        let url = path(relative)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try apply(owner: owner, mode: mode, to: url)
    }

    private func apply(owner: Owner, mode: Int, to url: URL) throws {
        guard chown(url.path, owner.uid, owner.gid) == 0 else {
            throw CLIError("chown \(url.path) failed: \(String(cString: strerror(errno)))")
        }
        guard chmod(url.path, mode_t(mode)) == 0 else {
            throw CLIError("chmod \(url.path) failed: \(String(cString: strerror(errno)))")
        }
    }
}
