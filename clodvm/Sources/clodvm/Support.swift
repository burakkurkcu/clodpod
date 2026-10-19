import Foundation

struct CLIError: Error, CustomStringConvertible {
    let description: String

    init(_ description: String) {
        self.description = description
    }
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("clodvm: error: \(error)\n".utf8))
    exit(1)
}

func log(_ message: String) {
    FileHandle.standardError.write(Data("\(message)\n".utf8))
}

func runAsync(_ body: @escaping @MainActor () async throws -> Void) -> Never {
    Task { @MainActor in
        do {
            try await body()
            exit(0)
        } catch {
            fail(error)
        }
    }
    dispatchMain()
}

func printJSON(_ value: Any) throws {
    let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

struct Arguments {
    private(set) var positionals: [String] = []
    private var options: [String: [String]] = [:]
    private var flags: Set<String> = []

    init(_ arguments: [String], flags allowedFlags: Set<String> = [], options allowedOptions: Set<String> = []) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if allowedFlags.contains(argument) {
                flags.insert(argument)
            } else if allowedOptions.contains(argument) {
                guard index + 1 < arguments.count else {
                    throw CLIError("\(argument) requires a value")
                }
                index += 1
                options[argument, default: []].append(arguments[index])
            } else if argument.hasPrefix("--"), let separator = argument.firstIndex(of: "="),
                      allowedOptions.contains(String(argument[..<separator])) {
                let name = String(argument[..<separator])
                options[name, default: []].append(String(argument[argument.index(after: separator)...]))
            } else if argument.hasPrefix("-") {
                throw CLIError("unknown option \(argument)")
            } else {
                positionals.append(argument)
            }
            index += 1
        }
    }

    func has(_ flag: String) -> Bool {
        flags.contains(flag)
    }

    func value(_ option: String) -> String? {
        options[option]?.last
    }

    func values(_ option: String) -> [String] {
        options[option] ?? []
    }

    func integer(_ option: String) throws -> Int? {
        guard let raw = value(option) else {
            return nil
        }
        guard let number = Int(raw), number > 0 else {
            throw CLIError("\(option) requires a positive integer (got \(raw))")
        }
        return number
    }

    func positional(_ index: Int, _ usage: String) throws -> String {
        guard index < positionals.count else {
            throw CLIError("usage: clodvm \(usage)")
        }
        return positionals[index]
    }
}

@discardableResult
func runTool(_ executable: String, _ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    try process.run()
    let data = try output.fileHandleForReading.readToEnd() ?? Data()
    process.waitUntilExit()
    let text = String(decoding: data, as: UTF8.self)

    guard process.terminationStatus == 0 else {
        throw CLIError("\(executable) \(arguments.joined(separator: " ")) failed: \(text)")
    }
    return text
}

func runToolPlist(_ executable: String, _ arguments: [String]) throws -> [String: Any] {
    let output = try runTool(executable, arguments)
    guard let plist = try PropertyListSerialization.propertyList(from: Data(output.utf8), format: nil) as? [String: Any] else {
        throw CLIError("\(executable) \(arguments.joined(separator: " ")) did not return a plist")
    }
    return plist
}
