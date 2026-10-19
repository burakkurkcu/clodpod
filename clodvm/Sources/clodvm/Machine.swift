import Foundation
import Virtualization

enum Machine {
    static func configuration(for vm: VMDirectory, config: VMConfig, shares: [String: URL] = [:]) throws -> VZVirtualMachineConfiguration {
        guard let hardwareModel = VZMacHardwareModel(dataRepresentation: config.hardwareModel) else {
            throw CLIError("invalid hardware model in \(vm.configURL.path)")
        }
        guard hardwareModel.isSupported else {
            throw CLIError("hardware model of \(vm.name) is not supported on this host")
        }
        guard let machineIdentifier = VZMacMachineIdentifier(dataRepresentation: config.machineIdentifier) else {
            throw CLIError("invalid machine identifier in \(vm.configURL.path)")
        }
        guard let macAddress = VZMACAddress(string: config.macAddress) else {
            throw CLIError("invalid MAC address in \(vm.configURL.path)")
        }

        let platform = VZMacPlatformConfiguration()
        platform.hardwareModel = hardwareModel
        platform.machineIdentifier = machineIdentifier
        platform.auxiliaryStorage = VZMacAuxiliaryStorage(url: vm.nvramURL)

        let graphics = VZMacGraphicsDeviceConfiguration()
        graphics.displays = [
            VZMacGraphicsDisplayConfiguration(
                widthInPixels: config.display.width,
                heightInPixels: config.display.height,
                pixelsPerInch: config.display.pixelsPerInch
            )
        ]

        let disk = try VZDiskImageStorageDeviceAttachment(
            url: vm.diskURL,
            readOnly: false,
            cachingMode: .automatic,
            synchronizationMode: .full
        )

        let network = VZVirtioNetworkDeviceConfiguration()
        network.attachment = VZNATNetworkDeviceAttachment()
        network.macAddress = macAddress

        let configuration = VZVirtualMachineConfiguration()
        configuration.platform = platform
        configuration.bootLoader = VZMacOSBootLoader()
        configuration.cpuCount = config.cpuCount
        configuration.memorySize = config.memoryMB * 1024 * 1024
        configuration.graphicsDevices = [graphics]
        configuration.storageDevices = [VZVirtioBlockDeviceConfiguration(attachment: disk)]
        configuration.networkDevices = [network]
        configuration.keyboards = [VZMacKeyboardConfiguration()]
        configuration.pointingDevices = [VZMacTrackpadConfiguration(), VZUSBScreenCoordinatePointingDeviceConfiguration()]
        configuration.entropyDevices = [VZVirtioEntropyDeviceConfiguration()]
        configuration.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]

        if !shares.isEmpty {
            // The automount tag makes macOS guests mount every share under "/Volumes/My Shared Files/<name>".
            let fileSystem = VZVirtioFileSystemDeviceConfiguration(tag: VZVirtioFileSystemDeviceConfiguration.macOSGuestAutomountTag)
            fileSystem.share = VZMultipleDirectoryShare(directories: shares.mapValues { VZSharedDirectory(url: $0, readOnly: false) })
            configuration.directorySharingDevices = [fileSystem]
        }

        try configuration.validate()
        return configuration
    }
}
