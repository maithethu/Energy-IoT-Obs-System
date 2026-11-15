# Energy-IoT-Obs-System

Hệ thống BI **cảnh báo quá tải trạm biến áp**, có cơ chế **ưu tiên và xếp hạng cảnh báo** trên dashboard điều hành (Streamlit) và báo cáo phân tích (Power BI).

Luồng: phát lại dữ liệu cảm biến → kho dữ liệu chuỗi thời gian → phát hiện → xếp hạng cảnh báo → người trực xử lý (Vàng: **Theo dõi**; Đỏ: **Chuyển tải** hoặc **Báo giả**). Dữ liệu **không dừng** khi lên Đỏ; thời hạn xử lý tính theo **giờ dữ liệu**.

Dữ liệu: ETTm1 + ETTm2 (tải và nhiệt độ dầu của 2 máy biến áp thật, 15 phút/bản ghi), gán cho 4 trạm. Không bơm lỗi nhân tạo.

## 1. Kiến trúc

```
scenario_data.csv → Producer ──► raw (append-only) ──ELT 10s──► cleaned ──► agg_hourly
   (--event EVxxx)                 giữ ingested_at        bản mới nhất    │
                                                                         ▼  v_load_sim (tải đo ± chuyển tải mô phỏng)
                                         Detector ──► fact_alert ◄──► Streamlit (3 trang)
                                            ▲  trả tải SAFE / TIMEOUT       │ Theo dõi / Chuyển tải / Báo giả
                                            └────── fact_alert_action ◄─────┘
```

- **Producer** phát từng mốc `ts` (4 trạm, 1 transaction) vào `raw` bằng `INSERT` thuần. Phát lại cùng mốc chỉ thêm dòng mới.
- **ELT** (`sql/elt.sql`, chạy mỗi 10 giây) lấy bản `raw` có `ingested_at` mới nhất cho mỗi (trạm, ts), tính `s_h`, `load_pct`, ghi `cleaned` bằng `ON CONFLICT DO UPDATE`.
- **Detector** đọc dữ liệu theo thứ tự `ts`, mở/cập nhật/đóng cảnh báo và trả tải. Dữ liệu chạy liên tục, không ai xử lý thì cảnh báo giữ nguyên tới khi tải tự về bình thường.
- **Dashboard** ghi thao tác của người trực, kèm giờ thật (`*_at`) và mốc dữ liệu (`acked_ts`, `action_ts`).
- **Tác dụng chuyển tải là mô phỏng.** Dữ liệu là lịch sử nên lưới thật không đổi. `v_load_sim`: trạm nguồn = S_H đo − X, trạm nhận = S_H đo + X. `cleaned` giữ nguyên số đo.
- **Hai đồng hồ:** `*_ts` là giờ dữ liệu, dùng cho phát hiện **và thời hạn xử lý**. `*_at` là giờ thật, chỉ để tham khảo.
- **Run:** `LIVE` = phát lại có người trực (DB `energy`). `HISTORY` = detector chạy một lượt toàn bộ 8 tháng cho Power BI (DB `energy_history`).

| Service | Công nghệ | Cổng | Vai trò |
|---|---|---|---|
| `timescaledb` | TimescaleDB (PG16) | 5433 | Kho dữ liệu chuỗi thời gian |
| `dashboard` | Streamlit | 8501 | Dashboard điều hành và xử lý cảnh báo |

Chi tiết: `docs/architecture.md` (luồng, quy trình), `docs/erd.md` (schema), `producer/README.md` (producer, ELT), `powerbi/README.md` (Power BI).

## 2. Cài đặt

Cần Docker Compose v2 và Python ≥ 3.10.

```bash
cp .env.example .env
docker compose up -d --build                  # dựng lại dashboard mỗi khi sửa code
P="docker compose exec -T timescaledb psql -U energy -d energy -v ON_ERROR_STOP=1 -q"
$P < sql/elt.sql                              # chỉ khi DB mới
pip install -r detector/requirements.txt      # psycopg 3 (máy không cài được: dùng USE_DOCKER=1, mục 3)
scripts/prepare_demo.sh                       # chuẩn bị dữ liệu demo (mục 3.1)
```

