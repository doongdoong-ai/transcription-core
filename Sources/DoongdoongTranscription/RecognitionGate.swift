import Foundation

/// Actor reentrancy alone does not serialize work across an awaited system call.
actor RecognitionGate {
    private var occupied = false
    private var waiters: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        try Task.checkCancellation()
        if !occupied { occupied = true; return }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                if Task.isCancelled { continuation.resume(throwing: CancellationError()) }
                else { waiters.append((id, continuation)) }
            }
        } onCancel: { Task { await self.cancel(id) } }
    }

    func release() {
        if waiters.isEmpty { occupied = false }
        else { waiters.removeFirst().1.resume() }
    }

    private func cancel(_ id: UUID) {
        if let index = waiters.firstIndex(where: { $0.0 == id }) {
            waiters.remove(at: index).1.resume(throwing: CancellationError())
        }
    }
}
