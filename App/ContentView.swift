import SwiftUI

struct ContentView: View {
    @StateObject private var model = AppModel()
    @State private var text = ""
    @State private var askQuality = false
    @State private var didRunCheck = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Label("Tải và xử lý trực tiếp trên iPhone", systemImage: "iphone")
                    Text("Dùng Wi-Fi hoặc dữ liệu di động. Giữ LocalReel mở trong khi tải và tạo MP4.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Section("Thêm video") {
                    TextField("Dán liên kết video hoặc Reel", text: $text, axis: .vertical)
                        .keyboardType(.URL).autocorrectionDisabled().textInputAutocapitalization(.never)
                        .privacySensitive()
                    PasteButton(payloadType: String.self) { text = $0.first ?? "" }
                    Text("Dán liên kết rồi bấm Tải. App tự tìm nguồn; không cần mở trang hay phát video trước.")
                        .font(.footnote).foregroundStyle(.secondary)
                    Toggle("Chọn chất lượng trước khi tải", isOn: $askQuality)
                    Button { if model.submit(text, ask: askQuality) { text = "" } } label: {
                        Label("Tải video trên iPhone", systemImage: "arrow.down.circle.fill")
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = model.error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        Button("Đóng thông báo") { model.error = nil }
                    }
                }
                Section("Trạng thái tải") {
                    if model.jobs.isEmpty { Text("Dán liên kết để bắt đầu. Không cần ghép đôi hay bật Mac.").foregroundStyle(.secondary) }
                    ForEach(model.jobs) { job in row(job) }
                }
                Section {
                    Text("YouTube được trích xuất trên thiết bị. Các trang mạng xã hội chỉ tải được khi trang cung cấp nguồn video có thể truy cập. Video riêng tư hoặc yêu cầu đăng nhập có thể không tải được.")
                    Text("Tải xong sẽ tự lưu vào Photos. Chỉ báo lưu thành công khi Photos xác nhận đã lưu. Hãy cấp quyền Thêm ảnh/video khi được hỏi.")
                }.font(.footnote).foregroundStyle(.secondary)
            }
            .navigationTitle("LocalReel")
            .alert("Lưu thành công", isPresented: $model.showSaveSuccess) {
                Button("OK", role: .cancel) { }
            } message: {
                Text("Video đã được lưu vào Photos.")
            }
            .onOpenURL { url in
                if SharedLink.isSupported(url) { _ = model.submit(url.absoluteString, ask: false) }
                else if url.scheme == "localreel", let link = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "url" })?.value { _ = model.submit(link, ask: false) }
            }
            .task {
                // Explicit device smoke checks follow the same Photos-save flow as normal downloads.
                guard !didRunCheck else { return }
                didRunCheck = true
                if let index = ProcessInfo.processInfo.arguments.firstIndex(of: "--ondevice-check-url"), ProcessInfo.processInfo.arguments.count > index + 1 {
                    _ = model.submit(ProcessInfo.processInfo.arguments[index + 1], ask: false)
                }
            }
        }
    }
    @ViewBuilder private func row(_ job: LocalJob) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(job.title).font(.headline).lineLimit(3)
            Text("\(job.platform) · \(job.state.label)").font(.caption).foregroundStyle(.secondary)
            if job.state.isRunning {
                if let progress = job.progress { ProgressView(value: min(max(progress, 0), 1)) }
                else { ProgressView() }
                if job.state == .downloading, job.received > 0 {
                    Text(ByteCountFormatter.string(fromByteCount: job.received, countStyle: .file) + (job.expected.map { " / " + ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? ""))
                        .font(.caption).monospacedDigit()
                }
            }
            if let error = job.errorMessage {
                Text(error).font(.callout).foregroundStyle(.red)
            }
            if !job.note.isEmpty { Text(job.note).font(.caption).foregroundStyle(.secondary) }
            if job.state == .awaitingSelection {
                Menu("Chọn chất lượng và tải") {
                    Button("Cao nhất tương thích iPhone") { model.choose(job, height: nil) }
                    ForEach(job.heights, id: \.self) { height in Button("\(height)p") { model.choose(job, height: height) } }
                }
            }
            HStack {
                if (job.state.isRunning && job.state != .savingPhotos) || job.state == .awaitingSelection { Button("Hủy", role: .destructive) { model.cancel(job) } }
                if [.error, .cancelled, .paused].contains(job.state) { Button(job.state == .paused ? "Tiếp tục" : "Thử lại") { model.retry(job) } }
            }.buttonStyle(.borderless)
        }
        .swipeActions { if job.state != .savingPhotos { Button("Xóa", role: .destructive) { model.remove(job) } } }
    }
}
