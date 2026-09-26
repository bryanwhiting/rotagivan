import Foundation

enum CredentialWorkerError: LocalizedError {
    case busy
    var errorDescription: String? {
        "Another Keychain operation is still waiting. Finish that operation, then retry."
    }
}

/// Security calls can wait indefinitely. Keep them off the main thread and
/// admit just one call, without accumulating blocked calls or queued retries.
final class CredentialWorker: @unchecked Sendable {
    static let shared = CredentialWorker()
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "local.rotagivan.credentials", qos: .userInitiated)
    private var occupied = false

    func run<T: Sendable>(_ operation: @escaping @Sendable () throws -> T) async throws -> T {
        try Task.checkCancellation()
        let request = CredentialRequest<T>()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                request.install(continuation)
                lock.lock()
                guard !occupied else {
                    lock.unlock()
                    request.finish(.failure(CredentialWorkerError.busy))
                    return
                }
                occupied = true
                lock.unlock()
                queue.async { [self] in
                    let result: Result<T, Error>
                    if request.isCancelled { result = .failure(CancellationError()) }
                    else { result = Result { try operation() } }
                    // A result may immediately start vault hydration. Release
                    // capacity before waking its caller, including errors.
                    lock.lock(); occupied = false; lock.unlock()
                    request.finish(result)
                }
            }
        }, onCancel: { request.cancel() })
    }
}

private final class CredentialRequest<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    private var cancelled = false
    private var completed = false
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }

    func install(_ value: CheckedContinuation<T, Error>) {
        lock.lock()
        if cancelled {
            completed = true; lock.unlock()
            value.resume(throwing: CancellationError())
        } else { continuation = value; lock.unlock() }
    }
    func cancel() {
        lock.lock()
        cancelled = true
        let pending = completed ? nil : continuation
        if pending != nil { completed = true; continuation = nil }
        lock.unlock()
        pending?.resume(throwing: CancellationError())
    }
    func finish(_ result: Result<T, Error>) {
        lock.lock()
        guard !completed, let pending = continuation else { lock.unlock(); return }
        completed = true; continuation = nil
        lock.unlock()
        pending.resume(with: result)
    }
}
