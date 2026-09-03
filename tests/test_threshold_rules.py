import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.threshold_rules import apply_measurement_thresholds, derive_plant_totals, detect_cross_source_conflicts
from router import _enforce_engineering_rules


def _finding(category, source_file, observed_data, severity="NORMAL", diagnosis=""):
    return {
        "category": category,
        "source_file": source_file,
        "observed_data": observed_data,
        "engineering_diagnosis": diagnosis,
        "severity": severity,
    }


def _report(findings, overall_status="NORMAL"):
    return {
        "plant_summary": {"overall_status": overall_status},
        "evidence_findings": findings,
    }


# --- The exact bug this file exists to prevent --------------------------

def test_low_riso_reading_is_never_left_as_normal_regardless_of_llm_output():
    """Golden case from Global House Phitsanulok: Inverter 2 monitoring screen
    reads Insulation resistance 0.836 MOhm. One real run of the LLM called
    this NORMAL, another called it WARNING, for the identical number. After
    this rule, it must always come out WARNING no matter what the LLM said."""
    report = _report([
        _finding(
            "Inverter & Monitoring", "Inv_2.jpg",
            "Inverter status: Grid connected, Active power: 3.867 kW, Insulation resistance: 0.836 MOhm",
            severity="NORMAL",  # this is what one real run produced — must be overridden
        ),
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "WARNING"
    assert report["plant_summary"]["overall_status"] == "WARNING"
    assert locked is False  # WARNING doesn't need to skip the verification pass, only CRITICAL does


def test_very_low_riso_escalates_to_critical_and_locks_status():
    report = _report([
        _finding(
            "Inverter & Monitoring", "Inv_9.jpg",
            "Insulation resistance: 0.2 MOhm", severity="NORMAL",
        ),
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "CRITICAL"
    assert report["plant_summary"]["overall_status"] == "CRITICAL"
    assert locked is True


def test_rule_never_downgrades_an_llm_severity_that_was_already_worse():
    report = _report([
        _finding(
            "Inverter & Monitoring", "Inv_2.jpg",
            "Insulation resistance: 0.836 MOhm", severity="CRITICAL",
        ),
    ], overall_status="CRITICAL")
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "CRITICAL"


def test_healthy_reading_is_left_alone():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "Insulation resistance: 20.000 MOhm"),
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "NORMAL"
    assert report["plant_summary"]["overall_status"] == "NORMAL"
    assert locked is False


def test_string_electrical_category_is_not_scanned_by_the_live_monitoring_rule():
    # Paper Megger readings live under a different category and a different
    # safety story (isolated test) — this rule must not fire on them.
    report = _report([
        _finding("String Electrical", "DC_Inv_1-2.jpg", "Riso +/G >1000 MOhm"),
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "NORMAL"


# --- Cross-source conflict (paper Megger vs live monitoring) ------------

def test_conflicting_paper_and_monitor_readings_are_flagged():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "Insulation resistance: 0.836 MOhm"),
        _finding("String Electrical", "DC_Inv_1-2.jpg", "Riso +/G >1000 MOhm"),
    ])
    report = detect_cross_source_conflicts(report)
    conflict_rows = [f for f in report["evidence_findings"] if "cross_source_conflict" in f.get("engineering_diagnosis", "")]
    assert len(conflict_rows) == 1
    assert "Inverter 2" in conflict_rows[0]["observed_data"]
    assert report["plant_summary"]["overall_status"] == "WARNING"


def test_no_conflict_flagged_when_both_sources_agree():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "Insulation resistance: 20.000 MOhm"),
        _finding("String Electrical", "DC_Inv_1-2.jpg", "Riso +/G >1000 MOhm"),
    ])
    report = detect_cross_source_conflicts(report)
    assert len(report["evidence_findings"]) == 2  # nothing appended


