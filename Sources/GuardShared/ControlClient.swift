import Foundation

public enum ControlClientError: Error, CustomStringConvertible {
    case notRunning
    case io(String)

    public var description: String {
        switch self {
        case .notRunning: return "Torie-chan app is not running"
        case .io(let msg): return msg
        }
    }
}

/// Synchronous client for the app's control socket. One request per connection.
public enum ControlClient {
    public static func send(_ request: ControlRequest, path: String = GuardIDs.controlSocketPath) throws -> ControlResponse {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlClientError.io("socket() failed") }
        defer { close(fd) }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
        guard path.utf8.count < maxLen else { throw ControlClientError.io("socket path too long") }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard rc == 0 else { throw ControlClientError.notRunning }

        var payload = try ControlCoding.encoder.encode(request)
        payload.append(0x0A)
        try payload.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(fd, buf.baseAddress! + sent, buf.count - sent)
                guard n > 0 else { throw ControlClientError.io("write failed") }
                sent += n
            }
        }

        let line = try readLine(fd: fd)
        return try ControlCoding.decoder.decode(ControlResponse.self, from: line)
    }

    /// Reads up to a newline. With a `deadline`, gives up once it passes (the socket's receive timeout bounds each read).
    public static func readLine(fd: Int32, deadline: Date? = nil) throws -> Data {
        var data = Data()
        var byte: UInt8 = 0
        while true {
            if let deadline, Date() > deadline { throw ControlClientError.io("timed out") }
            let n = read(fd, &byte, 1)
            if n <= 0 { break }
            if byte == 0x0A { break }
            data.append(byte)
            if data.count > 8 * 1024 * 1024 { throw ControlClientError.io("response too large") }
        }
        guard !data.isEmpty else { throw ControlClientError.io("empty response from app") }
        return data
    }
}
