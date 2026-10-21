import Foundation
import GuardShared

/// Unix-socket server for `bg-mcp` and other local clients. Socket is 0600 in a 0700 directory,
/// and the command set has no disarm, so the worst a local client can do is arm the guard.
final class ControlServer {
    private let path = GuardIDs.controlSocketPath
    private let handler: (ControlRequest) -> ControlResponse
    private var listenFD: Int32 = -1

    init(handler: @escaping (ControlRequest) -> ControlResponse) {
        self.handler = handler
    }

    func start() throws {
        unlink(path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ControlClientError.io("socket() failed") }

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in
            buf.copyBytes(from: path.utf8)
            buf[path.utf8.count] = 0
        }
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            throw ControlClientError.io("could not listen on \(path): \(String(cString: strerror(errno)))")
        }
        listenFD = fd

        let thread = Thread { [weak self] in self?.acceptLoop(fd) }
        thread.name = "toriechan.control"
        thread.start()
    }

    func stop() {
        if listenFD >= 0 { close(listenFD) }
        listenFD = -1
        unlink(path)
    }

    private func acceptLoop(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return
            }
            serve(client)
        }
    }

    private func serve(_ client: Int32) {
        defer { close(client) }
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        let response: ControlResponse
        if let line = try? ControlClient.readLine(fd: client),
           let request = try? ControlCoding.decoder.decode(ControlRequest.self, from: line) {
            response = DispatchQueue.main.sync { handler(request) }
        } else {
            response = ControlResponse(ok: false, error: "malformed request")
        }

        guard var data = try? ControlCoding.encoder.encode(response) else { return }
        data.append(0x0A)
        data.withUnsafeBytes { buf in
            var sent = 0
            while sent < buf.count {
                let n = write(client, buf.baseAddress! + sent, buf.count - sent)
                if n <= 0 { break }
                sent += n
            }
        }
    }
}
