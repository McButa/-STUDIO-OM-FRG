"""
Time-series inverter/logger CSV reader.

Why this file exists: an inverter data-log export (e.g. a Huawei/FusionSolar
style "Inverter_..._INVERTER-01_....csv") is a full day of 5-minute-interval
readings — commonly 200-300 rows x 30+ columns. Sending that as raw text to
an LLM would be expensive AND would reintroduce exactly the "same input,
different answer" unreliability this whole system exists to eliminate for a
domain (arithmetic over a table) that Python does exactly and for free. So
this file does ALL the actual computation — min/max/mean, uptime/downtime,
per-string comparison — in plain Python, and produces a ready-made
evidence_finding with a human-readable Thai summary + structured
key_measurements. No Gemini call is needed for this file type at all.

Column layouts differ by logger brand/export settings ("บางทีแต่ละทีมีข้างใน
ไม่เหมือนกัน" — the exact concern this module is built to survive), so nothing
here assumes a fixed row number for the header or a fixed column order —
only that certain columns can be recognized by keyword in their names.
"""

import csv
import io
import re
import statistics
from datetime import datetime

from core.peer_comparison import compare_to_peers
from core.threshold_rules import _higher

# Keyword patterns used to recognize a column regardless of exact wording/
# unit formatting, since exports vary ("Active power(kW)" vs "Active Power
# (kW)" vs "有功功率(kW)", etc. — we match on the English keyword substrings
# actually seen across common exports; a column that matches none of these
# is simply not summarized, not guessed at).
_COLUMN_PATTERNS = {
    "timestamp": re.compile(r"start time|^time$|timestamp", re.IGNORECASE),
    "active_power": re.compile(r"active power", re.IGNORECASE),
    "status": re.compile(r"inverter status|^status$", re.IGNORECASE),
    "internal_temp": re.compile(r"internal temperature", re.IGNORECASE),
    "total_yield": re.compile(r"total yield", re.IGNORECASE),
    "grid_current": re.compile(r"grid current", re.IGNORECASE),
}
_PV_STRING_CURRENT = re.compile(r"pv\s*(\d+)\s*input current", re.IGNORECASE)

# Status text is free-form ("OFF : instructed shutdown", "Standby :  no
# sunlight", "Grid connected", "Grid connected : self derating") — bucket by
# keyword rather than exact string match, since wording varies by brand/fw.
_STATUS_BUCKETS = [
    ("off_commanded", re.compile(r"\boff\b.*shutdown|instructed shutdown", re.IGNORECASE)),
    ("standby_no_sun", re.compile(r"standby.*(no sun|no light)", re.IGNORECASE)),
    ("fault_alarm", re.compile(r"fault|alarm|error|trip", re.IGNORECASE)),
    ("derating", re.compile(r"derat", re.IGNORECASE)),
    ("producing", re.compile(r"grid connected", re.IGNORECASE)),
]


def _bucket_status(text: str) -> str:
    for bucket, pattern in _STATUS_BUCKETS:
        if pattern.search(text):
            return bucket
    return "other"


def _sniff_header_row(rows: list) -> int:
    """Find the real header row among leading metadata lines (export
    timestamps, legend text, etc.) by looking for a row that names actual
    measurement columns, rather than assuming a fixed row number."""
    for i, row in enumerate(rows[:30]):
        joined = ",".join(row).lower()
        if ("time" in joined) and any(k in joined for k in ("power", "voltage", "current", "yield", "temperature")):
            return i
    raise ValueError("ไม่พบแถวหัวตาราง (header) ที่จดจำได้ในไฟล์ CSV นี้ — รูปแบบไฟล์อาจไม่ตรงกับที่รองรับไว้")


def _to_float(value):
    if value is None:
        return None
    try:
        cleaned = value.strip()
        if not cleaned or cleaned.upper() in ("N/A", "-", "NA"):
            return None
        return float(cleaned)
    except (TypeError, ValueError, AttributeError):
        return None


def _parse_timestamp(value: str):
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y/%m/%d %H:%M:%S"):
        try:
            return datetime.strptime(value.strip(), fmt)
        except (ValueError, AttributeError):
            continue
    return None


