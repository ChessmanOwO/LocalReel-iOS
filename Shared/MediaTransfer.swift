import Foundation

// URLSession streams to a temporary file; whole videos are never buffered in RAM.
final class MediaTransfer: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    static let shared = MediaTransfer()
    private struct Pending {
        let destination: URL
        let continuation: CheckedContinuation<URL, Error>
        let progress: @Sendable (Int64, Int64?) -> Void
    }
    private let lock = NSLock()
    private var pending: [Int: Pending] = [:]
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.default
        config.waitsForConnectivity = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = .greatestFiniteMagnitude
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        return URLSession(configuration: config, delegate: self, delegateQueue: queue)
    }()

    func download(_ url: URL, headers: [String: String], to destination: URL,
                  progress: @escaping @Sendable (Int64, Int64?) -> Void) async throws -> URL {
        guard SharedLink.safeHTTPS(url) else { throw LocalReelError(message: "Địa chỉ video không hợp lệ.") }
        var request = URLRequest(url: url)
        request.setValue(VideoResolver.agent, forHTTPHeaderField: "User-Agent")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        try Task.checkCancellation()
        let cancellation = TransferCancellation()
        let task = session.downloadTask(with: request)
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                lock.lock()
                pending[task.taskIdentifier] = Pending(destination: destination, continuation: continuation, progress: progress)
                lock.unlock()
                cancellation.install(task)
                task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }
    private func take(_ id: Int) -> Pending? {
        lock.lock(); defer { lock.unlock() }
        return pending.removeValue(forKey: id)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock(); let item = pending[downloadTask.taskIdentifier]; lock.unlock()
        item?.progress(totalBytesWritten, totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let item = take(downloadTask.taskIdentifier) else { return }
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, (200..<300).contains(response.statusCode),
                  let url = response.url, SharedLink.safeHTTPS(url) else {
                throw LocalReelError(message: "Nguồn từ chối tải file. Liên kết video có thể đã hết hạn; hãy thử lại.")
            }
            guard response.mimeType?.contains("html") != true else { throw LocalReelError(message: "Nguồn trả về trang web thay vì video.") }
            try FileManager.default.createDirectory(at: item.destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: item.destination.path) { try FileManager.default.removeItem(at: item.destination) }
            try FileManager.default.moveItem(at: location, to: item.destination)
            item.continuation.resume(returning: item.destination)
        } catch { item.continuation.resume(throwing: error) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let item = take(task.taskIdentifier) else { return }
        if let error = error as? URLError, error.code == .cancelled { item.continuation.resume(throwing: CancellationError()) }
        else { item.continuation.resume(throwing: error ?? LocalReelError(message: "Tải video chưa hoàn tất.")) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url.map(SharedLink.safeHTTPS) == true ? request : nil)
    }
}

private final class TransferCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionTask?
    private var cancelled = false
    func install(_ task: URLSessionTask) {
        lock.lock(); self.task = task; let stop = cancelled; lock.unlock()
        if stop { task.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let current = task; lock.unlock()
        current?.cancel()
    }
}
