#!/usr/bin/env bash
# Chuẩn bị dữ liệu demo – CHẠY MỘT LẦN trước buổi demo (v2.1, sped.md §9 R4). Chạy lại an toàn.
#   scripts/prepare_demo.sh                    # bỏ qua bước đã xong
#   scripts/prepare_demo.sh --rebuild-history  # dựng lại energy_history từ đầu
#   scripts/prepare_demo.sh --skip-enrich      # không phát lại các sự cố làm giàu dữ liệu trang 3–4
# Các bước:
#   1. Kiểm tra / bật container energy-timescaledb, energy-dashboard; nâng DB energy lên v2.1 nếu cần
#   2. Build lại image dashboard từ code hiện tại và tạo lại container
#   3. Dựng DB energy_history (8 tháng, detector chạy một lượt – run HISTORY) nếu chưa có
#   4. Cài lớp gold (powerbi/gold_views.sql) trên energy và energy_history
#   5. Làm giàu dữ liệu trang 3–4: phát lại EV028, EV022, EV035, EV036 (×60, trước 1 giờ) kèm giả lập người trực
#      (đúng hạn / trễ / bỏ qua → bỏ lỡ / báo giả). Không dùng EV031, EV033 (để dành cho phần demo trực tiếp).
# Producer / detector / giả lập chạy trong container (không cần psycopg trên máy).
set -euo pipefail
cd "$(dirname "$0")/.."

DB=energy-timescaledb
DASH=energy-dashboard
REBUILD_HISTORY=0; ENRICH=1
for arg in "$@"; do
    case "$arg" in
        --rebuild-history) REBUILD_HISTORY=1 ;;
        --skip-enrich) ENRICH=0 ;;
        *) echo "Tham số không hợp lệ: $arg" >&2; exit 2 ;;
    esac
done
HOST_DIR=$(pwd -W 2>/dev/null || pwd)
psql_db() { docker exec -i "$DB" psql -U energy -d "$1" -v ON_ERROR_STOP=1 -q "${@:2}"; }
scalar()  { docker exec "$DB" psql -U energy -d "$1" -tAc "$2"; }
step()    { echo; echo "=== $*"; }

# ------------------------------------------------------------------ 1. container + DB v2.1
step "1. Kiểm tra container và phiên bản DB"
for c in "$DB" "$DASH"; do
    if ! docker inspect "$c" >/dev/null 2>&1; then
        echo "Không có container $c. Chạy 'docker compose up -d --build' trước." >&2; exit 1
    fi
    [ "$(docker inspect -f '{{.State.Running}}' "$c")" = "true" ] || { echo "Bật $c"; docker start "$c" >/dev/null; }
done
until docker exec "$DB" pg_isready -U energy -d energy >/dev/null 2>&1; do sleep 2; done
if [ "$(scalar energy "SELECT to_regclass('replay_control') IS NULL
                         AND EXISTS (SELECT 1 FROM information_schema.columns
                                      WHERE table_name = 'cleaned' AND column_name = 'ingested_at')")" != "t" ]; then
    echo "DB energy còn schema v1 → chạy sql/migrate_v2.sql"
    psql_db energy < sql/migrate_v2.sql
fi
psql_db energy < sql/migrate_v21.sql 2>&1 | grep -v NOTICE || true
psql_db energy < db/init/003_views.sql 2>&1 | grep -v NOTICE || true
psql_db energy < sql/elt.sql
echo "DB energy: v2.1 OK (replay_session: $(scalar energy "SELECT count(*) FROM replay_session") lần phát)"

# ------------------------------------------------------------------ 2. dashboard
step "2. Build lại dashboard từ code hiện tại"
IMAGE=$(docker inspect -f '{{.Config.Image}}' "$DASH")
PROJECT=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$DASH")
docker build -q -t "$IMAGE" dashboard >/dev/null
docker compose -p "$PROJECT" up -d --no-build --force-recreate dashboard 2>&1 | tail -1
until [ "$(curl -s localhost:8501/_stcore/health || true)" = "ok" ]; do sleep 2; done
echo "Dashboard: http://localhost:8501 OK (image $IMAGE, project $PROJECT)"

# ------------------------------------------------------------------ 3. energy_history
step "3. DB energy_history (8 tháng, run HISTORY)"
NETWORK=$(docker inspect "$DB" --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}}{{end}}')
run_py() {  # run_py <lệnh python...> – chạy tới khi xong
    MSYS_NO_PATHCONV=1 docker run --rm --network "$NETWORK" \
        -v "$HOST_DIR/detector:/app/detector:ro" -v "$HOST_DIR/producer:/app/producer:ro" -v "$HOST_DIR/data:/app/data:ro" \
        -w /app python:3.12-slim sh -c "pip install -q 'psycopg[binary]>=3.1,<4' 2>/dev/null; python -u $*"
}
if [ "$REBUILD_HISTORY" = "1" ]; then
    docker exec "$DB" dropdb -U energy --if-exists energy_history
