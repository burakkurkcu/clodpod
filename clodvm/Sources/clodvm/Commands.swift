import Foundation
import Virtualization

enum Commands {
    static let defaultDisplay = VMConfig.Display(width: 1024, height: 768, pixelsPerInch: 80)

    static func ipsw(_ arguments: [String]) throws {
        _ = try Arguments(arguments)
        runAsync {
            let image = try await withCheckedThrowingContinuation { continuation in
                VZMacOSRestoreImage.fetchLatestSupported { continuation.resume(with: $0) }
            }
            print(image.url.absoluteString)
        }
    }

    static func create(_ arguments: [String]) throws {
        let args = try Arguments(arguments, options: ["--from-ipsw", "--disk-size", "--cpu", "--memory"])
        let vm = try VMStore.vm(try args.positional(0, "create <name> --from-ipsw <path> [--disk-size GB] [--cpu N] [--memory MB]"))
        guard let ipswPath = args.value("--from-ipsw") else {
            throw CLIError("create requires --from-ipsw <path>")
        }
        let ipswURL = URL(fileURLWithPath: ipswPath)
        let diskSizeGB = try args.integer("--disk-size") ?? 100
        let requestedCPU = try args.integer("--cpu") ?? 4
        let requestedMemoryMB = try args.integer("--memory") ?? 8192

        guard !vm.exists else {
            throw CLIError("VM \(vm.name) already exists")
        }
        try VMStore.ensureRoot()

        runAsync {
            let image = try await withCheckedThrowingContinuation { continuation in
                VZMacOSRestoreImage.load(from: ipswURL) { continuation.resume(with: $0) }
            }
            guard let requirements = image.mostFeaturefulSupportedConfiguration, requirements.hardwareModel.isSupported else {
                throw CLIError("restore image \(ipswPath) is not supported on this host")
            }

            let version = image.operatingSystemVersion
            let staging = VMDirectory(name: vm.name, url: VMStore.root.appendingPathComponent(".creating-\(vm.name)", isDirectory: true))
            if FileManager.default.fileExists(atPath: staging.url.path) {
                try FileManager.default.removeItem(at: staging.url)
            }
            try FileManager.default.createDirectory(at: staging.url, withIntermediateDirectories: true)

            do {
                _ = try VZMacAuxiliaryStorage(creatingStorageAt: staging.nvramURL, hardwareModel: requirements.hardwareModel)
                FileManager.default.createFile(atPath: staging.diskURL.path, contents: nil)
                let disk = try FileHandle(forWritingTo: staging.diskURL)
                try disk.truncate(atOffset: UInt64(diskSizeGB) * 1024 * 1024 * 1024)
                try disk.close()

                let config = VMConfig(
                    hardwareModel: requirements.hardwareModel.dataRepresentation,
                    machineIdentifier: VZMacMachineIdentifier().dataRepresentation,
                    cpuCount: max(requestedCPU, requirements.minimumSupportedCPUCount),
                    memoryMB: max(UInt64(requestedMemoryMB), requirements.minimumSupportedMemorySize / 1024 / 1024),
                    macAddress: VZMACAddress.randomLocallyAdministered().string,
                    display: defaultDisplay,
                    osVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                    osBuild: image.buildVersion
                )
                try staging.save(config)

                let machine = VZVirtualMachine(configuration: try Machine.configuration(for: staging, config: config))
                let installer = VZMacOSInstaller(virtualMachine: machine, restoringFromImageAt: ipswURL)
                var reported = -1
                let observation = installer.progress.observe(\.fractionCompleted, options: [.new]) { progress, _ in
                    let percent = Int(progress.fractionCompleted * 100)
                    if percent != reported {
                        reported = percent
                        log("Installing macOS \(config.osVersion) (\(config.osBuild)): \(percent)%")
                    }
                }
                try await withCheckedThrowingContinuation { continuation in
                    installer.install { continuation.resume(with: $0) }
                }
                observation.invalidate()

                try FileManager.default.moveItem(at: staging.url, to: vm.url)
            } catch {
                try? FileManager.default.removeItem(at: staging.url)
                throw error
            }
        }
    }

    static func provision(_ arguments: [String]) throws {
        let args = try Arguments(arguments, flags: ["--passwordless-sudo"], options: ["--user", "--password", "--authorized-keys"])
        let usage = "provision <name> --user <name> --password <password> --authorized-keys <file> [--passwordless-sudo]"
        let vm = try VMStore.existing(try args.positional(0, usage))
        guard let username = args.value("--user"), let password = args.value("--password"),
              let keysPath = args.value("--authorized-keys") else {
            throw CLIError("usage: clodvm \(usage)")
        }
        let config = try vm.loadConfig()
        let keys = try Data(contentsOf: URL(fileURLWithPath: keysPath))

        let disk = try GuestDisk.mount(vm)
        do {
            try Provisioner(
                disk: disk,
                username: username,
                password: password,
                authorizedKeys: keys,
                passwordlessSudo: args.has("--passwordless-sudo"),
                osVersion: config.osVersion,
                osBuild: config.osBuild
            ).run()
        } catch {
            try? disk.unmount()
            throw error
        }
        try disk.unmount()
    }

