# LocalReel iOS

## Cài và chạy trên iPhone

1. Trên Mac, tải source repo này hoặc clone:

   ```sh
   git clone https://github.com/ChessmanOwO/LocalReel-iOS.git
   cd LocalReel-iOS
   cp Config/Local.xcconfig.example Config/Local.xcconfig
   ```

2. Mở `Config/Local.xcconfig`, điền Team ID và Bundle ID của bạn. Nếu cập nhật app đã cài, dùng đúng Team và Bundle ID cũ. File này đã được Git bỏ qua.
3. Mở `LocalReel.xcodeproj` trong Xcode, kết nối iPhone, chọn thiết bị rồi bấm **Run**. Bật Developer Mode trên iPhone nếu Xcode yêu cầu.
4. Mở LocalReel, dán liên kết và bấm **Tải video trên iPhone**. Cấp quyền thêm video vào Photos khi được hỏi.
5. Giữ app mở. Khi báo **Lưu thành công**, mở Photos để xem video. Nếu chưa có quyền hoặc lưu lỗi, cấp lại quyền trong Cài đặt rồi bấm **Thử lại**.

Không cần Mac/backend khi sử dụng. Cài bằng Personal Team miễn phí thường cần ký và cài lại sau 7 ngày. Bản sửa iOS này chưa được build/kiểm thử trên iPhone trong phiên phát triển hiện tại.
