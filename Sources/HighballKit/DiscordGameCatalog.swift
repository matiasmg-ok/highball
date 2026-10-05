import Foundation

/// Discord's public detection catalog supplies the *game's* application id. No personal
/// Discord token or Highball application id is involved. The endpoint is undocumented;
/// keep the last valid catalog for offline use and fail without affecting game launches.
struct DiscordGameCatalog: Sendable {
    struct Application: Decodable, Sendable {
        struct SKU: Decodable, Sendable { let distributor: String; let id: String? }
        struct Executable: Decodable, Sendable { let name: String; let os: String; let is_launcher: Bool? }
        let id: String
        let name: String
        let aliases: [String]?
        let executables: [Executable]?
        let third_party_skus: [SKU]?
    }
    let applications: [Application]
    init(data: Data) throws { applications = try JSONDecoder().decode([Application].self, from: data) }

    func match(steamID: Int?, title: String, executable: String?) -> Application? {
        // Store ids win over names (localised titles and user renames are common).
        if let steamID {
            let matches = applications.filter { $0.third_party_skus?.contains { $0.distributor == "steam" && $0.id == String(steamID) } == true }
            if matches.count == 1 { return matches.first }
        }
        let byName = applications.filter { app in
            ([app.name] + (app.aliases ?? [])).contains { $0.caseInsensitiveCompare(title) == .orderedSame }
        }
        if byName.count == 1 { return byName.first }
        if let executable {
            let name = Self.basename(executable)
            let matches = applications.filter { app in app.executables?.contains {
                $0.os == "win32" && $0.is_launcher != true && Self.basename($0.name) == name
            } == true }
            if matches.count == 1 { return matches.first }
        }
        return nil   // Never guess from fuzzy titles or an ambiguous executable like game.exe.
    }
    static func basename(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/").split(separator: "/").last.map(String.init)?.lowercased() ?? ""
    }
}

actor DiscordCatalogStore {
    private var catalog: DiscordGameCatalog?
    private var lastAttempt = Date.distantPast
    private var cacheURL: URL?
    func load(paths: HighballPaths) async -> DiscordGameCatalog? {
        let url = paths.home.appending(path: "discord-games.json")
        if cacheURL != url {
            catalog = (try? Data(contentsOf: url)).flatMap { try? DiscordGameCatalog(data: $0) }
            cacheURL = url
            lastAttempt = .distantPast
        }
        let age = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            .map { Date().timeIntervalSince($0) } ?? .infinity
        guard age > 7 * 86400, Date().timeIntervalSince(lastAttempt) > 3600 else { return catalog }
        lastAttempt = Date()
        do {
            var request = URLRequest(url: URL(string: "https://discord.com/api/v10/applications/detectable")!)
            request.timeoutInterval = 15
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 32 * 1024 * 1024 else { return catalog }
            let fresh = try DiscordGameCatalog(data: data)
            guard !fresh.applications.isEmpty else { return catalog }
            catalog = fresh
            try? data.write(to: url, options: .atomic)
        } catch { /* The cached catalog still works when offline. */ }
        return catalog
    }
}

public struct DiscordRunningGame: Sendable, Equatable {
    public let identity: String
    public let title: String
    public let steamID: Int?
    public let executable: String?
    public let started: Date
    public init(identity: String, title: String, steamID: Int?, executable: String?, started: Date) {
        self.identity = identity; self.title = title; self.steamID = steamID
        self.executable = executable; self.started = started
    }
}
