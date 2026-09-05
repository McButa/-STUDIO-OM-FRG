import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.csv_reader import read_inverter_timeseries_csv

FIXTURE = ROOT / "tests" / "fixtures" / "inverter_log_sample.csv"


def _build_csv(header, rows):
    lines = [
        "Time range:,2026-09-05 00:00:00 - 2026-09-05 23:59:59,",
        "Export time:,2026-09-05 17:29:12,",
        ",".join(header),
    ]
    for r in rows:
        lines.append(",".join(str(v) for v in r))
    return ("\n".join(lines)).encode("utf-8")


# --- Golden test against the real, hand-verified file --------------------

def test_real_sample_file_finds_the_five_dead_strings():
    """Independently verified by hand: PV2, PV5, PV7, PV8, PV11 read exactly
    0.0 A across the entire day while PV1/3/4/6/9/10 reach ~22 A. This is a
    real production-impairing fault (5 of 11 strings dead), not a synthetic
    test case."""
    raw = FIXTURE.read_bytes()
    result = read_inverter_timeseries_csv(raw, FIXTURE.name)
    assert result["severity"] == "CRITICAL"  # 5/11 = 45% >= 30% threshold
    for label in ("PV2", "PV5", "PV7", "PV8", "PV11"):
        assert label in result["observed_data"]
    assert result["category"] == "Inverter & Monitoring"


def test_real_sample_file_flags_extended_commanded_shutdown():
    raw = FIXTURE.read_bytes()
    result = read_inverter_timeseries_csv(raw, FIXTURE.name)
    assert "instructed shutdown" in result["observed_data"]
    assert any(m["parameter"] == "off_commanded_minutes" and m["value"] >= 180 for m in result["key_measurements"])


def test_real_sample_file_computes_correct_yield_delta():
    # First row Total yield = 51.41, last row = 429.75 -> delta 378.34
    raw = FIXTURE.read_bytes()
    result = read_inverter_timeseries_csv(raw, FIXTURE.name)
    delta = [m["value"] for m in result["key_measurements"] if m["parameter"] == "daily_energy_kwh_delta"][0]
    assert delta == 378.34


# --- Synthetic tests for edge cases and format robustness -----------------

def test_all_strings_healthy_gives_normal_severity():
    header = ["Start Time", "Active power(kW)", "Inverter status", "Internal temperature(°C)",
              "PV1 input current(A)", "PV2 input current(A)", "Total yield(kWh)"]
    rows = [
        ["2026-09-05 08:00:00", "10.0", "Grid connected", "45.0", "10.0", "10.2", "100.0"],
        ["2026-09-05 08:05:00", "10.5", "Grid connected", "45.2", "10.1", "10.1", "100.9"],
        ["2026-09-05 08:10:00", "11.0", "Grid connected", "45.5", "10.2", "10.3", "101.8"],
        ["2026-09-05 08:15:00", "11.2", "Grid connected", "45.6", "10.3", "10.2", "102.7"],
    ]
    result = read_inverter_timeseries_csv(_build_csv(header, rows), "healthy.csv")
    assert result["severity"] == "NORMAL"
    assert "หมายเหตุ" not in result["observed_data"]


def test_different_column_order_and_wording_still_parses():
    """Different logger export: columns in a different order, different
    header capitalization — nothing here should assume a fixed layout."""
    header = ["Inverter Status", "PV1 Input Current(A)", "Start Time", "active power(kw)", "total yield(kwh)"]
    rows = [
        ["Grid connected", "15.0", "2026-09-05 09:00:00", "5.0", "50.0"],
        ["Grid connected", "15.2", "2026-09-05 09:05:00", "5.1", "50.5"],
        ["Grid connected", "15.1", "2026-09-05 09:10:00", "5.2", "51.0"],
        ["Grid connected", "15.3", "2026-09-05 09:15:00", "5.3", "51.5"],
    ]
    result = read_inverter_timeseries_csv(_build_csv(header, rows), "different_layout.csv")
    assert result["severity"] == "NORMAL"
    assert any(m["parameter"] == "daily_energy_kwh_delta" for m in result["key_measurements"])


def test_yield_counter_reset_does_not_report_fabricated_negative():
    header = ["Start Time", "Total yield(kWh)"]
    rows = [
        ["2026-09-05 08:00:00", "500.0"],
        ["2026-09-05 08:05:00", "0.5"],  # counter reset mid-window
    ]
    result = read_inverter_timeseries_csv(_build_csv(header, rows), "reset.csv")
    assert not any(m["parameter"] == "daily_energy_kwh_delta" for m in result["key_measurements"])


def test_unrecognizable_file_raises_value_error():
    garbage = b"this,is,not,an,inverter,log\n1,2,3,4,5,6"
    try:
        read_inverter_timeseries_csv(garbage, "garbage.csv")
        assert False, "should have raised"
    except ValueError:
        pass


def test_three_of_eleven_strings_weak_is_warning_not_critical():
    # 3/11 = 27% < 30% threshold -> WARNING, not CRITICAL
    header = ["Start Time"] + [f"PV{i} input current(A)" for i in range(1, 12)]
    healthy = ["20.0"] * 8
    weak = ["0.0"] * 3
    row = ["2026-09-05 09:00:00"] + healthy + weak
    row2 = ["2026-09-05 09:05:00"] + healthy + weak
    result = read_inverter_timeseries_csv(_build_csv(header, [row, row2]), "partial.csv")
    assert result["severity"] == "WARNING"