    static func injectKey(_ arguments: [String]) throws {
        let args = try Arguments(arguments, options: ["--user", "--authorized-keys"])
        let usage = "inject-key <name> --user <name> --authorized-keys <file>"
        let vm = try VMStore.existing(try args.positional(0, usage))
        guard let username = args.value("--user"), let keysPath = args.value("--authorized-keys") else {
            throw CLIError("usage: clodvm \(usage)")
        }
        let keys = try Data(contentsOf: URL(fileURLWithPath: keysPath))

        let disk = try GuestDisk.mount(vm)
        do {
            let record = try disk.readPlist("\(Provisioner.usersDirectory)/\(username).plist")
            guard let uid = (record["uid"] as? [String])?.first.flatMap({ uid_t($0) }),
                  let gid = (record["gid"] as? [String])?.first.flatMap({ gid_t($0) }),
                  let home = (record["home"] as? [String])?.first else {
                throw CLIError("guest user \(username) not found in \(vm.name)")
            }
            try writeAuthorizedKeys(keys, disk: disk, home: String(home.drop(while: { $0 == "/" })), owner: GuestDisk.Owner(uid: uid, gid: gid))
        } catch {
            try? disk.unmount()
            throw error
        }
        try disk.unmount()
    }

    static func run(_ arguments: [String]) throws {
        let args = try Arguments(arguments, flags: ["--no-graphics", "--recovery"], options: ["--dir"])
        let vm = try VMStore.existing(try args.positional(0, "run <name> [--no-graphics] [--recovery] [--dir name:path]..."))
        let config = try vm.loadConfig()

        var shares: [String: URL] = [:]
        for spec in args.values("--dir") {
            guard let separator = spec.firstIndex(of: ":") else {
                throw CLIError("invalid --dir value (\(spec)), expected name:path")
            }
            let name = String(spec[..<separator])
            let path = String(spec[spec.index(after: separator)...])
            var isDirectory: ObjCBool = false
            guard !name.isEmpty, FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                throw CLIError("invalid --dir value (\(spec)), directory not found")
            }
            guard shares[name] == nil else {
                throw CLIError("duplicate --dir name (\(name))")
            }
            shares[name] = URL(fileURLWithPath: path, isDirectory: true)
        }

        let configuration = try Machine.configuration(for: vm, config: config, shares: shares)
        // Held open until the process exits; the kernel releases the lock if the runner crashes.
        _ = try vm.acquireRunLock()

