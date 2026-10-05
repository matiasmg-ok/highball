import Foundation
import Darwin

/// Discord's local IPC framing. A Wine PID is not a macOS PID; use the host's PID so
/// Discord can follow its lifetime. Everything else, including join secrets, is preserved.
enum DiscordIPC {
    static let maximumPayload = 1_048_576
    struct Frame {
        var opcode: UInt32
        var payload: Data
        var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: payload)) as? [String: Any] }
        var bytes: Data {
            var out = Data()
            for value in [opcode, UInt32(payload.count)] {
                var le = value.littleEndian
                withUnsafeBytes(of: &le) { out.append(contentsOf: $0) }
            }
            out.append(payload)
            return out
        }
        init(opcode: UInt32, payload: Data) { self.opcode = opcode; self.payload = payload }
        init(opcode: UInt32, json: [String: Any]) throws {
            self.init(opcode: opcode, payload: try JSONSerialization.data(withJSONObject: json))
        }
        func hostPID(_ pid: pid_t) throws -> Frame {
            guard opcode == 1, var object = json, object["cmd"] as? String == "SET_ACTIVITY",
                  var args = object["args"] as? [String: Any] else { return self }
            args["pid"] = Int(pid)
            object["args"] = args
            return try Frame(opcode: opcode, json: object)
        }
        var activity: Bool? {
            guard opcode == 1, let object = json, object["cmd"] as? String == "SET_ACTIVITY",
                  let args = object["args"] as? [String: Any], let activity = args["activity"] else { return nil }
            return !(activity is NSNull)
        }
    }

    static func socketPaths(environment: [String: String] = ProcessInfo.processInfo.environment) -> [String] {
        let dirs = [environment["XDG_RUNTIME_DIR"], environment["TMPDIR"], environment["TMP"], environment["TEMP"],
                    NSTemporaryDirectory(), "/tmp"].compactMap { $0 }
        var seen = Set<String>()
        return dirs.flatMap { dir in (0..<10).map { URL(fileURLWithPath: dir).appending(path: "discord-ipc-\($0)").path } }
            .filter { seen.insert($0).inserted }
    }

    static func connect(paths: [String] = socketPaths()) throws -> DiscordSocket {
        for path in paths {
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8CString)
            guard bytes.count <= MemoryLayout.size(ofValue: address.sun_path) else { continue }
            withUnsafeMutablePointer(to: &address.sun_path) {
                $0.withMemoryRebound(to: CChar.self, capacity: bytes.count) { $0.update(from: bytes, count: bytes.count) }
            }
            let sock = try DiscordSocket(domain: AF_UNIX)
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(sock.fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            if result == 0 { return sock }
        }
        throw HighballError.failed("Discord is not running")
    }
}

/// Owns the descriptor until every reader has finished. stop() only shuts it down:
/// closing/reusing a descriptor while another thread reads it can affect an unrelated socket.
final class DiscordSocket: @unchecked Sendable {
    let fd: Int32
    init(fd: Int32) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
    }
    convenience init(domain: Int32) throws {
        let fd = Darwin.socket(domain, SOCK_STREAM, 0)
        guard fd >= 0 else { throw HighballError.failed("Could not create Discord IPC socket") }
        self.init(fd: fd)
    }
    deinit { Darwin.close(fd) }
    func stop() { shutdown(fd, SHUT_RDWR) }
    func read(_ count: Int, timeout: TimeInterval? = nil) throws -> Data {
        var data = Data(count: count)
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < count {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                let wait = deadline.map { max(0, min(1000, Int32($0.timeIntervalSinceNow * 1000))) } ?? 1000
                let ready = poll(&p, 1, wait)
                if ready < 0 && errno == EINTR { continue }
                if let deadline, Date() >= deadline { throw HighballError.failed("Discord IPC timed out") }
                if ready == 0 { continue }
                guard ready > 0 else { throw HighballError.failed("Discord IPC read failed") }
                let n = recv(fd, buffer.baseAddress!.advanced(by: offset), count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw HighballError.failed("Discord IPC disconnected") }
                offset += n
            }
        }
        return data
    }
    func write(_ data: Data) throws {
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&p, 1, 2000)
                if ready < 0 && errno == EINTR { continue }
                guard ready > 0 else { throw HighballError.failed("Discord IPC write timed out") }
                let n = send(fd, buffer.baseAddress!.advanced(by: offset), data.count - offset, MSG_DONTWAIT)
                if n < 0 && (errno == EINTR || errno == EAGAIN) { continue }
                guard n > 0 else { throw HighballError.failed("Discord IPC write failed") }
                offset += n
            }
        }
    }
    func readFrame(timeout: TimeInterval? = nil) throws -> DiscordIPC.Frame {
        let header = try read(8, timeout: timeout)
        let values = header.withUnsafeBytes { ($0.loadUnaligned(as: UInt32.self).littleEndian,
                                               $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian) }
        guard values.1 <= DiscordIPC.maximumPayload else { throw HighballError.failed("Discord IPC frame is too large") }
        return DiscordIPC.Frame(opcode: values.0, payload: try read(Int(values.1), timeout: timeout))
    }
    func write(_ frame: DiscordIPC.Frame) throws { try write(frame.bytes) }
}
