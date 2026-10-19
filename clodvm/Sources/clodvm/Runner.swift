import AppKit
import Foundation
import Virtualization

final class Runner: NSObject, NSApplicationDelegate, NSWindowDelegate, VZVirtualMachineDelegate {
    static let gracefulStopTimeout: TimeInterval = 30

    private let name: String
    private let machine: VZVirtualMachine
    private let display: VMConfig.Display
    private let showWindow: Bool
    private let recovery: Bool
    private var window: NSWindow?
    private var signalSources: [DispatchSourceSignal] = []
    private var stopRequested = false

    init(name: String, configuration: VZVirtualMachineConfiguration, display: VMConfig.Display, showWindow: Bool, recovery: Bool) {
        self.name = name
        self.machine = VZVirtualMachine(configuration: configuration)
        self.display = display
        self.showWindow = showWindow
        self.recovery = recovery
        super.init()
        machine.delegate = self
    }

    func run() -> Never {
        let application = NSApplication.shared
        application.setActivationPolicy(showWindow ? .regular : .prohibited)
        application.delegate = self
        application.run()
        exit(0)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for signalNumber in [SIGTERM, SIGINT, SIGHUP] {
            signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .main)
            source.setEventHandler { [weak self] in
                self?.requestStop()
            }
            source.resume()
            signalSources.append(source)
        }

        if showWindow {
            makeWindow()
        }

        let options = VZMacOSVirtualMachineStartOptions()
        options.startUpFromMacOSRecovery = recovery
        machine.start(options: options) { error in
            if let error {
                fail(error)
            }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        requestStop()
        return .terminateCancel
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        requestStop()
        return false
    }

    func guestDidStop(_ virtualMachine: VZVirtualMachine) {
        exit(0)
    }

    func virtualMachine(_ virtualMachine: VZVirtualMachine, didStopWithError error: Error) {
        fail(error)
    }

    // First request asks the guest to shut down; a second request, or the timeout, powers it off.
    private func requestStop() {
        guard !stopRequested, machine.canRequestStop else {
            forceStop()
            return
        }
        stopRequested = true
        do {
            try machine.requestStop()
        } catch {
            forceStop()
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Runner.gracefulStopTimeout) { [weak self] in
            self?.forceStop()
        }
    }

    private func forceStop() {
        guard machine.canStop else {
            exit(0)
        }
        machine.stop { error in
            if let error {
                fail(error)
            }
            exit(0)
        }
    }

    private func makeWindow() {
        let quitItem = NSMenuItem(title: "Stop \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let applicationMenu = NSMenu()
        applicationMenu.addItem(quitItem)
        let applicationMenuItem = NSMenuItem()
        applicationMenuItem.submenu = applicationMenu
        let mainMenu = NSMenu()
        mainMenu.addItem(applicationMenuItem)
        NSApp.mainMenu = mainMenu

        let view = VZVirtualMachineView()
        view.virtualMachine = machine
        view.capturesSystemKeys = true
        view.automaticallyReconfiguresDisplay = true

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: display.width, height: display.height),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = name
        window.contentView = view
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }
}