fi
if [ "$(scalar energy "SELECT count(*) FROM pg_database WHERE datname = 'energy_history'")" = "0" ]; then
    echo "Tạo energy_history"
    docker exec "$DB" createdb -U energy energy_history
    for f in db/init/001_schema.sql db/init/002_load_data.sql db/init/003_views.sql sql/elt.sql; do
        psql_db energy_history < "$f" >/dev/null 2>&1
    done
    psql_db energy_history -c "\copy raw (ts,station_id,hufl,hull,mufl,mull,lufl,lull,ot) FROM '/data/scenario_data.csv' CSV HEADER"
    psql_db energy_history -c "CALL sp_raw_to_cleaned()"
    psql_db energy_history -c "CALL refresh_continuous_aggregate('agg_hourly', NULL, NULL)"
else
    psql_db energy_history < sql/migrate_v21.sql 2>&1 | grep -v NOTICE || true
    psql_db energy_history < db/init/003_views.sql 2>&1 | grep -v NOTICE || true
fi
if [ "$(scalar energy_history "SELECT count(*) FROM fact_alert WHERE run_id = 'HISTORY'")" = "0" ]; then
    echo "Chạy detector HISTORY trên 8 tháng"
    run_py "detector/detector.py --source db --run-id HISTORY --once --database-url postgresql://energy:energy@$DB:5432/energy_history"
fi
echo "energy_history: $(scalar energy_history "SELECT count(*) FROM cleaned") bản ghi, \
$(scalar energy_history "SELECT count(*) FROM fact_alert") cảnh báo, $(scalar energy_history "SELECT count(*) FROM eval.event_label") sự cố"

# ------------------------------------------------------------------ 4. gold
step "4. Lớp gold cho Power BI"
for d in energy energy_history; do psql_db "$d" < powerbi/gold_views.sql 2>&1 | grep -v "NOTICE\|DETAIL\|drop cascades" || true; done
echo "gold OK trên energy và energy_history"

# ------------------------------------------------------------------ 5. làm giàu dữ liệu trang 3–4
step "5. Làm giàu dữ liệu diễn tập (trang 3–4)"
if [ "$ENRICH" = "1" ]; then
    MSYS_NO_PATHCONV=1 docker cp scripts/simulate_operator.py "$DASH":/app/simulate_operator.py
    # sự cố : kế hoạch xử lý Đỏ của người trực giả lập
    for item in EV028:ontime EV022:late EV035:ignore EV036:false; do
        ev=${item%%:*}; plan=${item##*:}
        # đã phát thành công = có phiên của sự cố này và phiên đó có sinh cảnh báo
        if [ "$(scalar energy "SELECT count(*) FROM fact_alert a JOIN replay_session rs USING (replay_id)
                                WHERE rs.event_id = '$ev'")" != "0" ]; then
            echo "$ev: đã phát trước đó – bỏ qua"; continue
        fi
        echo "--- $ev (giả lập: $plan)"
        MSYS_NO_PATHCONV=1 docker exec -d "$DASH" sh -c \
            "python /app/simulate_operator.py --red-plan $plan --late-min 35 --minutes 15 > /tmp/sim_$ev.log 2>&1 & echo \$! > /tmp/sim.pid; wait"
        USE_DOCKER=1 bash scripts/replay_event.sh "$ev" 60 1 | grep -E "replay_id|Xong:|== Xong|Detector|Đang có" || true
        n=$(scalar energy "SELECT count(*) FROM fact_alert WHERE replay_id =
                           (SELECT max(replay_id) FROM replay_session WHERE event_id = '$ev')")
        echo "$ev: $n cảnh báo"
        [ "$n" != "0" ] || echo "CẢNH BÁO: $ev không sinh cảnh báo nào – kiểm tra detector (docker logs energy-detector-live)" >&2
        MSYS_NO_PATHCONV=1 docker exec "$DASH" sh -c "kill \$(cat /tmp/sim.pid) 2>/dev/null; grep -v -i warn /tmp/sim_$ev.log | grep -v '^\$' || true"
    done
else
    echo "Bỏ qua (--skip-enrich)"
fi

step "Tóm tắt"
docker exec "$DB" psql -U energy -d energy -c "
SELECT rs.replay_id, rs.event_id, to_char(rs.started_at AT TIME ZONE 'Asia/Ho_Chi_Minh', 'DD/MM HH24:MI') AS bat_dau,
       count(a.*) FILTER (WHERE a.severity = 'RED') AS do, count(a.*) FILTER (WHERE a.severity = 'YELLOW') AS vang,
       count(a.*) FILTER (WHERE a.severity = 'SENSOR') AS cam_bien
  FROM replay_session rs LEFT JOIN fact_alert a ON a.replay_id = rs.replay_id
 GROUP BY 1, 2, 3 ORDER BY 1"
echo "Xong. Mở powerbi/CanhBaoQuaTai_v2/CanhBaoQuaTai_v2.pbip → Refresh. Demo: scripts/replay_event.sh EV031 rồi EV033."