**Nâng cấp DB đã có từ bản cũ** – không cần xóa volume (`scripts/prepare_demo.sh` làm tự động):

```bash
$P < sql/migrate_v2.sql && $P < sql/migrate_v21.sql && $P < db/init/003_views.sql && $P < sql/elt.sql
```

Kiểm tra: `curl -s localhost:8501/_stcore/health` trả về `ok`. `param_threshold` có 4 dòng, `eval.event_label` có **29** dòng (9 quá tải + 20 lỗi cảm biến).

## 3. Chạy demo (2 đoạn: EV031 và EV033)

Tốc độ **×20** (15 phút dữ liệu = 45 giây thật), **phát trước sự cố 1 giờ** (đủ 4 bản ghi để detector tính tốc độ).

### 3.1 Chuẩn bị – chạy MỘT lần trước buổi demo

```bash
scripts/prepare_demo.sh
```

Script (chạy lại an toàn) lần lượt: kiểm tra container, nâng DB lên v2.1 → build lại dashboard → dựng DB `energy_history` (8 tháng, run HISTORY) → cài lớp gold cho Power BI → phát lại 4 sự cố khác (EV028, EV022, EV035, EV036) kèm **giả lập người trực** (đúng hạn / trễ / bỏ qua → bỏ lỡ / báo giả) để trang 3–4 của Power BI có sẵn dữ liệu. Mất khoảng 20 phút. Sau đó mở Power BI và **Refresh** một lần để kiểm tra.

### 3.2 Đoạn 1 – EV031: quá tải Trạm Y (~15 phút)

```bash
scripts/replay_event.sh EV031                # máy không cài được psycopg: USE_DOCKER=1 scripts/replay_event.sh EV031
```

Mở **http://localhost:8501**:

| Phút (×20) | Giờ dữ liệu | Diễn biến | Người trực |
|---|---|---|---|
| ~3 | 10/02 19:45 | Trạm Y lên **Vàng** (tải 91,5%) | **Điều hành** → **Theo dõi** (trong 60′ dữ liệu ≈ 3′ thật) |
| ~7 | 21:00 | Trạm Y lên **Đỏ**: tải **nhảy 93% → 105%** trong một mốc 15 phút | **Xử lý** → trang Chi tiết trạm (trạm dự phòng Trạm 3 ở trên đầu) |
| | | Khung chuyển tải: lượng điền sẵn (~5–7), sức nhận của Trạm 3 | **Xác nhận chuyển tải** trong **30′ dữ liệu ≈ 1′30″ thật** |
| các mốc sau | 21:15 → 22:00 | Tải mô phỏng Trạm Y (nét xanh dương) xuống dưới 85%, Trạm 3 tăng tương ứng | Theo dõi biểu đồ, ghi nguyên nhân |
| | ~22:00 | Tải mô phỏng < 85% hai lần → **cảnh báo đóng** | Xem thẻ **Kết quả xử lý**: đúng hạn |
| ~12–13 | ~23:00 | Tải **đo** < 85% hai lần → **trả tải an toàn (SAFE)** | — |

> Vì sao Vàng ở 19:45 chứ không 19:15: phát trước 1 giờ (từ 18:45) thì lúc 19:15 detector chưa đủ 4 bản ghi để tính tốc độ tăng tải, nên Vàng mở theo ngưỡng 90% (19:45). Đỏ 21:00 là cú nhảy đột ngột – không luật dự báo nào báo trước được; tín hiệu sớm của đoạn này chính là **Vàng** (~1 giờ 15 phút trước).

### 3.3 Đoạn 2 – EV033: cảm biến kẹt Trạm Y (~13 phút)

```bash
scripts/replay_event.sh EV033
```

| Phút (×20) | Giờ dữ liệu | Diễn biến | Người trực |
|---|---|---|---|
| ~5 | 23/02 04:15 | Số đo Trạm Y đứng yên 4 bản ghi → cảnh báo **Cảm biến**: ô trạm và biểu đồ chuyển **xám** ("số liệu không tin cậy") | **Điều hành** → **Chuyển bảo trì** |
| | 04:45 | Số đo thay đổi lại → cảnh báo tự đóng | — |

