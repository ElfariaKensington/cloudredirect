import Foundation
import CloudRedirectSupport

struct NativeCommandResult {
    let data: Data
    let errors: String
    let status: Int32

    func json() throws -> [String: Any] {
        let lines = data.split(separator: 10)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            ?? lines.reversed().compactMap { (try? JSONSerialization.jsonObject(with: Data($0))) as? [String: Any] }.first
        guard let object else { throw AppError.message(errors.isEmpty ? "The native helper returned an invalid response." : errors) }
        guard status == 0, object["success"] as? Bool != false, object["ok"] as? Bool != false else {
            throw AppError.message(object["error"] as? String ?? object["message"] as? String ?? "The native operation failed.")
        }
        return object
    }
}

final class NativeCommand: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func cancel() {
        let task = lock.withLock { cancelled = true; return process }
        if task?.isRunning == true { task?.terminate() }
    }

    func run(_ executable: URL, _ arguments: [String], input: Data? = nil,
             onLine: (@Sendable (Data) -> Void)? = nil) async throws -> NativeCommandResult {
        try await withTaskCancellationHandler {
            try await Task.detached { [self] in
                let errorURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                FileManager.default.createFile(atPath: errorURL.path, contents: nil)
                defer { try? FileManager.default.removeItem(at: errorURL) }
                let errorFile = try FileHandle(forWritingTo: errorURL)
                defer { try? errorFile.close() }
                let task = Process(), output = Pipe(), stdin = Pipe()
                task.executableURL = executable; task.arguments = arguments
                task.standardOutput = output; task.standardError = errorFile; task.standardInput = stdin
                try lock.withLock {
                    if cancelled { throw CancellationError() }
                    process = task
                    do { try task.run() } catch { process = nil; throw error }
                }
                defer { lock.withLock { process = nil } }
                if let input { try stdin.fileHandleForWriting.write(contentsOf: input) }
                try stdin.fileHandleForWriting.close()
                var result = Data(), pending = Data()
                while true {
                    let bytes = output.fileHandleForReading.availableData
                    if bytes.isEmpty { break }
                    result.append(bytes)
                    if let onLine {
                        pending.append(bytes)
                        while let end = pending.firstIndex(of: 10) {
                            onLine(Data(pending[..<end])); pending.removeSubrange(...end)
                        }
                    }
                }
                if !pending.isEmpty { onLine?(pending) }
                task.waitUntilExit()
                let wasCancelled = lock.withLock { cancelled }
                if wasCancelled { throw CancellationError() }
                return NativeCommandResult(data: result, errors: String(decoding: (try? Data(contentsOf: errorURL)) ?? Data(), as: UTF8.self), status: task.terminationStatus)
            }.value
        } onCancel: { self.cancel() }
    }
}
