import Foundation

/// Only processes belonging to Highball's prefixes count. Inherited WINEPREFIX also
/// covers games installed on Z: or a symlinked/external Steam library, whose cwd is outside
/// the prefix. argv's executable is matched, never another process's command-line text.
enum DiscordGameDetection {
    struct ProcessSnapshot {
        let pid: pid_t
        let arguments: [String]
        let prefix: String?
        let workingDirectory: String
    }
    static func snapshots() -> [ProcessSnapshot] {
        ProcessTable.allPIDs().compactMap { pid in
            guard pid != ProcessInfo.processInfo.processIdentifier,
                  let command = ProcessTable.commandLineAndEnvironment(of: pid),
                  let cwd = ProcessTable.workingDirectory(of: pid) else { return nil }
            return ProcessSnapshot(pid: pid, arguments: command.arguments,
                                   prefix: command.environment["WINEPREFIX"], workingDirectory: cwd)
        }
    }
    static func detect(bottles: [Bottle], steamGames: [String: [SteamGame]], processes: [ProcessSnapshot],
                       started: [String: Date], now: Date = Date()) -> [DiscordRunningGame] {
        var games: [DiscordRunningGame] = []
        var seen = Set<String>()
        for bottle in bottles {
            let root = ProcessTable.canonical(bottle.url.path)
            let server = ProcessTable.serverDirectory(forPrefix: bottle.url).map { ProcessTable.canonical($0.path) }
            for process in processes {
                let belongs = process.prefix.map { ProcessTable.canonical($0) == root }
                    ?? ProcessTable.belongs(workingDirectory: ProcessTable.canonical(process.workingDirectory), toPrefix: root, serverDirectory: server)
                guard belongs,
                      let exe = process.arguments.first(where: { $0.lowercased().hasSuffix(".exe") }) else { continue }
                let name = DiscordGameCatalog.basename(exe)
                guard !["steam.exe", "steamwebhelper.exe", "epicgameslauncher.exe", "highball-discord-bridge.exe",
                        "wineboot.exe", "services.exe", "winedevice.exe", "explorer.exe", "svchost.exe", "rpcss.exe",
                        "plugplay.exe", "conhost.exe", "start.exe", "cmd.exe", "reg.exe", "msiexec.exe"].contains(name) else { continue }
                let path = exe.replacingOccurrences(of: "\\", with: "/").lowercased()
                let steam = steamGames[bottle.name]?.first { game in
                    guard !game.installdir.isEmpty else { return false }
                    if path.contains("steamapps/common/\(game.installdir.lowercased())/") { return true }
                    return game.installFolder.map { path.hasPrefix($0.resolvingSymlinksInPath().path.lowercased() + "/") } ?? false
                }
                let pins = bottle.settings.pins.filter { DiscordGameCatalog.basename($0.path) == name }
                let pin = pins.count == 1 ? pins.first : nil
                let identity = "\(root)#\(steam.map { "steam:\($0.appid)" } ?? path)"
                guard seen.insert(identity).inserted else { continue }
                games.append(DiscordRunningGame(identity: identity, title: steam?.name ?? pin?.name ?? "",
                                                steamID: steam?.appid, executable: exe,
                                                started: started[identity] ?? now))
            }
        }
        return games
    }
}

extension DiscordPresence {
    /// A process scan also discovers games started from Steam's own window, other launchers,
    /// or before Highball opened. Watching only beginSession() would miss those cases.
    public func runningGames(bottles: [Bottle], steamGames: [String: [SteamGame]], previous: [DiscordRunningGame]) -> [DiscordRunningGame] {
        let started = Dictionary(previous.map { ($0.identity, $0.started) }, uniquingKeysWith: { first, _ in first })
        return DiscordGameDetection.detect(bottles: bottles, steamGames: steamGames,
                                           processes: DiscordGameDetection.snapshots(), started: started)
    }
}