Chạy EV033 **không xóa** kết quả EV031: reset chỉ xóa dữ liệu cảm biến và trạng thái detector; cảnh báo và thao tác được giữ, gắn mã sự cố + thời điểm phát (`replay_session`). Cảnh báo còn mở của lần trước được đóng với lý do `REPLAY_END` (không tính là bỏ lỡ).

### 3.4 Power BI (~5 phút)

Mở `powerbi/CanhBaoQuaTai_v2/CanhBaoQuaTai_v2.pbip` → **Refresh** → trang 3–4 có kết quả EV031, EV033 (cột mã sự cố) cùng các lần làm giàu dữ liệu.

| Trang | Nguồn |
|---|---|
| 1 · Lưới điện, 2 · Sự cố, 5 · Cảm biến | **Dữ liệu lịch sử 8 tháng đã nạp sẵn** (DB `energy_history`) |
| 3 · Vận hành, 4 · Chuyển tải | **Dữ liệu diễn tập thời gian thực** (DB `energy`, các lần phát lại có người trực) |

Thời hạn xử lý theo **giờ dữ liệu**:

| Mức | Thao tác | Thời hạn | Ở ×20 |
|---|---|---|---|
| Đỏ | **Xác nhận chuyển tải** (hoặc **Báo giả**) | ≤ 30 phút kể từ lúc lên Đỏ | ≈ 1 phút 30 giây thật |
| Vàng | **Theo dõi** | ≤ 60 phút kể từ lúc mở | ≈ 3 phút thật |

Không ai xử lý Đỏ → cảnh báo giữ nguyên tới khi tải tự giảm → **bị bỏ lỡ**. Chuyển tải ≥ 2 giờ mà tải đo vẫn ≥ 90% → **chuyển tải quá hạn**; ≥ 2 giờ và < 90% → trả tải **TIMEOUT**.

### 3.5 Mô hình khi triển khai thật

- **Một kho dữ liệu trung tâm** (TimescaleDB) nhận số đo thật từ trạm thay cho producer phát lại; **Streamlit và Power BI cùng đọc kho này** (không có hai nguồn riêng như bản demo `energy` / `energy_history`).
- Streamlit là màn hình vận hành, tự làm mới mỗi 5 giây.
- Power BI là báo cáo phân tích, **làm mới định kỳ** (lịch Refresh trên Power BI Service qua gateway, ví dụ mỗi giờ / mỗi ca) – **không phải kết nối streaming liên tục**.

## 4. Dashboard (Streamlit)

Ba trang, tự làm mới mỗi 5 giây. Chỉ có một người trực là "Người trực A".

| Trang | Nội dung |
|---|---|
| **Điều hành** | 4 ô trạm (% tải, xu hướng, "Còn X phút", cờ **chuyển tải quá hạn**; ô chuyển **xám** khi cảm biến lỗi). **Hàng đợi** xếp: đang mở → mức (Đỏ > Vàng > Cảm biến) → TTB (khung 10 phút) → khách hàng ưu tiên → % tải. Cột "đã chờ X/30 (hoặc /60) phút dữ liệu"; quá hạn nhấp nháy. Nút: Đỏ **Xử lý**, Vàng **Theo dõi**, Cảm biến **Chuyển bảo trì** |
| **Chi tiết trạm** | **Trạm dự phòng ở trên đầu.** Cảm biến lỗi: thẻ số liệu và dải trên biểu đồ chuyển **xám**. Khi có Đỏ: khung chuyển tải duy nhất + Báo giả, đồng hồ giờ dữ liệu /30′. Khi có Vàng: nút Theo dõi, đồng hồ /60′. Số liệu hiện tại, biểu đồ 24 giờ (tải đo / tải mô phỏng), chuyển tải (lý do trả, quá hạn), lịch sử 7 ngày |
| **Báo cáo quản trị** | Đỏ chuyển tải đúng hạn, Đỏ bị bỏ lỡ, báo giả / tổng Đỏ, Vàng theo dõi đúng hạn; số lần / lượng chuyển tải, trả an toàn, trả do hết giờ, quá hạn; cảnh báo theo trạm × mức; bảng kết quả Đỏ |

