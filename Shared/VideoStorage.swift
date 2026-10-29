import Foundation
import Photos

@MainActor
enum VideoStorage {
    static func support() throws -> URL {
        let url = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LocalReelOnDevice", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func transfers() throws -> URL {
        let url = try support().appendingPathComponent("Transfers", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    static func videos() throws -> URL {
        var url = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appendingPathComponent("LocalReel", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try url.setResourceValues(values)
        return url
    }
    static func requirePhotoAccess() async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw LocalReelError(message: "Chưa có quyền lưu Photos. Hãy vào Cài đặt → LocalReel → Ảnh, cho phép thêm ảnh/video rồi bấm Thử lại.")
        }
    }
    static func savePhotos(_ file: URL) async throws {
        try await requirePhotoAccess()
        guard file.isFileURL, ((try file.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0) > 0 else {
            throw LocalReelError(message: "Chưa lưu được vào Photos vì file video không còn hoặc chưa hoàn tất. Hãy thử lại.")
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .video, fileURL: file, options: nil)
            }
        } catch {
            throw LocalReelError(message: "Chưa lưu được vào Photos. Kiểm tra dung lượng trống và quyền Ảnh rồi bấm Thử lại.")
        }
    }
}
