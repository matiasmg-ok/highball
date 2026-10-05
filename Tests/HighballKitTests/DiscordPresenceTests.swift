import XCTest
import Darwin
@testable import HighballKit

final class DiscordPresenceTests: XCTestCase {
    private let catalogData = Data(#"""
    [{"id":"356942674672091136","name":"Geometry Dash","aliases":["GD"],
      "executables":[{"name":"geometry dash/geometrydash.exe","os":"win32"}],
      "third_party_skus":[{"distributor":"steam","id":"322170"},{"distributor":"battlenet","id":null}]},
     {"id":"2","name":"First","executables":[{"name":"game.exe","os":"win32"}]},
     {"id":"3","name":"Second","executables":[{"name":"game.exe","os":"win32"}]},
     {"id":"4","name":"A launcher","executables":[{"name":"launcher.exe","os":"win32","is_launcher":true}]}]
    """#.utf8)

    func testCurrentPublicCatalogWhenProvided() throws {
        guard let path = ProcessInfo.processInfo.environment["HIGHBALL_DISCORD_CATALOG_FIXTURE"] else {
            throw XCTSkip("Set HIGHBALL_DISCORD_CATALOG_FIXTURE to validate a downloaded public catalog")
        }
        let catalog = try DiscordGameCatalog(data: Data(contentsOf: URL(fileURLWithPath: path)))
        XCTAssertGreaterThan(catalog.applications.count, 1000)
        XCTAssertEqual(catalog.match(steamID: 322170, title: "Renamed game", executable: nil)?.name, "Geometry Dash")
    }

    func testCatalogPrefersSteamIDAndRejectsAmbiguousExecutables() throws {
        let catalog = try DiscordGameCatalog(data: catalogData)
        XCTAssertEqual(catalog.match(steamID: 322170, title: "My renamed game", executable: nil)?.name, "Geometry Dash")
        XCTAssertEqual(catalog.match(steamID: nil, title: "gd", executable: nil)?.id, "356942674672091136")
        XCTAssertEqual(catalog.match(steamID: nil, title: "", executable: #"C:\Games\GeometryDash.exe"#)?.name, "Geometry Dash")
        XCTAssertNil(catalog.match(steamID: nil, title: "", executable: "game.exe"))
        XCTAssertNil(catalog.match(steamID: nil, title: "", executable: "launcher.exe"))
        XCTAssertNil(catalog.match(steamID: nil, title: "Geometry", executable: nil))
    }

    func testDetectionScopesGamesToTheirPrefixAndHandlesExternalLibrary() {
        let a = Bottle(url: URL(fileURLWithPath: "/tmp/highball-presence-a"), settings: BottleSettings(name: "a", engineID: "test"))
        let b = Bottle(url: URL(fileURLWithPath: "/tmp/highball-presence-b"), settings: BottleSettings(name: "b", engineID: "test"))
        let game = SteamGame(appid: 322170, name: "Geometry Dash", installdir: "Geometry Dash", sizeOnDisk: 0, stateFlags: 4, lastPlayed: nil)
        let processes = [
            DiscordGameDetection.ProcessSnapshot(pid: 1, arguments: [#"D:\SteamLibrary\steamapps\common\Geometry Dash\GeometryDash.exe"#], prefix: a.url.path, workingDirectory: "/Volumes/Games"),
            DiscordGameDetection.ProcessSnapshot(pid: 2, arguments: ["steam.exe", "-applaunch", "322170"], prefix: a.url.path, workingDirectory: a.driveC.path),
            DiscordGameDetection.ProcessSnapshot(pid: 3, arguments: ["GeometryDash.exe"], prefix: "/tmp/another-app", workingDirectory: a.driveC.path),
            DiscordGameDetection.ProcessSnapshot(pid: 4, arguments: ["highball-discord-bridge.exe"], prefix: a.url.path, workingDirectory: a.driveC.path),
        ]
        let games = DiscordGameDetection.detect(bottles: [a, b], steamGames: ["a": [game]], processes: processes, started: [:])
        XCTAssertEqual(games.count, 1)
        XCTAssertEqual(games.first?.steamID, 322170)
        let since = Date(timeIntervalSince1970: 100)
        let again = DiscordGameDetection.detect(bottles: [a], steamGames: ["a": [game]], processes: processes,
                                               started: [games[0].identity: since])
        XCTAssertEqual(again[0].started, since)
    }

    func testFragmentedFrameAndPIDTranslationPreserveRichData() throws {
        let (writer, reader) = try pair()
        let frame = try DiscordIPC.Frame(opcode: 1, json: ["cmd": "SET_ACTIVITY", "nonce": "n",
            "args": ["pid": 123, "activity": ["state": "In game", "secrets": ["join": "secret"], "assets": ["large_image": "map"]]]])
        DispatchQueue.global().async { for byte in frame.bytes { try? writer.write(Data([byte])) } }
        let received = try reader.readFrame(timeout: 2)
        let rewritten = try received.hostPID(456)
        XCTAssertEqual((rewritten.json?["args"] as? [String: Any])?["pid"] as? Int, 456)
        let activity = (rewritten.json?["args"] as? [String: Any])?["activity"] as? [String: Any]
        XCTAssertEqual((activity?["secrets"] as? [String: String])?["join"], "secret")
        XCTAssertEqual(rewritten.json?["nonce"] as? String, "n")
        XCTAssertEqual(received.activity, true)
        let ping = DiscordIPC.Frame(opcode: 3, payload: Data([0, 255, 1]))
        XCTAssertEqual(try ping.hostPID(456).bytes, ping.bytes)
    }

    func testRejectsOversizeAndTruncatedFrames() throws {
        let (writer, reader) = try pair()
        var header = Data([1, 0, 0, 0]); var size = UInt32(DiscordIPC.maximumPayload + 1).littleEndian
        withUnsafeBytes(of: &size) { header.append(contentsOf: $0) }
        try writer.write(header)
        XCTAssertThrowsError(try reader.readFrame(timeout: 1))
        let (writer2, reader2) = try pair()
        try writer2.write(Data([1, 0, 0])); writer2.stop()
        XCTAssertThrowsError(try reader2.readFrame(timeout: 1))
    }

    func testPassiveUsesGameIDClearsOnRichPresenceAndResumes() throws {
        let fake = try FakeDiscord()
        defer { fake.stop() }
        let presence = DiscordPresence(socketPaths: { [fake.path] })
        defer { presence.stop() }
        let catalog = try DiscordGameCatalog(data: catalogData)
        let game = DiscordRunningGame(identity: "gd", title: "My title", steamID: 322170, executable: nil, started: Date(timeIntervalSince1970: 123))
        presence.publish(games: [game], catalog: catalog)
        XCTAssertEqual(presence.status, "Sharing Geometry Dash")
        XCTAssertEqual(fake.handshakes.last, "356942674672091136")
        let id = UUID()
        presence.richActivity(id, active: true)
        presence.publish(games: [game], catalog: catalog)
        XCTAssertEqual(presence.status, "Game Rich Presence connected")
        XCTAssertEqual(fake.handshakes.count, 1)
        presence.richActivity(id, active: false)
        presence.publish(games: [game], catalog: catalog)
        XCTAssertEqual(presence.status, "Sharing Geometry Dash")
        XCTAssertEqual(fake.handshakes.count, 2)
        presence.publish(games: [], catalog: catalog)
        XCTAssertEqual(presence.status, "Waiting for a game")
    }

    func testPassiveReconnectsAfterDiscordRestartAndRespondsToPing() throws {
        let fake = try FakeDiscord()
        defer { fake.stop() }
        let presence = DiscordPresence(socketPaths: { [fake.path] })
        defer { presence.stop() }
        let catalog = try DiscordGameCatalog(data: catalogData)
        let game = DiscordRunningGame(identity: "gd", title: "Geometry Dash", steamID: 322170,
                                      executable: nil, started: Date())
        presence.publish(games: [game], catalog: catalog)
        try fake.ping()
        presence.publish(games: [game], catalog: catalog)
        XCTAssertEqual(fake.handshakes.count, 1, "Ping must not republish the activity")
        fake.disconnectClients()
        presence.publish(games: [game], catalog: catalog)
        presence.publish(games: [game], catalog: catalog)
        XCTAssertEqual(presence.status, "Sharing Geometry Dash")
        XCTAssertEqual(fake.handshakes.count, 2)
    }

    func testBridgeIsBidirectionalAndStopsConnections() throws {
        let fake = try FakeDiscord()
        defer { fake.stop() }
        let bridge = try DiscordBridge(socketPaths: { [fake.path] }) { _, _ in }
        defer { bridge.stop() }
        let client = try tcp(port: bridge.port)
        try client.write(Data(bridge.token.utf8) + Data([0]))
        try client.write(DiscordIPC.Frame(opcode: 0, json: ["v": 1, "client_id": "356942674672091136"]))
        XCTAssertEqual(try client.readFrame(timeout: 2).json?["evt"] as? String, "READY")
        try client.write(DiscordIPC.Frame(opcode: 1, json: ["cmd": "SET_ACTIVITY", "nonce": "win",
            "args": ["pid": 999, "activity": ["state": "A level"]]]))
        let reply = try client.readFrame(timeout: 2)
        XCTAssertEqual((reply.json?["args"] as? [String: Any])?["pid"] as? Int, Int(getpid()))
        XCTAssertEqual(reply.json?["nonce"] as? String, "win")
        bridge.stop()
        XCTAssertThrowsError(try client.readFrame(timeout: 2))
    }

    func testWineNamedPipeSmokeWhenRequested() throws {
        guard let enginePath = ProcessInfo.processInfo.environment["HIGHBALL_DISCORD_SMOKE_ENGINE"] else {
            throw XCTSkip("Set HIGHBALL_DISCORD_SMOKE_ENGINE to an installed engine directory for the Wine smoke")
        }
        let engineRoot = URL(fileURLWithPath: enginePath)
        let engine = InstalledEngine(manifest: try EngineManifest.load(from: engineRoot.appending(path: "manifest.json")), root: engineRoot)
        let root = URL(fileURLWithPath: "/tmp/hb-discord-smoke-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bottle = Bottle(url: root, settings: BottleSettings(name: "discord-smoke", engineID: engine.id))
        var env = engine.baseEnvironment().merging(ProcessInfo.processInfo.environment) { original, _ in original }
        env["WINEPREFIX"] = root.path; env["WINEDEBUG"] = "-all"
        env["WINEMSYNC"] = "0"; env["WINEESYNC"] = "0"
        let boot = Process(); boot.executableURL = engine.wineBinary; boot.arguments = ["wineboot.exe", "--init"]
        boot.environment = env; boot.standardOutput = FileHandle.nullDevice; boot.standardError = FileHandle.nullDevice
        try boot.run()
        defer {
            let kill = Process(); kill.executableURL = engine.wineserverBinary; kill.arguments = ["-k"]
            kill.environment = env; try? kill.run(); kill.waitUntilExit()
            try? FileManager.default.removeItem(at: root)
        }
        XCTAssertTrue(waitUntil(seconds: 90) { !boot.isRunning }, "Wine boot timed out")
        guard !boot.isRunning else { boot.terminate(); return }
        XCTAssertEqual(boot.terminationStatus, 0)
        let fake = try FakeDiscord()
        defer { fake.stop() }
        let presence = DiscordPresence(socketPaths: { [fake.path] })
        defer { presence.stop() }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let helper = repo.appending(path: "spike/discord-bridge/highball-discord-bridge.exe")
        let probe = repo.appending(path: "spike/discord-bridge/probe.exe")
        for cycle in 0..<2 {
            presence.ensureBridge(engine: engine, bottle: bottle, environment: env, helperURL: helper)
            for slot in [0, 9, 0] {
                let process = Process(), output = Pipe()
                process.executableURL = engine.wineBinary; process.arguments = [probe.path, String(slot)]
                process.environment = env; process.currentDirectoryURL = bottle.driveC
                process.standardOutput = output; process.standardError = FileHandle.nullDevice
                try process.run()
                XCTAssertTrue(waitUntil(seconds: 15) { !process.isRunning }, "Named-pipe probe hung (cycle \(cycle), slot \(slot))")
                guard !process.isRunning else { process.terminate(); return }
                XCTAssertEqual(process.terminationStatus, 0, "Wine pipe probe failed")
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let lines = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline)
                XCTAssertEqual(lines.count, 2)
                if let last = lines.last, let json = try JSONSerialization.jsonObject(with: Data(last.utf8)) as? [String: Any] {
                    XCTAssertEqual((json["args"] as? [String: Any])?["pid"] as? Int, Int(getpid()))
                    XCTAssertEqual(json["nonce"] as? String, "wine-probe")
                }
            }
            presence.stop()
            XCTAssertTrue(waitUntil(seconds: 5) {
                !ProcessTable.allPIDs().contains { pid in
                    guard let command = ProcessTable.commandLineAndEnvironment(of: pid), command.environment["WINEPREFIX"] == root.path else { return false }
                    return command.arguments.contains { $0.contains("highball-discord-bridge.exe") }
                }
            }, "Bridge shutdown left the Wine helper alive")
        }
    }

    private func waitUntil(seconds: TimeInterval, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while !condition() && Date() < deadline { usleep(20_000) }
        return condition()
    }

    private func pair() throws -> (DiscordSocket, DiscordSocket) {
        var fds: [Int32] = [-1, -1]
        guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw HighballError.failed("socketpair") }
        return (DiscordSocket(fd: fds[0]), DiscordSocket(fd: fds[1]))
    }
}

private func tcp(port: UInt16) throws -> DiscordSocket {
    let sock = try DiscordSocket(domain: AF_INET)
    var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET)
    addr.sin_addr.s_addr = inet_addr("127.0.0.1"); addr.sin_port = port.bigEndian
    let result = withUnsafePointer(to: &addr) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(sock.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    guard result == 0 else { throw HighballError.failed("connect") }
    return sock
}

/// Real local Unix sockets, with no network access and no activity sent to the user's Discord.
private final class FakeDiscord: @unchecked Sendable {
    let path = "/tmp/hb-\(UUID().uuidString.prefix(12)).sock"
    private let listener: DiscordSocket
    private let lock = NSLock()
    private var stopped = false
    private var sockets: [DiscordSocket] = []
    private var ids: [String] = []
    var handshakes: [String] { lock.withLock { ids } }
    init() throws {
        listener = try DiscordSocket(domain: AF_UNIX)
        let socket = listener
        var addr = sockaddr_un(); addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8CString)
        withUnsafeMutablePointer(to: &addr.sun_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { $0.update(from: bytes, count: bytes.count) }
        }
        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0, listen(socket.fd, 16) == 0 else { throw HighballError.failed("fake bind") }
        DispatchQueue.global().async { [self] in
            while !lock.withLock({ stopped }) {
                var p = pollfd(fd: socket.fd, events: Int16(POLLIN), revents: 0)
                guard poll(&p, 1, 100) > 0 else { continue }
                let fd = accept(socket.fd, nil, nil)
                guard fd >= 0 else { continue }
                let client = DiscordSocket(fd: fd)
                lock.withLock { sockets.append(client) }
                DispatchQueue.global().async { [self] in
                    do {
                        let handshake = try client.readFrame(timeout: 2)
                        lock.withLock { ids.append(handshake.json?["client_id"] as? String ?? "") }
                        try client.write(DiscordIPC.Frame(opcode: 1, json: ["cmd": "DISPATCH", "evt": "READY", "data": [:]]))
                        while true {
                            let frame = try client.readFrame()
                            try client.write(frame) // echo nonce and rewritten args
                        }
                    } catch { client.stop() }
                }
            }
        }
    }
    func ping() throws {
        guard let client = lock.withLock({ sockets.last }) else { throw HighballError.failed("No fake client") }
        try client.write(DiscordIPC.Frame(opcode: 3, payload: Data("ping".utf8)))
    }
    func disconnectClients() { lock.withLock { for client in sockets { client.stop() } } }
    func stop() {
        lock.withLock { stopped = true; listener.stop(); for client in sockets { client.stop() } }
        unlink(path)
    }
}
