#!/usr/bin/env bash
# Phát lại MỘT đoạn demo (v2.1, sped.md §9):
#   scripts/replay_event.sh EV031        đoạn 1 – quá tải Trạm Y: Vàng → Đỏ → chuyển tải → trả tải (~15 phút)
#   scripts/replay_event.sh EV033        đoạn 2 – cảm biến kẹt Trạm Y → chuyển bảo trì (~13 phút)
# Tùy chọn: scripts/replay_event.sh <EV> [speed] [before_hours]   (mặc định 20 và 1)
#   speed 20      : 15 phút dữ liệu = 45 giây thật
#   before_hours 1: phát trước sự cố 1 giờ (đủ 4 bản ghi để detector tính tốc độ)
# Dữ liệu KHÔNG dừng khi lên Đỏ; thời hạn theo giờ dữ liệu (Đỏ ≤ 30′ ≈ 1′30″ thật, Vàng ≤ 60′ ≈ 3′ thật).
# Mỗi lần chạy: kết thúc lần phát trước (đóng cảnh báo còn mở, KHÔNG xóa lịch sử cảnh báo / thao tác),
#   xóa dữ liệu cảm biến → chạy detector (nền) → producer --event (tạo replay_session mới) → tắt detector.
# Producer / detector chạy:
#   - mặc định bằng Python trên máy (pip install -r detector/requirements.txt);
#   - USE_DOCKER=1: trong container python:3.12-slim (máy không cài được psycopg).
# Cần: container energy-timescaledb đang chạy và đã chạy scripts/prepare_demo.sh một lần.
set -euo pipefail
cd "$(dirname "$0")/.."

EVENT="${1:?Cách dùng: scripts/replay_event.sh EV031|EV033 [speed] [before_hours]}"
SPEED="${2:-20}"
BEFORE="${3:-1}"
PYTHON="${PYTHON:-python}"
DB_CONTAINER="${DB_CONTAINER:-energy-timescaledb}"
DB_USER="${POSTGRES_USER:-energy}"; DB_PASS="${POSTGRES_PASSWORD:-energy}"; DB_NAME="${POSTGRES_DB:-energy}"
case "$EVENT" in
    EV031|EV033) ;;
    *) echo "Lưu ý: kịch bản demo là EV031 và EV033; vẫn phát $EVENT." >&2 ;;
esac

# Chốt chống chạy song song: hai lần phát cùng lúc sẽ xóa dữ liệu / container của nhau
if [ "$(docker inspect -f '{{.State.Running}}' energy-producer-live 2>/dev/null)" = "true" ]; then
    echo "Đang có một lần phát khác (container energy-producer-live). Chờ xong hoặc: docker rm -f energy-producer-live" >&2
    exit 1
fi

echo "== Kết thúc lần phát trước, xóa dữ liệu cảm biến (giữ lịch sử cảnh báo)"
docker exec -i "$DB_CONTAINER" psql -U "$DB_USER" -d "$DB_NAME" -v ON_ERROR_STOP=1 -q < sql/reset_replay.sql

if [ "${USE_DOCKER:-0}" = "1" ]; then
    NETWORK=$(docker inspect "$DB_CONTAINER" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
    URL="postgresql://${DB_USER}:${DB_PASS}@${DB_CONTAINER}:5432/${DB_NAME}"
    HOST_DIR=$(pwd -W 2>/dev/null || pwd)   # Git Bash trên Windows: E:/... cho Docker Desktop
    run_py() {  # run_py <tên container> <lệnh python...>  (chạy nền)
        local name=$1; shift
        docker rm -f "$name" >/dev/null 2>&1 || true
        MSYS_NO_PATHCONV=1 docker run -d --name "$name" --network "$NETWORK" \
            -v "$HOST_DIR/detector:/app/detector:ro" -v "$HOST_DIR/producer:/app/producer:ro" -v "$HOST_DIR/data:/app/data:ro" \
            -w /app python:3.12-slim sh -c "pip install -q 'psycopg[binary]>=3.1,<4' 2>/dev/null; python -u $*" >/dev/null
    }
    echo "== Chạy detector trong container energy-detector-live"
    run_py energy-detector-live "detector/detector.py --source db --run-id LIVE --poll-seconds 2 --database-url $URL"
    trap 'docker rm -f energy-detector-live >/dev/null 2>&1 || true' EXIT
    sleep 20                                 # chờ detector cài psycopg và mở kết nối
    if [ "$(docker inspect -f '{{.State.Running}}' energy-detector-live)" != "true" ]; then
        echo "Detector đã dừng:" >&2; docker logs energy-detector-live >&2; exit 1
    fi
    echo "== Phát lại $EVENT ở x$SPEED, trước sự cố ${BEFORE} giờ. Mở http://localhost:8501 để xử lý."
    run_py energy-producer-live "producer/producer.py --event $EVENT --speed $SPEED --before-hours $BEFORE --dsn $URL"
    docker logs -f energy-producer-live
else
    export DATABASE_URL="${DATABASE_URL:-postgresql://${DB_USER}:${DB_PASS}@localhost:5433/${DB_NAME}}"
    echo "== Chạy detector (log: detector_${EVENT}.log)"
    "$PYTHON" detector/detector.py --source db --run-id LIVE --poll-seconds 2 > "detector_${EVENT}.log" 2>&1 &
    DETECTOR=$!
    trap 'kill $DETECTOR 2>/dev/null || true' EXIT
    sleep 2
    kill -0 $DETECTOR 2>/dev/null || { cat "detector_${EVENT}.log"; exit 1; }
    echo "== Phát lại $EVENT ở x$SPEED, trước sự cố ${BEFORE} giờ. Mở http://localhost:8501 để xử lý."
    "$PYTHON" producer/producer.py --event "$EVENT" --speed "$SPEED" --before-hours "$BEFORE"
fi
echo "== Chờ detector xử lý các bản ghi cuối"
sleep 15
echo "== Xong $EVENT. Power BI: bấm Refresh để cập nhật trang 3–4."
