import Darwin
import Foundation
import XCTest

/// The token the server-level tests build their authorizer with.
///
/// A fixed literal rather than a generated one: these tests are about the door, not about the key,
/// and a constant keeps the raw HTTP in the assertions readable.
let testCapabilityToken = "test-capability-token"

/// `sockaddr_un.sun_path` is 104 bytes. Foundation's `temporaryDirectory` on macOS is a per-user
/// path long enough to overflow it, so socket tests use the short real temp root instead.
func makeShortTemporaryDirectory(prefix: String) throws -> URL {
    let directory = URL(
        fileURLWithPath: "/private/tmp/\(prefix)-\(UUID().uuidString.prefix(8))",
        isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    return directory
}

func connectToSocket(at url: URL) throws -> Int32 {
    let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
        throw POSIXError(.init(rawValue: errno) ?? .EIO)
    }

    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let capacity = MemoryLayout.size(ofValue: address.sun_path)
    withUnsafeMutablePointer(to: &address.sun_path) { pointer in
        pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
            _ = strlcpy(destination, url.path, capacity)
        }
    }

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { addressPointer in
            Darwin.connect(descriptor, addressPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard result == 0 else {
        let code = errno
        Darwin.close(descriptor)
        throw POSIXError(.init(rawValue: code) ?? .EIO)
    }
    return descriptor
}

/// The listen backlog is matched to the connection cap, so a burst larger than the cap can be met
/// with ECONNREFUSED while the accept loop is still draining. That is the kernel, not the server,
/// and a client retries. Returns nil when the endpoint refused for the whole window.
func connectToSocketWithRetry(at url: URL, attempts: Int = 80) -> Int32? {
    for attempt in 0..<attempts {
        if let descriptor = try? connectToSocket(at: url) {
            return descriptor
        }
        Thread.sleep(forTimeInterval: 0.002 * Double(attempt + 1))
    }
    return nil
}

func writeAllToSocket(_ data: Data, to descriptor: Int32) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(descriptor, base.advanced(by: offset), raw.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                throw POSIXError(.init(rawValue: errno) ?? .EIO)
            }
            offset += count
        }
    }
}

func readUntilSocketClose(from descriptor: Int32, timeout: TimeInterval) throws -> Data {
    var result = Data()
    var bytes = [UInt8](repeating: 0, count: 4_096)
    let deadline = Date().addingTimeInterval(timeout)
    while true {
        let remaining = deadline.timeIntervalSinceNow
        guard remaining > 0 else { throw POSIXError(.ETIMEDOUT) }

        var readiness = pollfd(fd: descriptor, events: Int16(POLLIN | POLLHUP), revents: 0)
        let ready = Darwin.poll(&readiness, 1, Int32(remaining * 1_000))
        if ready < 0, errno == EINTR { continue }
        guard ready > 0 else {
            throw POSIXError(ready == 0 ? .ETIMEDOUT : (.init(rawValue: errno) ?? .EIO))
        }

        let count = bytes.withUnsafeMutableBytes { raw in
            Darwin.read(descriptor, raw.baseAddress, raw.count)
        }
        if count == 0 { return result }
        if count < 0, errno == EINTR { continue }
        if count < 0 { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        result.append(contentsOf: bytes[0..<count])
    }
}

/// One request, one reply, one connection. The endpoint answers with `Connection: close`, so a
/// read to EOF is the whole response.
func exchangeOverSocket(
    at url: URL,
    request: String,
    timeout: TimeInterval = 5
) throws -> (statusLine: String, body: String) {
    guard let descriptor = connectToSocketWithRetry(at: url) else {
        throw POSIXError(.ECONNREFUSED)
    }
    defer { Darwin.close(descriptor) }
    try writeAllToSocket(Data(request.utf8), to: descriptor)
    let raw = try readUntilSocketClose(from: descriptor, timeout: timeout)
    let text = String(decoding: raw, as: UTF8.self)
    let statusLine = text.components(separatedBy: "\r\n").first ?? ""
    let body = text.components(separatedBy: "\r\n\r\n").dropFirst().joined(separator: "\r\n\r\n")
    return (statusLine, body)
}

func toolCallRequest(tool: String, token: String?) -> String {
    var request = "POST /tools/\(tool) HTTP/1.1\r\n"
    request += "Host: localhost\r\n"
    request += "Content-Type: application/json\r\n"
    if let token {
        request += "Authorization: Bearer \(token)\r\n"
    }
    request += "Content-Length: 2\r\n"
    request += "Connection: close\r\n\r\n{}"
    return request
}
