import Foundation

// MARK: - Argument parsing

struct Args {
    private var flags: [String: String] = [:]

    init(_ arguments: [String]) {
        var i = 0
        while i < arguments.count {
            let arg = arguments[i]
            if arg.hasPrefix("--"), arg.count > 2 {
                let key = String(arg.dropFirst(2))
                let next = i + 1
                if next < arguments.count, !arguments[next].hasPrefix("--") {
                    flags[key] = arguments[next]
                    i += 2
                } else {
                    flags[key] = ""
                    i += 1
                }
            } else {
                i += 1
            }
        }
    }

    // A flag present without a value (e.g. `--emoji` with nothing after it) stores
    // an empty string internally. Treat that as absent so callers get nil rather
    // than silently writing an empty emoji/message.
    subscript(_ key: String) -> String? {
        guard let value = flags[key] else { return nil }
        return value.isEmpty ? nil : value
    }
}

// MARK: - Entry point

func printUsage() {
    print("""
    usage: attention-cli <command> [options]

    commands:
      pair invite  [--name NAME]
      pair join    --payload <attention://...> [--name NAME]
      pair status
      pair forget
      send         [--message TEXT]
      watch        [--interval N]
      ack          [--emoji EMOJI]
      inspect
    """)
}

Task {
    do {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            printUsage()
            exit(1)
        }
        let rest = Array(args.dropFirst())
        switch command {
        case "pair":    try await PairCommand.run(rest)
        case "send":    try await SendCommand.run(rest)
        case "watch":   try await WatchCommand.run(rest)
        case "ack":     try await AckCommand.run(rest)
        case "inspect": try await InspectCommand.run(rest)
        default:
            fputs("unknown command: \(command)\n", stderr)
            printUsage()
            exit(1)
        }
    } catch {
        fputs("error: \(error.localizedDescription)\n", stderr)
        exit(1)
    }
    exit(0)
}

dispatchMain()
