-- =====================================================================
-- reset_replay.sql – Chuẩn bị DB cho một lần phát mới (v2.1, sped.md §9 R3).
-- CHỈ xóa dữ liệu cảm biến (raw, cleaned) và trạng thái detector.
-- GIỮ: lịch sử cảnh báo + thao tác người trực (fact_alert, fact_alert_action, replay_session),
--       dim_*, param_threshold, eval.event_label, thủ tục ELT và job.
-- Trước khi xóa: kết thúc lần phát trước – đóng cảnh báo còn mở (close_reason = 'REPLAY_END', không tính
-- là bỏ lỡ) và trả các lần chuyển tải còn hiệu lực (return_reason = 'REPLAY_END').
-- Dừng detector TRƯỚC khi chạy (detector giữ trạng thái trong bộ nhớ), chạy lại sau.
--
--   docker compose exec -T timescaledb psql -U energy -d energy -v ON_ERROR_STOP=1 < sql/reset_replay.sql
-- =====================================================================
BEGIN;
-- 1. Trả chuyển tải còn hiệu lực của run LIVE (mốc trả = mốc dữ liệu cuối của trạm nguồn, ít nhất sau 1 mốc)
UPDATE fact_alert_action x
   SET effective_to_ts = GREATEST(COALESCE((SELECT max(c.ts) FROM cleaned c WHERE c.station_id = a.station_id),
                                           x.effective_from_ts), x.effective_from_ts + INTERVAL '15 minutes'),
       return_reason = 'REPLAY_END'
  FROM fact_alert a
 WHERE a.alert_id = x.alert_id AND a.run_id = 'LIVE' AND x.effective_to_ts IS NULL;

-- 2. Đóng cảnh báo còn mở của run LIVE
UPDATE fact_alert
   SET status = 'RESOLVED', resolved_ts = last_ts, resolved_at = now(), close_reason = 'REPLAY_END',
       updated_at = now()
 WHERE run_id = 'LIVE' AND status IN ('OPEN', 'ACK', 'ACTION_TAKEN');

-- 3. Kết thúc phiên phát còn dở
UPDATE replay_session SET ended_at = now() WHERE ended_at IS NULL;

-- 4. Xóa dữ liệu cảm biến và trạng thái detector của run LIVE
DELETE FROM detector_checkpoint WHERE run_id = 'LIVE';
DELETE FROM cleaned;
DELETE FROM raw;
UPDATE etl_watermark SET last_ingested_at = '1900-01-01', updated_at = now();
COMMIT;
CALL refresh_continuous_aggregate('agg_hourly', NULL, NULL);
SELECT (SELECT count(*) FROM raw) AS raw, (SELECT count(*) FROM cleaned) AS cleaned,
       (SELECT count(*) FROM fact_alert WHERE run_id = 'LIVE') AS live_alerts_kept,
       (SELECT count(*) FROM replay_session) AS replays;