Chuyển tải:
- cần giảm = S_H − 0,85 × định mức (thêm dự báo 1 giờ nếu tải đang tăng);
- trạm nhận tối đa = 0,9 × định mức trạm nhận − S_H trạm nhận (kiểm tra lại trong DB lúc ghi);
- cảnh báo đóng khi tải **mô phỏng** < 85% hai lần; trả tải theo tải **đo** (SAFE / TIMEOUT).

Màu chỉ dùng để báo trạng thái: Đỏ `#E02F44`, Vàng `#FADE2A`, Xám `#8E8E8E` (cảm biến), Xanh `#56A64B`. Xanh dương là số liệu mô phỏng.

## 5. Luật phát hiện

Ngưỡng lấy từ `param_threshold`, không hard-code. Detector **không đọc** `event_label`. Một phương pháp duy nhất.

- Tốc độ = `load_pct` − `load_pct` 4 bản ghi trước (%/giờ), trên tải đo.
- TTB = (100 − `load_pct`) / tốc độ × 60. TTB là NULL khi tốc độ ≤ 0 hoặc `load_pct` ≥ 100.
- **Đỏ:** ≥ 100% hoặc TTB ≤ 30. **Vàng:** ≥ 90% hoặc TTB ≤ 60. **Đóng:** < 85% ở 2 bản ghi liên tiếp.
- **Lỗi cảm biến** (mọi lỗi dữ liệu gom về một loại): S_H không đổi ≥ 4 bản ghi → cảnh báo SENSOR, bỏ qua bước xét quá tải.

```bash
python detector/detector.py --source csv                 # chạy 8 tháng trên CSV → alerts.csv
python detector/detector.py --source db --run-id HISTORY --once   # ghi DB energy_history cho Power BI
python -m unittest discover -s detector -v               # unit test
```

## 6. Trạm và dữ liệu

| Trạm | Nguồn | Loại | Định mức | Ghi chú |
|---|---|---|---|---|
| `TRAM_Y` | ETTm1 | Thật | 20,45 | Sát giới hạn (P99 đã loại lỗi × 1,05); 9 đợt quá tải thật |
| `TRAM_2` | ETTm2 | Thật | 68,99 | Tải giảm dần ở năm gần nhất → tối đa chỉ lên Vàng |
| `TRAM_3` | ETTm1 | Dẫn xuất (−7 ngày) | 27,86 | Luôn dư công suất; nhận chuyển tải từ Trạm Y |
| `TRAM_4` | ETTm2 | Dẫn xuất (−14 ngày) | 69,05 | Tối đa chỉ lên Vàng |

- Hiệu chuẩn (16 tháng): 01/07/2016 → 31/10/2017 → P99 và định mức. Kiểm thử (8 tháng): 01/11/2017 → 26/06/2018.
- `scripts/build_scenario.py` dựng lại `scenario_data.csv` từ ETT gốc (không bơm lỗi) và `event_label.csv` (29 sự cố, giữ mã EV gốc).
- Nhãn sự cố chỉ nằm trong `eval.event_label`. Bảng `raw` và `cleaned` không có nhãn.
- Dữ liệu âm ở MUFL/LUFL… là đặc điểm của bộ dữ liệu gốc; S_H chỉ dùng HUFL, HULL.

## 7. Hạn chế

- Chỉ có 2 trạm thật; Trạm 3 và Trạm 4 là bản dời ngày.
- Định mức và hệ số k là giả định của nhóm ("quá tải" là so với định mức tự đặt).
- Tác dụng chuyển tải là mô phỏng; hệ thống không điều khiển lưới.
- Luật TTB nhạy với dao động ngắn: sinh nhiều cảnh báo Vàng/Đỏ không khớp sự cố (xem Power BI trang 2).
- Ngoài phạm vi: trường hợp trạm dự phòng cũng cao tải, tổn thất điện năng.

## 8. Lệnh thường dùng

```bash
docker compose logs -f <service>
docker compose down              # dừng, giữ dữ liệu
docker compose down -v           # dừng và XÓA dữ liệu (cài lại từ db/init/)
```

Không commit file `.env`. Grafana và FastAPI cũ được giữ trong `archive/`, không còn dùng.
