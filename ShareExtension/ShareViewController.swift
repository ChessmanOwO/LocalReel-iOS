import SwiftUI
import UIKit
import UniformTypeIdentifiers

final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let content = ShareView(context: extensionContext) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
        let controller = UIHostingController(rootView: content)
        addChild(controller); view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
    }
}

@MainActor
final class ShareDownloadModel: ObservableObject {
    @Published var message = "Đang đọc liên kết…"
    @Published var progress: Double?
    @Published var busy = false
    @Published var file: URL?
    @Published var saving = false
    @Published var saved = false
    @Published var error: String?
    var source: URL?

    func download() async {
        guard !busy, !saved, let source else { return }
        busy = true; error = nil
        defer { busy = false; saving = false }
        do {
            try Task.checkCancellation()
            try await VideoStorage.requirePhotoAccess()
            try Task.checkCancellation()
            let output: URL
            if let file, FileManager.default.fileExists(atPath: file.path) {
                output = file
            } else {
                message = "Đang tìm nguồn video trên iPhone…"
                let resolved = try await VideoResolver().resolveAutomatically(source)
                try Task.checkCancellation()
                guard let variant = resolved.variants.max(by: { ($0.height, $0.bitrate) < ($1.height, $1.bitrate) }) else { throw LocalReelError(message: "Không tìm thấy nguồn video phù hợp.") }
                output = try await VideoPipeline().run(variant, id: UUID().uuidString) { [weak self] value in
                    guard let self, !self.saving, !self.saved else { return }
                    self.message = value.state.label; self.progress = value.progress
                }
                file = output
            }
            try Task.checkCancellation()
            saving = true; progress = nil
            message = "Đang lưu vào Photos…"
            try await VideoStorage.savePhotos(output)
            saved = true; message = "Lưu thành công vào Photos."
            // The extension's private sandbox is not the main app's Documents folder.
            try? FileManager.default.removeItem(at: output)
            file = nil
        } catch is CancellationError { message = "Đã dừng tải." }
        catch { self.error = error.localizedDescription; message = "Chưa hoàn tất." }
    }
}

@MainActor
struct ShareView: View {
    let context: NSExtensionContext?
    let finish: () -> Void
    @StateObject private var model = ShareDownloadModel()
    @State private var loaded = false
    @State private var task: Task<Void, Never>?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Label(model.message, systemImage: model.saved ? "checkmark.circle.fill" : "iphone")
                    if model.busy {
                        if let progress = model.progress { ProgressView(value: min(max(progress, 0), 1)) }
                        else { ProgressView() }
                    }
                    Text("Tải trực tiếp trên iPhone, không dùng Mac. Giữ bảng chia sẻ này mở đến khi xong. Với video dài, hãy dùng app LocalReel chính.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if let error = model.error { Section { Text(error).foregroundStyle(.red) } }
                if !model.busy && !model.saved && model.source != nil {
                    Button("Thử lại") { start() }
                }
            }
            .navigationTitle("Tải với LocalReel")
            .toolbar { Button(model.saved ? "Xong" : "Đóng") { task?.cancel(); finish() }.disabled(model.saving) }
            .task {
                guard !loaded else { return }; loaded = true
                if let link = await readLink(), let url = URL(string: link) { model.source = url; start() }
                else { model.message = "Không nhận được liên kết video. Hãy chọn Sao chép liên kết rồi dán vào LocalReel." }
            }
            .onDisappear { task?.cancel() }
        }
    }
    private func start() {
        task = Task { @MainActor in
            await model.download()
        }
    }
    private func readLink() async -> String? {
        for item in ((context?.inputItems as? [NSExtensionItem]) ?? []).prefix(5) {
            for provider in (item.attachments ?? []).prefix(5) {
                for type in [UTType.url.identifier, UTType.plainText.identifier] where provider.hasItemConformingToTypeIdentifier(type) {
                    let text: String? = await withCheckedContinuation { continuation in
                        provider.loadItem(forTypeIdentifier: type, options: nil) { value, _ in
                            if let url = value as? URL { continuation.resume(returning: url.absoluteString) }
                            else if let text = value as? String { continuation.resume(returning: text) }
                            else if let data = value as? Data, data.count <= 16_384 { continuation.resume(returning: String(data: data, encoding: .utf8)) }
                            else { continuation.resume(returning: nil) }
                        }
                    }
                    if let text, let link = SharedLink.find(in: text) { return link }
                }
            }
            if let text = item.attributedContentText?.string, let link = SharedLink.find(in: text) { return link }
        }
        return nil
    }
}
