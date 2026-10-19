import Foundation

let usage = """
Usage: clodvm <command> [options]

Manage macOS virtual machines for clodpod (Apple Virtualization.framework).
VMs live in ~/.local/share/clodpod/vms (override with CLODVM_HOME).

Commands:
  ipsw                                 Print the latest restore image URL supported by this host
  create <name> --from-ipsw <path>     Install macOS from a restore image
         [--disk-size GB] [--cpu N] [--memory MB]
  provision <name> --user <name>       Offline setup of an installed VM (requires root):
         --password <password>         user, autologin, SSH, no Setup Assistant
         --authorized-keys <file> [--passwordless-sudo]
  inject-key <name> --user <name>      Replace a stopped guest user's authorized_keys (requires root)
         --authorized-keys <file>
  run <name> [--no-graphics]           Run a VM in the foreground until it stops
         [--recovery] [--dir name:path]...
  stop <name>                          Shut down a running VM (forced after 30 seconds)
  list [--format text|json] [--quiet]  List VMs
  get <name> [--format text|json]      Show VM settings and state
  set <name> [--cpu N] [--memory MB]   Change VM settings
         [--random-mac] [--random-serial]
  ip <name> [--wait seconds]           Print the VM's IP address from the host DHCP leases
  clone <source> <destination>         Copy-on-write clone of a stopped VM
  rename <name> <new-name>             Rename a stopped VM
  delete <name>                        Delete a stopped VM
"""

var arguments = Array(CommandLine.arguments.dropFirst())
guard !arguments.isEmpty else {
    print(usage)
    exit(1)
}
let command = arguments.removeFirst()

do {
    switch command {
    case "ipsw":
        try Commands.ipsw(arguments)
    case "create":
        try Commands.create(arguments)
    case "provision":
        try Commands.provision(arguments)
    case "inject-key":
        try Commands.injectKey(arguments)
    case "run":
        try Commands.run(arguments)
    case "stop":
        try Commands.stop(arguments)
    case "list":
        try Commands.list(arguments)
    case "get":
        try Commands.get(arguments)
    case "set":
        try Commands.set(arguments)
    case "ip":
        try Commands.ip(arguments)
    case "clone":
        try Commands.clone(arguments)
    case "rename":
        try Commands.rename(arguments)
    case "delete":
        try Commands.delete(arguments)
    case "help", "-h", "--help":
        print(usage)
    default:
        throw CLIError("unknown command \(command)\n\(usage)")
    }
} catch {
    fail(error)
}
