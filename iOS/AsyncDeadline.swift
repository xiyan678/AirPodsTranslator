import Foundation

/// 系统请求不响应取消时，超时仍须释放调用者；晚到结果只能完成自己的请求。
@MainActor
final class AsyncDeadline<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var operation: Task<Void, Never>?
    private var timer: Task<Void, Never>?

    static func run(timeout: Duration,
                    operation body: @escaping @MainActor () async throws -> Value) async throws -> Value {
        let attempt = AsyncDeadline()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                attempt.continuation = continuation
                attempt.operation = Task { @MainActor in
                    do { attempt.finish(.success(try await body())) }
                    catch { attempt.finish(.failure(error)) }
                }
                attempt.timer = Task { @MainActor in
                    do { try await Task.sleep(for: timeout) }
                    catch { return }
                    attempt.finish(.failure(URLError(.timedOut)))
                }
            }
        } onCancel: {
            Task { @MainActor in attempt.finish(.failure(CancellationError())) }
        }
    }

    private func finish(_ result: Result<Value, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timer?.cancel()
        operation?.cancel()
        timer = nil
        operation = nil
        continuation.resume(with: result)
    }
}
