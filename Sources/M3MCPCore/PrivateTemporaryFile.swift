import Darwin
import Foundation

/// Creates an owner-only regular file using `O_EXCL`; no existing path or symlink can be reused.
public enum PrivateTemporaryFile {
    public enum FileError: Error, LocalizedError, Sendable {
        case createFailed(Int32)
        case writeFailed(Int32)

        public var errorDescription: String? {
            switch self {
            case .createFailed(let code):
                return "Could not create private temporary file (errno \(code))."
            case .writeFailed(let code):
                return "Could not write private temporary file (errno \(code))."
            }
        }
    }

    public static func write(
        _ data: Data,
        directory: URL = FileManager.default.temporaryDirectory,
        prefix: String,
        suffix: String
    ) throws -> URL {
        let filename = prefix + UUID().uuidString + suffix
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        let descriptor = url.path.withCString { path in
            Darwin.open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        }
        guard descriptor >= 0 else {
            throw FileError.createFailed(errno)
        }

        var shouldRemove = true
        defer {
            _ = Darwin.close(descriptor)
            if shouldRemove {
                try? FileManager.default.removeItem(at: url)
            }
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard var base = rawBuffer.baseAddress else { return }
                var remaining = rawBuffer.count
                while remaining > 0 {
                    let written = Darwin.write(descriptor, base, remaining)
                    guard written > 0 else {
                        throw FileError.writeFailed(errno)
                    }
                    remaining -= written
                    base = base.advanced(by: written)
                }
            }
        } catch {
            throw error
        }

        guard Darwin.fsync(descriptor) == 0 else {
            throw FileError.writeFailed(errno)
        }
        shouldRemove = false
        return url
    }
}
