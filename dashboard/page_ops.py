"""Trang Điều hành: trạm nào nguy, làm gì trước, và vận hành đang làm tốt đến đâu.

v2 (sped.md §4): dữ liệu không dừng khi lên Đỏ; thời hạn tính theo GIỜ DỮ LIỆU
(Đỏ ≤ 30 phút đến lúc chuyển tải, Vàng ≤ 60 phút đến lúc "Theo dõi").
"""

from __future__ import annotations

import streamlit as st

import common
import db

QUEUE_WIDTHS = [0.4, 1.1, 1.0, 1.8, 2.0, 1.4]
QUEUE_HEADERS = ["#", "Trạm", "Mức", "Tình trạng", "Xử lý · thời hạn (giờ dữ liệu)", ""]


def render() -> None:
    live_block()


@st.fragment(run_every=5)
def live_block() -> None:
    params = db.params_by_station()
    stations = db.station_latest()
    queue = db.open_queue()
    overdue = {x["source_station"] for x in db.transfers() if x["is_overdue"]}
    common.topbar("Điều hành · Giám sát quá tải trạm biến áp")
    if not stations:
        st.info("Chưa có dữ liệu. Hãy chạy producer (xem README: scripts/replay_event.sh).")
        return
    common.section("Tình trạng trạm")
    station_tiles(list(stations.values()), params, overdue)
    common.section(f"Hàng đợi cảnh báo đang mở ({len(queue)})")
    alert_queue(queue, params)


def tile_subline(row: dict, load: float, red_pct: float) -> str:
    level = row["load_level"]
    if level == "SENSOR":
        return "Cảm biến lỗi – số liệu không tin cậy"
    if level == "NORMAL":
        return "Bình thường"
    if row["ttb_min"] is not None:
        return f"Còn {row['ttb_min']:.0f} phút"
    return "Đang quá tải" if load >= red_pct else "Tải không tăng"


def subline_ink(row: dict, load: float, p: dict) -> str:
    level = row["load_level"]
    if level == "SENSOR":
        return common.INK["SENSOR"]
    if level == "NORMAL":
        return common.INK["GREEN"]
    if row["ttb_min"] is not None:
        return common.ttb_ink(row["ttb_min"], p)
    return common.load_ink(load, p)


def transfer_note(row: dict, overdue: bool = False) -> str:
    """Dòng ghi chú khi trạm đang chuyển / nhận tải; nhãn "mô phỏng" đã nằm cạnh con số % nên không lặp lại."""
    if row["transfer_out"]:
        text = f"⇢ đang chuyển −{row['transfer_out']:.2f} · tải đo {row['load_pct']:.1f}%"
        if overdue:
            return (f'<div class="sub" style="color:#4C78A8">{text}</div>'
                    f'<div class="sub blink" style="color:{common.INK["RED"]}">⚠ Chuyển tải quá hạn (≥ 2 giờ)</div>')
    elif row["transfer_in"]:
        text = f"⇠ đang nhận +{row['transfer_in']:.2f} · tải đo {row['load_pct']:.1f}%"
    else:
        return ""
    return f'<div class="sub" style="color:#4C78A8">{text}</div>'


def station_card(row: dict, p: dict, overdue: bool = False) -> str:
    """Viền trái + chip = mức cảnh báo đang mở; số % / mũi tên / thanh = màu theo số liệu."""
    level = row["load_level"]
    load, simulated = common.shown_load(row)
    tag = f' <span style="font-size:0.8rem;color:#4C78A8">{common.SIM_TAG}</span>' if simulated else ""
    sensor = level == "SENSOR"                 # cảm biến lỗi: cả ô chuyển tông xám, số liệu không tin cậy
    number_ink = common.INK["SENSOR"] if sensor else common.load_ink(load, p)
    background = f"{common.COLORS['SENSOR']}33" if sensor else f"{common.COLORS[level]}14"
    trend = common.span("số đo đứng yên", common.INK["SENSOR"]) if sensor else ""
    bar = (f'<div class="bar"><div class="fill" style="width:100%;background:{common.COLORS["SENSOR"]};opacity:.45">'
           f'</div></div>') if sensor else common.load_bar(load, p)
    return (
        f'<div class="card" style="border-left-color:{common.COLORS[level]};background:{background}">'
        f'<div class="name"><span>{row["station_name"]}</span>{common.chip(level)}</div>'
        f'<div><span class="big" style="color:{number_ink}">{load:.1f}%</span>{tag}'
        f'<span class="trend">{trend}</span></div>'
        f'{bar}'
        f'{subline_html(row, load, p)}{transfer_note(row, overdue)}</div>')


def subline_html(row: dict, load: float, p: dict) -> str:
    """Dòng phụ; bỏ "Bình thường" khi đang có dòng chuyển tải (chip mức đã ghi Bình thường)."""
    if row["load_level"] == "NORMAL" and common.shown_load(row)[1]:
        return ""
    return f'<div class="sub" style="color:{subline_ink(row, load, p)}">{tile_subline(row, load, p["red_pct"])}</div>'