def test_thai_label_ka_chanuan_is_also_caught_not_just_english_wording():
    """The real 2026-09-03 report writer output '...ค่าฉนวน 0.836 MOhm' — Thai
    for insulation value — instead of the English phrase. An English-only
    regex would have silently missed this and shipped the exact same bug
    again under a different label."""
    report = _report([
        _finding(
            "Inverter & Monitoring", "Inv_2.jpg",
            "Active power 3.867 kW, ค่าฉนวน 0.836 MOhm",
            severity="NORMAL", diagnosis="ค่าฉนวนอยู่ในเกณฑ์ยอมรับได้",
        ),
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "WARNING"


# --- Deterministic recovery of plant-level totals ------------------------

def test_unconfirmed_active_power_is_summed_from_per_inverter_readings():
    """Live run on 2026-09-03: the top summary line showed 'กำลังผลิตจริง:
    UNCONFIRMED' even though every single Inverter & Monitoring finding had a
    real Active power reading (3.867, 3.925, 4.165 kW, ...). Summing is not
    an LLM judgment call — do it in Python whenever the per-item numbers are
    actually present in evidence_findings."""
    report = {
        "plant_summary": {"overall_status": "WARNING", "active_power_kw": "UNCONFIRMED"},
        "evidence_findings": [
            _finding("Inverter & Monitoring", "Inv_1.jpg", "Active power: 1.067 kW"),
            _finding("Inverter & Monitoring", "Inv_2.jpg", "Active power: 3.867 kW"),
            _finding("Inverter & Monitoring", "Inv_3.jpg", "Active power: 3.925 kW"),
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "8.859"


def test_partial_per_inverter_data_is_not_summed_to_avoid_understating_output():
    # Only 2 of 3 inverter findings have a parseable reading — summing just
    # those two would silently under-report total output, so leave it alone.
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": None},
        "evidence_findings": [
            _finding("Inverter & Monitoring", "Inv_1.jpg", "Active power: 1.067 kW"),
            _finding("Inverter & Monitoring", "Inv_2.jpg", "Active power: 3.867 kW"),
            _finding("Inverter & Monitoring", "Inv_3.jpg", "Inverter offline, no reading"),
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] is None


def test_existing_active_power_value_is_never_overwritten():
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "18.2"},
        "evidence_findings": [
            _finding("Inverter & Monitoring", "Inv_1.jpg", "Active power: 999 kW"),
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "18.2"


# --- Coverage for router's existing hard-coded rules (previously untested) --

def test_zero_grid_current_locks_critical():
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "0.1", "rated_capacity_kw": "500", "grid_current_a": "0"},
        "evidence_findings": [],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] == "CRITICAL"
    assert locked is True


def test_ground_fault_keyword_locks_critical():
    report = {
        "plant_summary": {"overall_status": "NORMAL"},
        "evidence_findings": [{"observed_data": "Alarm: Ground Fault detected", "engineering_diagnosis": ""}],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] == "CRITICAL"
    assert locked is True


def test_normal_with_zero_alarms_keeps_normal():
    report = {
        "plant_summary": {"overall_status": "NORMAL"},
        "evidence_findings": [{"observed_data": "0 alarm active", "engineering_diagnosis": ""}],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] == "NORMAL"
    assert locked is False


def test_negated_ground_fault_mention_does_not_lock_critical():
    """GBN - Phitsanulok report: every finding says NORMAL and the text reads
    'ไม่พบภาวะกราวด์ฟอลต์ (Ground Fault)' — Thai for 'no ground fault found' —
    but a naive substring search for 'ground fault' still matched and forced
    the whole report to CRITICAL despite every finding being NORMAL."""
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "18.201", "rated_capacity_kw": "680", "grid_current_a": "26.969"},
        "evidence_findings": [{
            "observed_data": "วงจร DC สตริงทั้งหมดเชื่อมต่อทางไฟฟ้าอย่างสมบูรณ์",
            "engineering_diagnosis": "ขั้วต่อและสายโซลาร์เคเบิลมีสภาพความเป็นฉนวนสมบูรณ์ ไม่พบภาวะกราวด์ฟอลต์ (Ground Fault) หรือสายขาดวงจร",
        }],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] != "CRITICAL"
    assert locked is False


def test_real_unnegated_ground_fault_still_locks_critical():
    """Make sure fixing the false positive above didn't break the real case —
    an actual, unnegated ground fault mention must still lock CRITICAL."""
    report = {
        "plant_summary": {"overall_status": "NORMAL"},
        "evidence_findings": [{"observed_data": "Alarm log shows an active ground fault on string 4", "engineering_diagnosis": ""}],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] == "CRITICAL"
    assert locked is True
