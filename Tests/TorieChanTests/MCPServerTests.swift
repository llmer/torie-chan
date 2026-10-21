import Foundation
import XCTest
@testable import GuardShared
@testable import TorieChan

/// Runs the real `bg-mcp` binary against a fake app on a private control socket. The support
/// folder override and TORIECHAN_NO_LAUNCH keep it away from any real Torie-chan on this Mac.
final class MCPServerTests: XCTestCase {
    private var directory: URL!
    private var server: ControlServer?
    private var received: [ControlRequest] = []

    override func setUp() {
        // Unix socket paths max out at 104 bytes, so keep this short.
        directory = URL(fileURLWithPath: "/tmp/tc-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        setenv("TORIECHAN_SUPPORT_DIR", directory.path, 1)
    }

    override func tearDown() {
        server?.stop()
        unsetenv("TORIECHAN_SUPPORT_DIR")
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: Helpers

    private func startFakeApp(_ respond: @escaping (ControlRequest) -> ControlResponse) throws {
        let server = ControlServer { [unowned self] request in
            self.received.append(request)
            return respond(request)
        }
        try server.start()
        self.server = server
    }

    private var binary: URL {
        Bundle(for: Self.self).bundleURL.deletingLastPathComponent().appendingPathComponent("bg-mcp")
    }

    /// Send JSON-RPC messages to bg-mcp and collect its replies, keyed by id.
    private func run(_ calls: [(id: Int, method: String, params: [String: Any])]) throws -> [Int: [String: Any]] {
        let process = Process()
        process.executableURL = binary
        var env = ProcessInfo.processInfo.environment
        env["TORIECHAN_SUPPORT_DIR"] = directory.path
        env["TORIECHAN_NO_LAUNCH"] = "1"
        process.environment = env
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = Pipe()
        try process.run()

        var lines = [#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"0"}}}"#]
        for call in calls {
            let msg: [String: Any] = ["jsonrpc": "2.0", "id": call.id, "method": call.method, "params": call.params]
            lines.append(String(decoding: try JSONSerialization.data(withJSONObject: msg), as: UTF8.self))
        }
        input.fileHandleForWriting.write(Data((lines.joined(separator: "\n") + "\n").utf8))
        try input.fileHandleForWriting.close()

        // The fake app answers on the main queue, so wait while spinning the run loop.
        let done = expectation(description: "bg-mcp exits")
        var data = Data()
        DispatchQueue.global().async {
            data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            done.fulfill()
        }
        wait(for: [done], timeout: 20)

        var replies: [Int: [String: Any]] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            guard let obj = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let id = obj["id"] as? Int else { continue }
            replies[id] = obj
        }
        return replies
    }

    private func toolText(_ reply: [String: Any]?) -> (text: String, isError: Bool) {
        let result = reply?["result"] as? [String: Any]
        let content = (result?["content"] as? [[String: Any]])?.first
        return (content?["text"] as? String ?? "", result?["isError"] as? Bool ?? false)
    }

    private static let status = GuardStatus(state: "arming", detail: nil, armedSince: nil, expectedBack: nil, note: nil,
                                             peopleSeen: 0, peopleInView: 0, lidClosed: false, onACPower: true,
                                             protections: ["Being moved or picked up"], gaps: [], kioskFocused: true, passcodeSet: true)

    // MARK: Tests

    func testThereIsNoDisarmTool() throws {
        let replies = try run([(1, "tools/list", [:])])
        let tools = ((replies[1]?["result"] as? [String: Any])?["tools"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
        XCTAssertEqual(Set(tools), ["arm_guard", "guard_status", "last_session", "post_update", "get_events"])
        XCTAssertFalse(tools.contains { $0.contains("disarm") })
        let info = (replies[0]?["result"] as? [String: Any])?["serverInfo"] as? [String: Any]
        XCTAssertEqual(info?["name"] as? String, "torie-chan")
    }

    func testArmingClampsTheCountdownAndCleansTheNote() throws {
        try startFakeApp { _ in ControlResponse(ok: true, status: Self.status) }
        let replies = try run([(1, "tools/call", ["name": "arm_guard", "arguments": ["countdown_seconds": 0, "note": "Back\nin 5"]])])
        XCTAssertFalse(toolText(replies[1]).isError)
        let arm = try XCTUnwrap(received.first { $0.command == .arm })
        XCTAssertEqual(arm.countdownSeconds, 5)
        XCTAssertEqual(arm.note, "Back in 5")
    }

    func testAlarmPhotoPathsNeverReachAgents() throws {
        try startFakeApp { _ in
            ControlResponse(ok: true, events: [GuardEvent(kind: "alarm", message: "Lifted", snapshotPath: "/Users/someone/secret/alarm.jpg")])
        }
        let replies = try run([(1, "tools/call", ["name": "get_events", "arguments": [:] as [String: Any]])])
        let text = toolText(replies[1]).text
        XCTAssertTrue(text.contains("photoSavedOnMac"))
        XCTAssertFalse(text.contains("/Users/someone"), "the path stays on the Mac")
        XCTAssertFalse(text.contains("alarm.jpg"))
    }

    func testAgentUpdatesAreForwarded() throws {
        try startFakeApp { _ in ControlResponse(ok: true) }
        _ = try run([(1, "tools/call", ["name": "post_update", "arguments": ["message": "tests passing"]])])
        XCTAssertEqual(received.first?.command, .postUpdate)
        XCTAssertEqual(received.first?.message, "tests passing")
    }

    func testWithTheAppNotRunningToolsSaySo() throws {
        let replies = try run([(1, "tools/call", ["name": "guard_status", "arguments": [:] as [String: Any]])])
        let result = toolText(replies[1])
        XCTAssertTrue(result.isError)
        XCTAssertTrue(result.text.contains("not running"))
    }

    func testTheControlSocketIsPrivateToTheUser() throws {
        try startFakeApp { _ in ControlResponse(ok: true, status: Self.status) }
        let attributes = try FileManager.default.attributesOfItem(atPath: GuardIDs.controlSocketPath)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        let replied = expectation(description: "status")
        var response: ControlResponse?
        DispatchQueue.global().async {
            response = try? ControlClient.send(ControlRequest(command: .status))
            replied.fulfill()
        }
        wait(for: [replied], timeout: 5)
        XCTAssertEqual(response?.status?.state, "arming")
    }
}