def station_tiles(stations: list[dict], params: dict[str, dict], overdue: set[str]) -> None:
    for col, row in zip(st.columns(len(stations)), stations):
        with col:
            st.markdown(station_card(row, params[row["station_id"]], row["station_id"] in overdue),
                        unsafe_allow_html=True)
            if st.button("Xem trạm", key=f"tile_{row['station_id']}", width="stretch"):
                common.open_station(row["station_id"])


def queue_header() -> None:
    cells = "".join(f'<div style="flex:{w}">{t}</div>' for w, t in zip(QUEUE_WIDTHS, QUEUE_HEADERS))
    st.markdown(f'<div class="qhead" style="display:flex;gap:16px;padding-left:12px">{cells}</div>',
                unsafe_allow_html=True)


def owner_text(alert: dict) -> str:
    """Người xử lý và thời gian chờ theo giờ dữ liệu (so với thời hạn của mức)."""
    deadline, waited = alert["deadline_min"], alert["data_wait_min"]
    if alert["handled_ts"] is not None:
        verb = "chuyển tải" if alert["severity"] == "RED" else "theo dõi"
        ink = common.INK["GREEN"] if waited is not None and waited <= deadline else common.INK["RED"]
        return (f"{common.span('✓', common.INK['GREEN'])} {alert['acked_by']} · {verb} sau "
                f"{common.span(f'{waited:.0f}/{deadline} phút', ink)}")
    if alert["severity"] == "SENSOR":
        return (f"{common.span('✓', common.INK['GREEN'])} {alert['acked_by']} · đã chuyển bảo trì"
                if alert["acked_by"] else common.span("Chưa chuyển bảo trì", common.INK["GRAY"]))
    prefix = f"{alert['acked_by']} đang theo dõi · " if alert["acked_by"] else "Chưa xử lý · "
    ink = common.elapsed_ink(waited, deadline)
    return common.span(f"{prefix}đã chờ {waited:.0f}/{deadline} phút", ink)


def alert_queue(alerts: list[dict], params: dict[str, dict]) -> None:
    if not alerts:
        st.success("Không có cảnh báo đang mở.")
        return
    queue_header()
    for index, alert in enumerate(alerts, start=1):
        with st.container(border=alert["is_overdue"]):
            queue_row(index, alert, params[alert["station_id"]])


def queue_row(index: int, alert: dict, p: dict) -> None:
    cols = st.columns(QUEUE_WIDTHS, vertical_alignment="center")
    escalated = alert["is_overdue"]
    stripe = common.COLORS[alert["severity"]]
    cols[0].markdown(f'<span style="border-left:5px solid {stripe};padding-left:8px;font-weight:800">{index}</span>',
                     unsafe_allow_html=True)
    cols[1].markdown(f"**{alert['station_name']}**")
    label = common.LEVEL_LABEL[alert["severity"]] + (" · quá hạn" if escalated else "")
    cols[2].markdown(common.chip(alert["severity"], label, blink=escalated), unsafe_allow_html=True)
    cols[3].markdown(situation_text(alert, p), unsafe_allow_html=True)
    cols[4].markdown(owner_text(alert), unsafe_allow_html=True)
    with cols[5]:
        action_button(alert)


def situation_text(alert: dict, p: dict) -> str:
    """Một dòng tình trạng: % tải và còn bao lâu tới 100% (hoặc lý do không tin số liệu)."""
    if alert["severity"] == "SENSOR":
        return common.span("Số đo đứng yên – không tin số liệu", common.INK["SENSOR"])
    load, ttb = alert["load_pct"], alert["ttb_min"]
    text = common.span(f"{load:.1f}%", common.load_ink(load, p)) if load is not None else "—"
    if ttb is not None:
        text += " · " + common.span(f"còn {ttb:.0f}′ tới 100%", common.ttb_ink(ttb, p))
    elif load is not None and load >= p["red_pct"]:
        text += " · " + common.span("đang quá tải", common.INK["RED"])
    return text


def action_button(alert: dict) -> None:
    key = f"q_{alert['alert_id']}"
    severity, status = alert["severity"], alert["status"]
    if severity == "RED":
        if st.button("Xử lý" if status != "ACTION_TAKEN" else "Xem", key=f"red_{key}", width="stretch"):
            common.open_station(alert["station_id"])
    elif severity == "YELLOW":
        if status == "OPEN":
            if st.button("Theo dõi", key=key, width="stretch"):
                db.follow(alert["alert_id"], common.operator())
                st.rerun()
        elif st.button("Xem", key=key, width="stretch"):
            common.open_station(alert["station_id"])
    else:
        done = alert["root_cause"] == "SENSOR_MAINTENANCE"
        if st.button("Đã chuyển bảo trì" if done else "Chuyển bảo trì", key=key,
                     disabled=done, width="stretch"):
            db.send_to_maintenance(alert["alert_id"], common.operator())
            st.rerun()
