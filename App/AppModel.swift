import Foundation
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var jobs: [LocalJob] = []
    @Published var error: String?
    @Published var showSaveSuccess = false
    private var running: Task<Void, Never>?
    private var currentID: String?
    private var cancelled = Set<String>()
    private var choices: [String: [MediaVariant]] = [:]
    private var lastSave = Date.distantPast
    private let resolver = VideoResolver()

    init() {
        do {
            let path = try VideoStorage.support().appendingPathComponent("jobs.json")
            if let data = try? Data(contentsOf: path) { jobs = try JSONDecoder().decode([LocalJob].self, from: data) }
            for index in jobs.indices where jobs[index].state.isRunning || jobs[index].state == .awaitingSelection {
                jobs[index].state = .paused
                jobs[index].note = "Tác vụ đã tạm dừng khi app đóng. Bấm Tiếp tục để lấy lại nguồn mới."
                jobs[index].progress = nil
            }
            for index in jobs.indices where jobs[index].state == .complete && jobs[index].photosSaved != true {
                jobs[index].state = .paused
                jobs[index].note = "Tác vụ từ bản cũ chưa có xác nhận lưu Photos. Bấm Tiếp tục để lưu."
            }
            save()
        } catch { self.error = error.localizedDescription }
    }
    func file(for job: LocalJob) -> URL? {
        guard let filename = job.filename, filename == URL(fileURLWithPath: filename).lastPathComponent,
              let root = try? VideoStorage.videos() else { return nil }
        let url = root.appendingPathComponent(filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }
    @discardableResult func submit(_ text: String, ask: Bool) -> Bool {
        guard let link = SharedLink.find(in: text), let url = URL(string: link) else {
            error = "Không thấy liên kết video HTTPS hợp lệ trong nội dung dán."
            return false
        }
        if jobs.contains(where: { $0.sourceURL == url && $0.state.isRunning }) {
            error = "Video này đã có trong hàng đợi."
            return false
        }
        var job = LocalJob(sourceURL: url)
        job.quality = ask ? "ask" : "best"
        jobs.insert(job, at: 0)
        error = nil
        save(); schedule()
        return true
    }
    func choose(_ job: LocalJob, height: Int?) {
        edit(job.id) { $0.quality = height.map(String.init) ?? "best"; $0.state = .queued; $0.errorMessage = nil }
        save(); schedule()
    }
    func retry(_ job: LocalJob) {
        cancelled.remove(job.id)
        edit(job.id) { $0.state = .queued; $0.progress = nil; $0.errorMessage = nil; $0.note = "" }
        save(); schedule()
    }
    func cancel(_ job: LocalJob) {
        guard jobs.first(where: { $0.id == job.id })?.state != .savingPhotos else { return }
        cancelled.insert(job.id)
        if currentID == job.id { running?.cancel() }
        edit(job.id) { $0.state = .cancelled; $0.progress = nil; $0.note = "" }
        choices.removeValue(forKey: job.id)
        save()
    }
    func remove(_ job: LocalJob) {
        guard jobs.first(where: { $0.id == job.id })?.state != .savingPhotos else { return }
        cancel(job)
        if let file = file(for: job) { try? FileManager.default.removeItem(at: file) }
        jobs.removeAll { $0.id == job.id }
        save()
    }
    private func edit(_ id: String, _ action: (inout LocalJob) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == id }) else { return }
        action(&jobs[index])
    }
    private func save() {
        do {
            let path = try VideoStorage.support().appendingPathComponent("jobs.json")
            try JSONEncoder().encode(jobs).write(to: path, options: .atomic)
        } catch { self.error = "Không lưu được hàng đợi: \(error.localizedDescription)" }
    }
    private func schedule() {
        guard running == nil, let job = jobs.reversed().first(where: { $0.state == .queued }) else { return }
        currentID = job.id
        UIApplication.shared.isIdleTimerDisabled = true
        running = Task { @MainActor in
            await process(job)
            currentID = nil; running = nil
            UIApplication.shared.isIdleTimerDisabled = false
            save(); schedule()
        }
    }
    private func process(_ initial: LocalJob) async {
        let id = initial.id
        do {
            try Task.checkCancellation()
            try await VideoStorage.requirePhotoAccess()
            try Task.checkCancellation()
            // A failed Photos save retains its completed MP4: retry the save, not the download.
            if let existing = file(for: initial) {
                try await finishSaving(existing, id: id)
                return
            }
            var variants = choices[id]
            if variants == nil {
                edit(id) { $0.state = .extracting; $0.progress = nil; $0.note = "" }
                save()
                let resolved = try await resolver.resolveAutomatically(initial.sourceURL)
                try Task.checkCancellation()
                variants = resolved.variants
                edit(id) { $0.title = resolved.title; $0.heights = Array(Set(resolved.variants.map(\.height).filter { $0 > 0 })).sorted(by: >) }
            }
            guard let candidates = variants, !candidates.isEmpty else { throw LocalReelError(message: "Không tìm thấy chất lượng phù hợp.") }
            if initial.quality == "ask" {
                choices[id] = candidates
                edit(id) { $0.state = .awaitingSelection; $0.progress = nil }
                return
            }
            let matching: [MediaVariant]
            if let height = Int(initial.quality) { matching = candidates.filter { $0.height == height } }
            else { matching = candidates }
            guard let variant = matching.max(by: { ($0.height, $0.bitrate) < ($1.height, $1.bitrate) }) else { throw LocalReelError(message: "Chất lượng đã chọn không còn khả dụng.") }
            choices.removeValue(forKey: id)
            let output = try await VideoPipeline().run(variant, id: id) { [weak self] update in
                guard let self, !self.cancelled.contains(id), [JobState.extracting, .downloading, .merging].contains(self.jobs.first(where: { $0.id == id })?.state ?? .error) else { return }
                self.edit(id) {
                    $0.state = update.state; $0.progress = update.progress; $0.received = update.received; $0.expected = update.expected
                    if !update.note.isEmpty { $0.note = update.note }
                }
                if Date().timeIntervalSince(self.lastSave) > 1 { self.lastSave = Date(); self.save() }
            }
            try Task.checkCancellation()
            edit(id) { $0.filename = output.lastPathComponent }
            save()
            try await finishSaving(output, id: id)
        } catch is CancellationError {
            edit(id) { if $0.state != .queued { $0.state = .cancelled; $0.progress = nil } }
        } catch {
            edit(id) { $0.state = .error; $0.progress = nil; $0.note = ""; $0.errorMessage = error.localizedDescription }
        }
    }
    private func finishSaving(_ output: URL, id: String) async throws {
        try Task.checkCancellation()
        edit(id) { $0.state = .savingPhotos; $0.progress = nil; $0.note = "Đang lưu vào Photos…" }
        save()
        // Photos commits atomically. Do not allow Cancel/Delete during this short phase,
        // and do not turn a successful commit into a cancellation after it returns.
        try await VideoStorage.savePhotos(output)
        edit(id) {
            $0.state = .complete; $0.photosSaved = true; $0.progress = 1
            $0.filename = nil; $0.errorMessage = nil; $0.note = "Lưu thành công vào Photos."
        }
        save()
        try? FileManager.default.removeItem(at: output)
        showSaveSuccess = true
    }

}
