import Foundation

/// Bounded retries share the same logic in production and network-failure tests.
@MainActor
struct ModelFileDownloader {
    var download: (URL, Data?) async throws -> (URL, URLResponse)
    var delay: (Int) async throws -> Void = { attempt in
        try await Task.sleep(for: .seconds(attempt))
    }

    func fetch(_ url: URL, expectedSize: Int, retry: (Int) -> Void) async throws -> URL {
        var resumeData: Data?
        for attempt in 1...3 {
            try Task.checkCancellation()
            do {
                let (temporary, response) = try await download(url, resumeData)
                do {
                    try Task.checkCancellation()
                    guard let response = response as? HTTPURLResponse,
                          [200, 206].contains(response.statusCode),
                          (try temporary.resourceValues(forKeys: [.fileSizeKey]).fileSize) == expectedSize else {
                        throw URLError(.badServerResponse)
                    }
                    return temporary
                } catch {
                    try? FileManager.default.removeItem(at: temporary)
                    throw error
                }
            } catch {
                if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                guard attempt < 3 else { throw error }
                // Resume when Foundation supplies valid resume information. If a resume
                // attempt fails without new data, the next attempt starts fresh.
                resumeData = (error as NSError).userInfo["NSURLSessionDownloadTaskResumeData"] as? Data
                retry(attempt + 1)
                try await delay(attempt)
            }
        }
        throw URLError(.unknown)
    }
}

enum ModelDownloadFailure: LocalizedError {
    case failed
    var errorDescription: String? {
        "语音模型下载未完成，已自动重试。请检查网络后重试，已下载完成的文件会保留。"
    }
}
