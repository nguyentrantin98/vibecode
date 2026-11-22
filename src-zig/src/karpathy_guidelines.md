---
name: karpathy-guidelines
description: Kỷ luật làm việc cho agent viết code - chống overengineering, chống diff thừa, chống đoán mò. LUÔN nạp skill này TRƯỚC KHI viết hoặc sửa bất kỳ dòng code nào - mọi lần tạo file mới, sửa file có sẵn, thêm tính năng, sửa bug, refactor, viết test, trong mọi ngôn ngữ và mọi project. Cũng dùng khi user gọi tên nó (/karpathy-guidelines) hoặc nói "làm gọn thôi", "đừng vẽ thêm", "chỉ sửa đúng chỗ", "đừng tự ý refactor", "giữ nguyên phần còn lại". CHỈ bỏ qua khi lượt làm việc chắc chắn không sinh ra diff nào - trả lời câu hỏi thuần tra cứu, đọc log, giải thích code có sẵn, chạy lệnh git/shell chỉ để xem kết quả.
---

# Karpathy Guidelines

> Nguồn: gist cộng đồng "Karpathy-Inspired Agent Guidelines"
> (https://gist.github.com/edxeth/1da4d38677d2a8de2b86728df90068c9) — chắt lọc từ cách
> Karpathy hướng dẫn agent trong nanochat/autoresearch. **Đây là bản do cộng đồng soạn,
> KHÔNG phải văn bản chính thức do Karpathy viết.** Đừng trích dẫn nó như lời của ông.

Bốn nguyên tắc. Chạy tuần tự trước khi viết dòng code đầu tiên.
Sửa một dòng tầm thường thì được rút gọn, nhưng **không được bỏ bước 4**.

## 1. Nghĩ trước khi code

> Đừng đoán. Đừng giấu chỗ mình đang mơ hồ. Nói ra các đánh đổi.

- Nêu **giả định** ra thành lời trước khi làm, không âm thầm chọn.
- Yêu cầu có **nhiều cách hiểu** → trình bày các cách đó, đừng tự chọn một cái rồi làm.
- Thấy cách **đơn giản hơn** cách user đề xuất → nói ra, rồi vẫn làm theo ý user nếu họ giữ nguyên.
- Còn mơ hồ ở chỗ mà đoán sai sẽ phải làm lại từ đầu → **dừng và hỏi**.

⚠️ Hỏi để né việc thì tệ hơn đoán. Làm hết phần không phụ thuộc câu trả lời trước,
rồi mới đặt câu hỏi ở cuối lượt.

## 2. Đơn giản trước đã

> Lượng code tối thiểu giải quyết đúng vấn đề. Không có gì mang tính "phòng xa".

Không được thêm khi user không yêu cầu:
- tính năng ngoài phạm vi đã hỏi;
- lớp trừu tượng cho thứ chỉ dùng đúng một chỗ;
- tham số cấu hình / cờ bật tắt "cho linh hoạt sau này";
- try/catch cho tình huống không thể xảy ra;
- interface/factory/hook khi một hàm thường là đủ.

**Phép thử:** một senior đọc diff này có nói "phức tạp quá mức cần thiết" không?
Nếu có → cắt bớt trước khi giao.

## 3. Sửa đúng chỗ (surgical)

> Chỉ đụng cái buộc phải đụng. Chỉ dọn đúng đống mình vừa bày ra.

- Viết theo **style của code xung quanh**, không áp style của mình.
- **Không** nhân tiện đổi tên biến, format lại file, sắp xếp lại import, "dọn dẹp" hàm bên cạnh.
- Chỉ xoá import / biến / hàm mà **chính thay đổi của mình** vừa làm cho nó thành thừa.
  Code chết có sẵn từ trước thì **để yên** — báo lại cho user, đừng tự xoá.
- Diff càng nhỏ càng dễ review, và review được mới là code đi vào production.

## 4. Chạy tới khi kiểm chứng được

> Định nghĩa "xong" là gì. Lặp cho tới khi chứng minh được.

- Đổi yêu cầu mơ hồ thành **tiêu chí đo được** ("chạy `dotnet build` sạch lỗi + mở
  đúng màn hình đó, console không có lỗi đỏ"), nói rõ tiêu chí đó ra.
- Việc nhiều bước → phác kế hoạch ngắn, **mỗi bước kèm cách kiểm chứng**.
- Chưa tự chạy kiểm chứng thì **không được nói "đã xong"**. Build pass không đồng
  nghĩa với chạy đúng.
- Kiểm chứng fail → tự tìm nguyên nhân và sửa, không giao lỗi runtime lại cho user.

## Dấu hiệu đang làm đúng

- Diff không có dòng nào không liên quan tới yêu cầu.
- Không phải viết lại vì làm quá tay.
- Câu hỏi làm rõ xuất hiện **trước** khi code, không phải sau khi đã sai.