        let runner = Runner(
            name: vm.name,
            configuration: configuration,
            display: config.display,
            showWindow: !args.has("--no-graphics"),
            recovery: args.has("--recovery")
        )
        // NSApplication only holds its delegate weakly.
        withExtendedLifetime(runner) {
            runner.run()
        }
    }

    static func stop(_ arguments: [String]) throws {
        let args = try Arguments(arguments)
        let vm = try VMStore.existing(try args.positional(0, "stop <name>"))

        var pid = vm.runningPID
        // The runner writes its pid right after taking the lock.
        for _ in 0..<50 where pid == 0 {
            Thread.sleep(forTimeInterval: 0.1)
            pid = vm.runningPID
        }
        guard let target = pid else {
            return
        }
        guard target > 0 else {
            throw CLIError("cannot determine runner pid for \(vm.name)")
        }

        kill(target, SIGTERM)
        if waitUntilStopped(vm, seconds: Runner.gracefulStopTimeout + 15) {
            return
        }
        kill(target, SIGKILL)
        guard waitUntilStopped(vm, seconds: 10) else {
            throw CLIError("VM \(vm.name) did not stop")
        }
    }

    private static func waitUntilStopped(_ vm: VMDirectory, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if vm.runningPID == nil {
                return true
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        return vm.runningPID == nil
    }

    static func list(_ arguments: [String]) throws {
        let args = try Arguments(arguments, flags: ["--quiet", "-q"], options: ["--format", "--source"])
        let source = args.value("--source") ?? "local"
        let vms = source == "local" ? try VMStore.all() : []

        if args.has("--quiet") || args.has("-q") {
            vms.forEach { print($0.name) }
        } else if args.value("--format") == "json" {
            try printJSON(vms.map { vm -> [String: Any] in
                ["Name": vm.name, "State": vm.state, "Source": "local", "Disk": vm.diskSizeBytes / 1_073_741_824]
            })
        } else {
            print("NAME".padding(toLength: 32, withPad: " ", startingAt: 0) + "STATE")
            vms.forEach { print($0.name.padding(toLength: 32, withPad: " ", startingAt: 0) + $0.state) }
        }
    }

    static func get(_ arguments: [String]) throws {
        let args = try Arguments(arguments, options: ["--format"])
        let vm = try VMStore.existing(try args.positional(0, "get <name> [--format text|json]"))
        let config = try vm.loadConfig()
        let details: [String: Any] = [
            "Name": vm.name,
            "State": vm.state,
            "CPU": config.cpuCount,
            "Memory": config.memoryMB,
            "Disk": vm.diskSizeBytes / 1_073_741_824,
            "Display": "\(config.display.width)x\(config.display.height)",
            "MACAddress": config.macAddress,
            "OS": "\(config.osVersion) (\(config.osBuild))"
        ]

        if args.value("--format") == "json" {
            try printJSON(details)
        } else {
            for key in details.keys.sorted() {
                print("\(key.padding(toLength: 12, withPad: " ", startingAt: 0))\(details[key]!)")
            }
        }
    }

    static func set(_ arguments: [String]) throws {
        let args = try Arguments(arguments, flags: ["--random-mac", "--random-serial"], options: ["--cpu", "--memory"])
        let vm = try VMStore.existing(try args.positional(0, "set <name> [--cpu N] [--memory MB] [--random-mac] [--random-serial]"))
        var config = try vm.loadConfig()

        if let cpu = try args.integer("--cpu") {
            config.cpuCount = cpu
        }
        if let memory = try args.integer("--memory") {
            config.memoryMB = UInt64(memory)
        }
        if args.has("--random-mac") {
            config.macAddress = VZMACAddress.randomLocallyAdministered().string
        }
        if args.has("--random-serial") {
            config.machineIdentifier = VZMacMachineIdentifier().dataRepresentation
        }
        try vm.save(config)
    }

    static func ip(_ arguments: [String]) throws {
        let args = try Arguments(arguments, options: ["--wait"])
        let vm = try VMStore.existing(try args.positional(0, "ip <name> [--wait seconds]"))
        let macAddress = try vm.loadConfig().macAddress
        let deadline = Date().addingTimeInterval(TimeInterval(try args.integer("--wait") ?? 0))

        while true {
            if let address = try DHCPLeases.address(for: macAddress) {
                print(address)
                return
            }
            guard Date() < deadline else {
                throw CLIError("no IP address found for \(vm.name)")
            }
            Thread.sleep(forTimeInterval: 1)
        }
    }

    static func clone(_ arguments: [String]) throws {
        let args = try Arguments(arguments)
        let source = try VMStore.existing(try args.positional(0, "clone <source> <destination>"))
        let destination = try VMStore.vm(try args.positional(1, "clone <source> <destination>"))
        try source.ensureStopped()
        guard !FileManager.default.fileExists(atPath: destination.url.path) else {
            throw CLIError("VM \(destination.name) already exists")
        }

        let staging = VMStore.root.appendingPathComponent(".cloning-\(destination.name)", isDirectory: true)
        if FileManager.default.fileExists(atPath: staging.path) {
            try FileManager.default.removeItem(at: staging)
        }
        guard clonefile(source.url.path, staging.path, 0) == 0 else {
            throw CLIError("clonefile \(source.url.path) failed: \(String(cString: strerror(errno)))")
        }
        let stagedLock = staging.appendingPathComponent("run.lock")
        if FileManager.default.fileExists(atPath: stagedLock.path) {
            try FileManager.default.removeItem(at: stagedLock)
        }
        try FileManager.default.moveItem(at: staging, to: destination.url)
    }

    static func rename(_ arguments: [String]) throws {
        let args = try Arguments(arguments)
        let vm = try VMStore.existing(try args.positional(0, "rename <name> <new-name>"))
        let destination = try VMStore.vm(try args.positional(1, "rename <name> <new-name>"))
        try vm.ensureStopped()
        guard !FileManager.default.fileExists(atPath: destination.url.path) else {
            throw CLIError("VM \(destination.name) already exists")
        }
        try FileManager.default.moveItem(at: vm.url, to: destination.url)
    }

    static func delete(_ arguments: [String]) throws {
        let args = try Arguments(arguments)
        let vm = try VMStore.existing(try args.positional(0, "delete <name>"))
        try vm.ensureStopped()
        try FileManager.default.removeItem(at: vm.url)
    }
}
