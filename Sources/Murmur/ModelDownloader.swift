import Foundation
import Combine

/// Downloads speech models from Hugging Face on request. The only network use besides
/// optional cloud cleanup.
final class ModelDownloader: NSObject, ObservableObject, URLSessionDownloadDelegate {
    static let shared = ModelDownloader()

    /// Model id → fraction complete.
    @Published var progress: [String: Double] = [:]
    @Published var failed: [String: String] = [:]
    /// Bumped when the set of installed models changes, so views re-check the disk.
    @Published var revision = 0

    private var tasks: [String: URLSessionDownloadTask] = [:]
    private lazy var session = URLSession(configuration: .default, delegate: self, delegateQueue: .main)

    func download(_ model: SpeechModel) {
        guard tasks[model.id] == nil else { return }
        failed[model.id] = nil
        progress[model.id] = 0
        let task = session.downloadTask(with: model.url)
        task.taskDescription = model.id
        tasks[model.id] = task
        task.resume()
    }

    func cancel(_ model: SpeechModel) {
        tasks[model.id]?.cancel()
        tasks[model.id] = nil
        progress[model.id] = nil
    }

    func delete(_ model: SpeechModel) {
        try? FileManager.default.removeItem(atPath: ModelCatalog.path(for: model.id))
        revision += 1
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard let id = downloadTask.taskDescription, totalBytesExpectedToWrite > 0 else { return }
        let fraction = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
        // Publishing every chunk would redraw Settings hundreds of times a second.
        if fraction - (progress[id] ?? 0) >= 0.01 || fraction >= 1 { progress[id] = fraction }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let id = downloadTask.taskDescription else { return }
        let status = (downloadTask.response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { failed[id] = "Download failed (HTTP \(status))"; return }
        let destination = URL(fileURLWithPath: ModelCatalog.path(for: id))
        try? FileManager.default.createDirectory(at: ModelCatalog.directory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            failed[id] = "Couldn't save the model"
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let id = task.taskDescription else { return }
        tasks[id] = nil
        progress[id] = nil
        if let error = error as NSError?, error.code != NSURLErrorCancelled { failed[id] = error.localizedDescription }
        revision += 1
    }
}
