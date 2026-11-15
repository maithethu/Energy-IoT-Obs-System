-- =====================================================================
-- migrate_v21.sql – Nâng cấp DB v2 → v2.1 tại chỗ (sped.md §9, R3 / D7 / D8). Chỉ THÊM, không đổi cột cũ.
--   * replay_session: định danh lần phát (mã sự cố + thời điểm bắt đầu)
--   * fact_alert.replay_id, fact_alert.close_reason ('REPLAY_END' = đóng do kết thúc lần phát)
--   * fact_alert_action.return_reason thêm 'REPLAY_END'
-- Chạy sau migrate_v2.sql; sau đó chạy db/init/003_views.sql. Chạy lại nhiều lần không lỗi.
-- =====================================================================
BEGIN;

CREATE TABLE IF NOT EXISTS replay_session (
    replay_id  BIGSERIAL PRIMARY KEY,
    event_id   TEXT,
    speed      DOUBLE PRECISION,
    data_from  TIMESTAMP,
    data_to    TIMESTAMP,
    started_at TIMESTAMPTZ NOT NULL DEFAULT now(),
    ended_at   TIMESTAMPTZ
);

ALTER TABLE fact_alert ADD COLUMN IF NOT EXISTS replay_id    BIGINT REFERENCES replay_session (replay_id),
                       ADD COLUMN IF NOT EXISTS close_reason TEXT;
ALTER TABLE fact_alert DROP CONSTRAINT IF EXISTS fact_alert_close_reason_check;
ALTER TABLE fact_alert ADD CONSTRAINT fact_alert_close_reason_check CHECK (close_reason IN ('REPLAY_END'));

ALTER TABLE fact_alert_action DROP CONSTRAINT IF EXISTS fact_alert_action_return_reason_check;
ALTER TABLE fact_alert_action ADD CONSTRAINT fact_alert_action_return_reason_check
    CHECK (return_reason IN ('SAFE', 'TIMEOUT', 'REPLAY_END'));

COMMIT;
