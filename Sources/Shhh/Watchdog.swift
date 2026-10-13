import Foundation

/// Runs blocking work on `queue` and gives up after `timeout`.
///
/// Core Audio calls can hang forever when a device misbehaves (an iPhone microphone dropping
/// out mid-handshake, a broken aggregate device). Running them this way means the caller gets
/// `WatchdogError.timedOut` instead of freezing with them. The stuck work keeps its thread, so
/// callers should stop using `queue` after a timeout.
func runWithWatchdog<T>(on queue: DispatchQueue, timeout: TimeInterval,
                        _ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = OnceGate()
        queue.async {
            let result = Result { try work() }
            if gate.claim() { continuation.resume(with: result) }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if gate.claim() { continuation.resume(throwing: WatchdogError.timedOut) }
        }
    }
}

/// Awaits `operation` for at most `timeout`, then throws `WatchdogError.timedOut`.
///
/// For async work that can stall for good (a model stuck on the Neural Engine or the GPU).
/// On a timeout the operation is left running and its result is dropped.
func withTimeout<T>(_ timeout: TimeInterval, _ operation: @escaping @Sendable () async throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        let gate = OnceGate()
        Task {
            do {
                let value = try await operation()
                if gate.claim() { continuation.resume(returning: value) }
            } catch {
                if gate.claim() { continuation.resume(throwing: error) }
            }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if gate.claim() { continuation.resume(throwing: WatchdogError.timedOut) }
        }
    }
}

enum WatchdogError: LocalizedError {
    case timedOut
    var errorDescription: String? { "Didn't respond in time" }
}

/// Lets exactly one of several racing callers through.
final class OnceGate: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}