def read_inverter_timeseries_csv(raw_bytes: bytes, source_file: str) -> dict:
    """Parse one inverter's day-log CSV and return a ready-made
    evidence_finding dict (category, source_file, observed_data,
    key_measurements). Raises ValueError with a Thai message if the file
    doesn't look like a recognizable inverter log at all — the caller
    should surface that as an UNCONFIRMED/needs-review note rather than
    silently dropping the file."""
    text = raw_bytes.decode("utf-8-sig", errors="ignore")
    all_rows = list(csv.reader(io.StringIO(text)))
    if not all_rows:
        raise ValueError("ไฟล์ CSV ว่างเปล่าหรืออ่านไม่ได้")

    header_idx = _sniff_header_row(all_rows)
    header = [h.strip() for h in all_rows[header_idx]]
    data_rows = [r for r in all_rows[header_idx + 1:] if any(cell.strip() for cell in r)]

    col_index = {}
    pv_string_cols = {}  # string number -> column index
    for i, name in enumerate(header):
        for key, pattern in _COLUMN_PATTERNS.items():
            if key not in col_index and pattern.search(name):
                col_index[key] = i
        pv_match = _PV_STRING_CURRENT.search(name)
        if pv_match:
            pv_string_cols[int(pv_match.group(1))] = i

    if "timestamp" not in col_index or not data_rows:
        raise ValueError("ไม่พบคอลัมน์เวลา หรือไม่มีข้อมูลแถวใดเลยในไฟล์ CSV นี้")

    def col(row, key):
        idx = col_index.get(key)
        return row[idx].strip() if idx is not None and idx < len(row) else None

    timestamps = [_parse_timestamp(col(r, "timestamp")) for r in data_rows]
    valid_rows = [(ts, r) for ts, r in zip(timestamps, data_rows) if ts is not None]
    if not valid_rows:
        raise ValueError("อ่านค่าเวลาจากไฟล์ CSV นี้ไม่ได้แม้แต่แถวเดียว")
    valid_rows.sort(key=lambda pair: pair[0])
    start_ts, _ = valid_rows[0]
    end_ts, _ = valid_rows[-1]

    # --- Active power stats ---
    active_power_values = [v for _, r in valid_rows if (v := _to_float(col(r, "active_power"))) is not None]
    peak_active_power = max(active_power_values) if active_power_values else None

    # --- Status time breakdown (bucketed) ---
    interval_minutes = None
    if len(valid_rows) >= 2:
        deltas = [(valid_rows[i][0] - valid_rows[i - 1][0]).total_seconds() / 60 for i in range(1, len(valid_rows))]
        interval_minutes = statistics.median(deltas)
    status_minutes = {}
    if "status" in col_index and interval_minutes:
        for _, r in valid_rows:
            raw_status = col(r, "status") or ""
            bucket = _bucket_status(raw_status)
            status_minutes[bucket] = status_minutes.get(bucket, 0) + interval_minutes

    # --- Total yield delta (cumulative counter) ---
    yield_values = [v for _, r in valid_rows if (v := _to_float(col(r, "total_yield"))) is not None]
    yield_delta = None
    if len(yield_values) >= 2:
        first_y, last_y = yield_values[0], yield_values[-1]
        if last_y >= first_y:
            yield_delta = round(last_y - first_y, 3)
        # if the counter went DOWN, it likely reset mid-window — don't
        # report a fabricated negative "production" figure

    # --- Internal temperature ---
    temp_values = [v for _, r in valid_rows if (v := _to_float(col(r, "internal_temp"))) is not None]
    temp_max = max(temp_values) if temp_values else None
    temp_min = min(temp_values) if temp_values else None

    # --- Per-PV-string peak current, peer-compared to find a dead/weak string ---
    string_peaks = {}
    for string_no, idx in pv_string_cols.items():
        values = [v for _, r in valid_rows if idx < len(r) and (v := _to_float(r[idx])) is not None]
        if values:
            string_peaks[string_no] = max(values)
    string_peer_results = compare_to_peers(
        [{"id": sn, "value": v} for sn, v in string_peaks.items()],
        bad_direction="low",
    )
    weak_strings = [r for r in string_peer_results if r["is_outlier"]]

    # --- Build human-readable summary (Thai) ---
    lines = []
    lines.append(
        f"ข้อมูล time-series จาก {start_ts.strftime('%Y-%m-%d %H:%M')} ถึง {end_ts.strftime('%Y-%m-%d %H:%M')} "
        f"({len(valid_rows)} จุดข้อมูล)"
    )
    if peak_active_power is not None:
        lines.append(f"กำลังผลิตสูงสุดที่บันทึกได้ในช่วงนี้: {peak_active_power} kW")
    if yield_delta is not None:
        lines.append(f"พลังงานที่ผลิตได้สะสมในช่วงนี้ (Total yield delta): {yield_delta} kWh")
    if temp_max is not None:
        lines.append(f"อุณหภูมิภายในเครื่อง: ต่ำสุด {temp_min}°C สูงสุด {temp_max}°C")
    if status_minutes:
        readable = ", ".join(f"{k}: {round(v)} นาที" for k, v in sorted(status_minutes.items(), key=lambda kv: -kv[1]))
        lines.append(f"สถานะเครื่องแยกตามช่วงเวลา: {readable}")
        off_commanded = status_minutes.get("off_commanded", 0)
        if off_commanded >= 180:  # 3+ hours of commanded-off is worth a human's attention
            hh, mm = divmod(round(off_commanded), 60)
            lines.append(
                f"หมายเหตุ: เครื่องอยู่ในสถานะ 'OFF : instructed shutdown' (ปิดโดยคำสั่ง ไม่ใช่ปิดเพราะไม่มีแดด) "
                f"ยาวนาน {hh} ชั่วโมง {mm} นาที ในช่วงเวลานี้ — ควรตรวจสอบว่าเป็นการปิดเพื่อบำรุงรักษาตามแผน "
                "หรือมีคนลืมเปิดเครื่องกลับ"
            )
    if weak_strings:
        weak_ids = ", ".join(f"PV{r['id']}" for r in weak_strings)
        best = max(string_peaks.values()) if string_peaks else None
        lines.append(
            f"หมายเหตุ: กระแสสูงสุดของสตริง {weak_ids} ต่ำกว่าสตริงที่ดีที่สุดในชุดเดียวกัน (สูงสุด {best} A) "
            "อย่างมีนัยสำคัญ ควรตรวจสอบสตริงนี้ (แผงบังแดด/สายหลุด/ฟิวส์ขาด)"
        )

    key_measurements = []
    if peak_active_power is not None:
        key_measurements.append({"parameter": "active_power_kw_peak", "value": peak_active_power, "unit": "kW", "comparator": "="})
    if yield_delta is not None:
        key_measurements.append({"parameter": "daily_energy_kwh_delta", "value": yield_delta, "unit": "kWh", "comparator": "="})
    if temp_max is not None:
        key_measurements.append({"parameter": "internal_temp_c_max", "value": temp_max, "unit": "C", "comparator": "="})
    if status_minutes.get("off_commanded"):
        key_measurements.append({"parameter": "off_commanded_minutes", "value": round(status_minutes["off_commanded"]), "unit": "min", "comparator": "="})

    # Severity is decided right here, in code — this whole finding is
    # already 100% computed, there's no LLM judgment step for it to pass
    # through. A weak-string proportion >= 30% of the array materially
    # impairs production (not just one bad apple), so it's CRITICAL rather
    # than WARNING; a smaller proportion, or just extended off-time, is
    # WARNING (worth a human's attention, not yet a confirmed major loss).
    severity = "NORMAL"
    if weak_strings and string_peaks:
        weak_fraction = len(weak_strings) / len(string_peaks)
        severity = _higher(severity, "CRITICAL" if weak_fraction >= 0.3 else "WARNING")
    if status_minutes.get("off_commanded", 0) >= 180:
        severity = _higher(severity, "WARNING")

    return {
        "category": "Inverter & Monitoring",
        "source_file": source_file,
        "observed_data": " ".join(lines),
        "severity": severity,
        "engineering_diagnosis": (
            f"[คำนวณจากไฟล์ CSV โดยตรง: พบสตริง {len(weak_strings)} จาก {len(string_peaks)} สตริง ที่กระแสสูงสุดต่ำกว่าสตริงที่ดีที่สุดอย่างมีนัยสำคัญ]"
            if weak_strings else ""
        ),
        "key_measurements": key_measurements,
    }

