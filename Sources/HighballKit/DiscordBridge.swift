import Foundation
import Darwin

/// Authenticated loopback transport from the Windows helper to the native Discord Unix
/// socket. Each pipe client owns one Discord connection; replies, pings and subscriptions
/// travel back to the original game. There is no DLL injection or Discord account access.
final class DiscordBridge: @unchecked Sendable {
    let token = UUID().uuidString
    let port: UInt16
    private let listener: DiscordSocket
    private let lock = NSLock()
    private var stopped = false
    private var clients: [UUID: DiscordSocket] = [:]
    private var controls: Set<String> = []
    private let socketPaths: @Sendable () -> [String]
    private let activity: @Sendable (UUID, Bool) -> Void

    init(socketPaths: @escaping @Sendable () -> [String] = { DiscordIPC.socketPaths() }, activity: @escaping @Sendable (UUID, Bool) -> Void) throws {
        self.activity = activity
        self.socketPaths = socketPaths
        let socket = try DiscordSocket(domain: AF_INET)
        listener = socket
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket.fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        guard bound == 0, listen(socket.fd, 32) == 0 else { throw HighballError.failed("Could not start Discord bridge") }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &address, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(socket.fd, $0, &size) }
        }) == 0 else { throw HighballError.failed("Could not read Discord bridge port") }
        port = UInt16(bigEndian: address.sin_port)
        DispatchQueue.global(qos: .utility).async { [self] in acceptClients() }
    }

    func isReady(prefix: String) -> Bool { lock.withLock { controls.contains(prefix) } }
    func stop() {
        lock.withLock {
            stopped = true
            listener.stop()
            for client in clients.values { client.stop() }
        }
    }
    private func acceptClients() {
        while !lock.withLock({ stopped }) {
            var p = pollfd(fd: listener.fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 1000) > 0 else { continue }
            let fd = accept(listener.fd, nil, nil)
            guard fd >= 0 else { continue }
            let client = DiscordSocket(fd: fd), id = UUID()
            let accepted = lock.withLock { () -> Bool in
                guard !stopped, clients.count < 64 else { return false }
                clients[id] = client
                return true
            }
            guard accepted else { client.stop(); continue }
            DispatchQueue.global(qos: .utility).async { [self] in serve(client, id: id) }
        }
    }
    private func serve(_ client: DiscordSocket, id: UUID) {
        defer {
            activity(id, false)
            client.stop()
            _ = lock.withLock { clients.removeValue(forKey: id) }
        }
        do {
            let auth = try client.read(37, timeout: 3)
            guard String(decoding: auth.prefix(36), as: UTF8.self) == token else { return }
            if auth.last == 255 {
                // The helper keeps this connection open. Closing it ends only that helper,
                // including every pipe thread, when Highball quits.
                let lengthData = try client.read(2, timeout: 3)
                let length = lengthData.withUnsafeBytes { Int($0.loadUnaligned(as: UInt16.self).littleEndian) }
                guard length > 0, length <= 4096 else { return }
                let prefix = String(decoding: try client.read(length, timeout: 3), as: UTF8.self)
                lock.withLock { _ = controls.insert(prefix) }
                defer { _ = lock.withLock { controls.remove(prefix) } }
                _ = try client.read(1)
                return
            }
            guard let index = auth.last, index < 10 else { return }
            // Prefer the same slot, then try the remaining clients (Stable/PTB/Canary).
            let paths = socketPaths()
            let ordered = paths.filter { $0.hasSuffix("discord-ipc-\(index)") } + paths.filter { !$0.hasSuffix("discord-ipc-\(index)") }
            let discord = try DiscordIPC.connect(paths: ordered)
            defer { discord.stop() }
            DispatchQueue.global(qos: .utility).async { [self] in
                defer { discord.stop(); client.stop() }
                do {
                    while true {
                        let frame = try discord.readFrame()
                        if frame.json?["cmd"] as? String == "SET_ACTIVITY", frame.json?["evt"] as? String == "ERROR" {
                            activity(id, false)
                        }
                        try client.write(frame)
                    }
                } catch { }
            }
            while true {
                let frame = try client.readFrame()
                if let active = frame.activity { activity(id, active) }
                try discord.write(frame.hostPID(getpid()))
            }
        } catch { /* An SDK reconnects when either side closes. */ }
    }
}
