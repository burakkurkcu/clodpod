import Foundation

struct VMConfig: Codable {
    struct Display: Codable {
        var width: Int
        var height: Int
        var pixelsPerInch: Int
    }

    var hardwareModel: Data
    var machineIdentifier: Data
    var cpuCount: Int
    var memoryMB: UInt64
    var macAddress: String
    var display: Display
    var osVersion: String
    var osBuild: String
}

enum VMStore {
    static var root: URL {
        if let override = ProcessInfo.processInfo.environment["CLODVM_HOME"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return invokingUserHome
            .appendingPathComponent(".local/share/clodpod/vms", isDirectory: true)
    }

    // Under sudo, HOME may point at root; VMs always belong to the invoking user.
    private static var invokingUserHome: URL {
        if geteuid() == 0, let sudoUser = ProcessInfo.processInfo.environment["SUDO_USER"],
           let entry = getpwnam(sudoUser) {
            return URL(fileURLWithPath: String(cString: entry.pointee.pw_dir), isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    static func validate(_ name: String) throws {
        guard name.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#, options: .regularExpression) != nil else {
            throw CLIError("invalid VM name (\(name))")
        }
    }

    static func vm(_ name: String) throws -> VMDirectory {
        try validate(name)
        return VMDirectory(name: name, url: root.appendingPathComponent(name, isDirectory: true))
    }

    static func existing(_ name: String) throws -> VMDirectory {
        let vm = try vm(name)
        guard vm.exists else {
            throw CLIError("VM \(name) does not exist")
        }
        return vm
    }

    static func all() throws -> [VMDirectory] {
        guard FileManager.default.fileExists(atPath: root.path) else {
            return []
        }
        return try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { VMDirectory(name: $0, url: root.appendingPathComponent($0, isDirectory: true)) }
            .filter { $0.exists }
    }

    static func ensureRoot() throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }
}

struct VMDirectory {
    let name: String
    let url: URL

    var configURL: URL { url.appendingPathComponent("config.json") }
    var diskURL: URL { url.appendingPathComponent("disk.img") }
    var nvramURL: URL { url.appendingPathComponent("nvram.bin") }
    var lockURL: URL { url.appendingPathComponent("run.lock") }

    var exists: Bool {
        FileManager.default.fileExists(atPath: configURL.path)
    }

    func loadConfig() throws -> VMConfig {
        try JSONDecoder().decode(VMConfig.self, from: Data(contentsOf: configURL))
    }

    func save(_ config: VMConfig) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: configURL, options: .atomic)
    }

    var diskSizeBytes: UInt64 {
        let attributes = try? FileManager.default.attributesOfItem(atPath: diskURL.path)
        return (attributes?[.size] as? NSNumber)?.uint64Value ?? 0
    }

    // A running VM holds an exclusive flock on run.lock for the lifetime of its `clodvm run` process.
    var runningPID: pid_t? {
        let fd = open(lockURL.path, O_RDONLY)
        guard fd >= 0 else {
            return nil
        }
        defer { close(fd) }

        if flock(fd, LOCK_SH | LOCK_NB) == 0 {
            flock(fd, LOCK_UN)
            return nil
        }
        let contents = (try? String(contentsOf: lockURL, encoding: .utf8)) ?? ""
        return pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    var state: String {
        runningPID == nil ? "stopped" : "running"
    }

    func ensureStopped() throws {
        guard runningPID == nil else {
            throw CLIError("VM \(name) is running")
        }
    }

    func acquireRunLock() throws -> Int32 {
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o644)
        guard fd >= 0 else {
            throw CLIError("cannot open \(lockURL.path)")
        }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw CLIError("VM \(name) is already running")
        }
        ftruncate(fd, 0)
        let pid = Data("\(getpid())\n".utf8)
        _ = pid.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
        return fd
    }
}
