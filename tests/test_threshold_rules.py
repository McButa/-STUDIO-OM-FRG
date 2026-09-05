import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.threshold_rules import (
    apply_measurement_thresholds,
    apply_peer_comparison,
    derive_plant_totals,
    detect_cross_source_conflicts,
    fill_default_diagnosis,
    finalize_overall_status,
    initialize_finding_defaults,
    reconcile_narrative_with_findings,
)
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


# --- Structured key_measurements (primary path, added after the schema change) --

def test_structured_insulation_reading_is_used_even_with_no_matching_text():
    """The whole point of key_measurements: this must work even when the
    model's prose doesn't mention 'insulation resistance' or 'ค่าฉนวน' at
    all — exactly the run where the old text-only regex came up empty."""
    report = _report([
        {
            "category": "Inverter & Monitoring", "source_file": "Inv_2.jpg",
            "observed_data": "หน้าจอแสดงค่าปกติทั่วไป", "engineering_diagnosis": "",
            "severity": "NORMAL",
            "key_measurements": [{"parameter": "insulation_resistance_mohm", "value": 0.836, "unit": "MOhm", "comparator": "="}],
        },
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "WARNING"


def test_structured_reading_takes_priority_over_conflicting_text():
    # If both are present, the structured number wins — it's the field the
    # prompt now requires to be accurate, text is free-form and can drift.
    report = _report([
        {
            "category": "Inverter & Monitoring", "source_file": "Inv_2.jpg",
            "observed_data": "Insulation resistance: 20 MOhm (พิมพ์ผิดในข้อความ)",
            "engineering_diagnosis": "", "severity": "NORMAL",
            "key_measurements": [{"parameter": "insulation_resistance_mohm", "value": 0.3, "unit": "MOhm", "comparator": "="}],
        },
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "CRITICAL"


def test_comparator_greater_than_in_structured_data_is_not_flagged():
    # A Megger '>1000 MOhm' reading structured as value=1000, comparator='>'
    # must not be misread as an exact 1000 that somehow trips a < threshold.
    report = _report([
        {
            "category": "Inverter & Monitoring", "source_file": "Inv_1.jpg",
            "observed_data": "", "engineering_diagnosis": "", "severity": "NORMAL",
            "key_measurements": [{"parameter": "insulation_resistance_mohm", "value": 1000, "unit": "MOhm", "comparator": ">"}],
        },
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "NORMAL"


def test_active_power_summed_from_structured_data_across_all_inverters():
    report = {
        "plant_summary": {"overall_status": "WARNING", "active_power_kw": "UNCONFIRMED"},
        "evidence_findings": [
            {"category": "Inverter & Monitoring", "source_file": "Inv_1.jpg", "observed_data": "", "engineering_diagnosis": "", "severity": "NORMAL",
             "key_measurements": [{"parameter": "active_power_kw", "value": 1.067, "comparator": "="}]},
            {"category": "Inverter & Monitoring", "source_file": "Inv_2.jpg", "observed_data": "", "engineering_diagnosis": "", "severity": "WARNING",
             "key_measurements": [{"parameter": "active_power_kw", "value": 3.867, "comparator": "="}]},
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "4.934"


def test_structured_and_text_active_power_can_mix_across_findings():
    # One finding has structured data, another only has it in prose — the
    # fallback still lets the sum go through instead of giving up entirely.
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": None},
        "evidence_findings": [
            {"category": "Inverter & Monitoring", "source_file": "Inv_1.jpg", "observed_data": "", "engineering_diagnosis": "", "severity": "NORMAL",
             "key_measurements": [{"parameter": "active_power_kw", "value": 1.067, "comparator": "="}]},
            {"category": "Inverter & Monitoring", "source_file": "Inv_2.jpg", "observed_data": "Active power: 3.867 kW", "engineering_diagnosis": "", "severity": "NORMAL",
             "key_measurements": []},
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "4.934"


def test_grid_current_and_rated_capacity_are_never_touched_by_this_module():
    """Physics/engineering guardrail: this module must never invent a plant-
    level grid_current_a or rated_capacity_kw, even when it could technically
    sum something — per-inverter currents aren't safely additive without
    known circuit topology, and rated capacity isn't derivable from photos
    at all. Only active_power_kw gets an automatic total."""
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "UNCONFIRMED", "grid_current_a": "UNCONFIRMED", "rated_capacity_kw": "UNCONFIRMED"},
        "evidence_findings": [
            {"category": "Inverter & Monitoring", "source_file": "Inv_1.jpg", "observed_data": "", "engineering_diagnosis": "", "severity": "NORMAL",
             "key_measurements": [
                 {"parameter": "active_power_kw", "value": 1.067, "comparator": "="},
                 {"parameter": "grid_current_a", "value": 5.6, "comparator": "="},
             ]},
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "1.067"
    assert report["plant_summary"]["grid_current_a"] == "UNCONFIRMED"
    assert report["plant_summary"]["rated_capacity_kw"] == "UNCONFIRMED"


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


def test_batch_test_file_does_not_pollute_peer_baseline():
    """Real bug from a live report: 'AC_Inv_1-6.jpg' (an AC-side Megger test
    covering all 6 inverters at once, reading '>500 MOhm') got filed under
    'Inverter & Monitoring' — the same category as the 6 individual live
    dashboard screenshots. Comparing against it inflated the peer baseline
    to 500 MOhm (a compliance bound from a different measurement method)
    instead of 20 MOhm (the real best live reading, from Inv_1.jpg), which
    overstated Inv_2's deviation as 99.8% instead of the correct 95.8%."""
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "Insulation resistance 20.000 MOhm"),
        _finding("Inverter & Monitoring", "Inv_2.jpg", "Insulation resistance 0.836 MOhm"),
        _finding("Inverter & Monitoring", "Inv_3.jpg", "Insulation resistance 0.867 MOhm"),
        _finding("Inverter & Monitoring", "Inv_4.jpg", "Insulation resistance 0.921 MOhm"),
        _finding("Inverter & Monitoring", "AC_Inv_1-6.jpg", "ผลการวัดแสดงค่า >500 MOhm ทุกเฟส"),
    ])
    report, locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    inv2 = [f for f in report["evidence_findings"] if f["source_file"] == "Inv_2.jpg"][0]
    assert inv2["corroboration"] == "peer_deviation:95.8pct_below_best_peer"


def test_batch_test_file_does_not_block_active_power_sum():
    """Same root cause, different function: AC_Inv_1-6.jpg has no active-power
    reading at all, so requiring EVERY 'Inverter & Monitoring' finding to
    have one (including this batch file) meant the sum was abandoned even
    though all 6 real inverters had a valid reading."""
    report = {
        "plant_summary": {"active_power_kw": "UNCONFIRMED"},
        "evidence_findings": [
            _finding("Inverter & Monitoring", "Inv_1.jpg", "Active power 1.067 kW"),
            _finding("Inverter & Monitoring", "Inv_2.jpg", "Active power 3.867 kW"),
            _finding("Inverter & Monitoring", "AC_Inv_1-6.jpg", "ผลการวัดแสดงค่า >500 MOhm ทุกเฟส"),
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "4.934"


# --- Peer comparison integration (corroborate or honestly qualify) ------

def test_global_house_full_batch_gets_corroborated_by_peer_deviation():
    """Full 6-inverter batch: the WARNING escalation for Inv2-5 should come
    out CORROBORATED (peer_deviation), because Inv1/Inv6 prove 13-20 MOhm was
    achievable under the same conditions right now — this is no longer just
    'a number crossed a generic line', it's a verified anomaly."""
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "Insulation resistance: 20.000 MOhm"),
        _finding("Inverter & Monitoring", "Inv_2.jpg", "Insulation resistance: 0.836 MOhm"),
        _finding("Inverter & Monitoring", "Inv_3.jpg", "Insulation resistance: 0.867 MOhm"),
        _finding("Inverter & Monitoring", "Inv_4.jpg", "Insulation resistance: 0.921 MOhm"),
        _finding("Inverter & Monitoring", "Inv_5.jpg", "Insulation resistance: 0.872 MOhm"),
        _finding("Inverter & Monitoring", "Inv_6.jpg", "Insulation resistance: 13.541 MOhm"),
    ])
    report, locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    findings_by_file = {f["source_file"]: f for f in report["evidence_findings"]}
    for f in ["Inv_2.jpg", "Inv_3.jpg", "Inv_4.jpg", "Inv_5.jpg"]:
        assert findings_by_file[f]["severity"] == "WARNING"
        assert findings_by_file[f]["corroboration"].startswith("peer_deviation:")
    assert findings_by_file["Inv_1.jpg"]["severity"] == "NORMAL"
    assert findings_by_file["Inv_6.jpg"]["severity"] == "NORMAL"


def test_single_low_reading_with_no_peers_stays_warning_but_wording_is_honestly_qualified():
    """This is the exact concern the user raised: without knowing this
    inverter model's real normal range, and with no peers to compare against,
    the system must NOT confidently claim 'violates safety standard'. But it
    also must not silently drop back to NORMAL — that reintroduces the
    original disaster (a real risk called normal). Severity stays WARNING;
    only the certainty of the wording changes."""
    report = _report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "Insulation resistance: 0.836 MOhm"),
    ])
    report, locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    finding = report["evidence_findings"][0]
    assert finding["severity"] == "WARNING"  # never silently downgraded
    assert finding["corroboration"] == "threshold_only_unverified"
    assert "ยังไม่มีข้อมูลอ้างอิงเฉพาะรุ่น" in finding["engineering_diagnosis"]


def test_peer_comparison_leaves_non_escalated_findings_untouched():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "Insulation resistance: 20.000 MOhm"),
        _finding("Inverter & Monitoring", "Inv_2.jpg", "Insulation resistance: 19.500 MOhm"),
        _finding("Inverter & Monitoring", "Inv_3.jpg", "Insulation resistance: 18.900 MOhm"),
        _finding("Inverter & Monitoring", "Inv_4.jpg", "Insulation resistance: 20.100 MOhm"),
    ])
    report, locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    for f in report["evidence_findings"]:
        assert f["severity"] == "NORMAL"
        assert f.get("corroboration") is None


# --- Narrative/data consistency guard ------------------------------------

def _full_report(findings, executive_summary="ระบบทำงานสมบูรณ์ ไม่พบความผิดปกติ", root_causes=None, corrective_actions=None):
    return {
        "plant_summary": {"overall_status": "WARNING"},
        "executive_summary": executive_summary,
        "evidence_findings": findings,
        "root_causes": root_causes or [],
        "corrective_actions": corrective_actions or [],
    }


def test_narrative_untouched_when_nothing_escalated():
    report = _full_report([_finding("Inverter & Monitoring", "Inv_1.jpg", "ปกติ")])
    result = reconcile_narrative_with_findings(report)
    assert result["executive_summary"] == "ระบบทำงานสมบูรณ์ ไม่พบความผิดปกติ"
    assert result["root_causes"] == []
    assert result["corrective_actions"] == []


def test_stale_all_clear_summary_gets_banner_when_findings_are_escalated():
    """The real bug: header said WARNING, but executive_summary still read
    'ระบบทำงานสมบูรณ์...ไม่พบความผิดปกติ' because the LLM wrote that BEFORE
    threshold rules escalated Inv_2. The original text must not be deleted
    (still useful context) but a reader must not be able to miss the
    contradiction."""
    report = _full_report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "ต่ำกว่าเกณฑ์", severity="WARNING"),
    ])
    result = reconcile_narrative_with_findings(report)
    assert result["executive_summary"].startswith("[หมายเหตุจากระบบตรวจสอบอัตโนมัติ")
    assert "ระบบทำงานสมบูรณ์ ไม่พบความผิดปกติ" in result["executive_summary"]  # original kept, not deleted
    assert "Inv_2.jpg" in result["executive_summary"]


def test_empty_root_causes_gets_populated_from_escalated_findings():
    report = _full_report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "ต่ำกว่าเกณฑ์", severity="WARNING", diagnosis="ค่าฉนวนต่ำกว่าเกณฑ์ปลอดภัย"),
    ], root_causes=[])
    result = reconcile_narrative_with_findings(report)
    assert len(result["root_causes"]) == 1
    assert result["root_causes"][0]["supporting_evidence"] == "Inv_2.jpg"
    assert "ค่าฉนวนต่ำกว่าเกณฑ์ปลอดภัย" in result["root_causes"][0]["description"]


def test_existing_root_cause_covering_the_file_is_not_duplicated():
    report = _full_report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "ต่ำกว่าเกณฑ์", severity="WARNING"),
    ], root_causes=[{"issue": "Riso ต่ำ", "description": "...", "supporting_evidence": "Inv_2.jpg"}])
    result = reconcile_narrative_with_findings(report)
    assert len(result["root_causes"]) == 1  # not duplicated


def test_corrective_actions_gets_a_followup_step_when_missing():
    report = _full_report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "ต่ำกว่าเกณฑ์", severity="WARNING"),
    ], corrective_actions=[{"step_number": 1, "title": "PM ปกติ", "actions": ["บันทึกข้อมูล"]}])
    result = reconcile_narrative_with_findings(report)
    assert len(result["corrective_actions"]) == 2
    assert result["corrective_actions"][1]["step_number"] == 2
    assert "Inv_2.jpg" in result["corrective_actions"][1]["actions"][0]


def test_root_causes_schema_stays_valid_after_reconciliation():
    """Every field the RootCause/CorrectiveAction pydantic models require
    must actually be present, or validate_report (which runs right after
    this in router.py) would reject the whole report."""
    report = _full_report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "ต่ำกว่าเกณฑ์", severity="CRITICAL"),
    ])
    result = reconcile_narrative_with_findings(report)
    for rc in result["root_causes"]:
        assert set(rc.keys()) >= {"issue", "description", "supporting_evidence"}
    for ca in result["corrective_actions"]:
        assert set(ca.keys()) >= {"step_number", "title", "actions"}
        assert isinstance(ca["step_number"], int) and ca["step_number"] >= 1


# --- Pipeline-stage helpers (extraction/analysis/narrative split) -------

def test_initialize_finding_defaults_fills_missing_fields():
    report = {"evidence_findings": [{"category": "Inverter & Monitoring", "source_file": "Inv_1.jpg", "observed_data": "20 MOhm"}]}
    result = initialize_finding_defaults(report)
    f = result["evidence_findings"][0]
    assert f["severity"] == "NORMAL"
    assert f["engineering_diagnosis"] == ""
    assert f["key_measurements"] == []


def test_initialize_finding_defaults_never_overwrites_existing_values():
    report = {"evidence_findings": [{"severity": "CRITICAL", "engineering_diagnosis": "already set"}]}
    result = initialize_finding_defaults(report)
    assert result["evidence_findings"][0]["severity"] == "CRITICAL"
    assert result["evidence_findings"][0]["engineering_diagnosis"] == "already set"


def test_fill_default_diagnosis_only_touches_empty_ones():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "20 MOhm", diagnosis=""),
        _finding("Inverter & Monitoring", "Inv_2.jpg", "0.8 MOhm", diagnosis="already explained"),
    ])
    result = fill_default_diagnosis(report)
    assert "ไม่มีกฎตรวจสอบอัตโนมัติ" in result["evidence_findings"][0]["engineering_diagnosis"]
    assert result["evidence_findings"][1]["engineering_diagnosis"] == "already explained"


def test_finalize_overall_status_computed_purely_from_findings():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "", severity="NORMAL"),
        _finding("Inverter & Monitoring", "Inv_2.jpg", "", severity="WARNING"),
    ], overall_status="NORMAL")
    result = finalize_overall_status(report)
    assert result["plant_summary"]["overall_status"] == "WARNING"


def test_finalize_overall_status_cannot_exceed_worst_finding_without_a_hard_lock():
    """The bug this closes: a report header said CRITICAL while every single
    finding topped out at WARNING — because overall_status used to be a
    free-floating field the LLM could set independently of its own
    per-finding severities. Now there's no such field for the LLM to set at
    all (run_extraction produces no overall_status), so an ungrounded
    CRITICAL claim like that is structurally impossible: this function is
    the ONLY thing that ever sets plant_summary.overall_status from
    scratch, and it can only derive CRITICAL from an actual CRITICAL
    finding or a prior hard lock."""
    report = _report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "", severity="WARNING"),
        _finding("Inverter & Monitoring", "Inv_3.jpg", "", severity="WARNING"),
    ])  # plant_summary starts with no overall_status key at all, like real extraction output
    del report["plant_summary"]
    report["plant_summary"] = {}
    result = finalize_overall_status(report)
    assert result["plant_summary"]["overall_status"] == "WARNING"  # never CRITICAL — nothing justifies it


def test_finalize_overall_status_preserves_a_genuine_hard_lock():
    # _enforce_engineering_rules sets this directly on plant_summary BEFORE
    # finalize_overall_status runs, for plant-level facts (e.g. confirmed
    # zero grid current) that aren't any single photo's severity.
    report = _report([_finding("Inverter & Monitoring", "Inv_1.jpg", "", severity="NORMAL")], overall_status="CRITICAL")
    result = finalize_overall_status(report)
    assert result["plant_summary"]["overall_status"] == "CRITICAL"


# --- Coverage for router's existing hard-coded rules (previously untested) --

def test_zero_grid_current_locks_critical():
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "0.1", "rated_capacity_kw": "500", "grid_current_a": "0"},
        "evidence_findings": [],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] == "CRITICAL"
    assert locked is True


def test_unconfirmed_active_power_and_grid_current_does_not_falsely_lock_critical():
    """Found during end-to-end verification: coerce_float('UNCONFIRMED') is
    None, and 'None or 0.0' silently became 0.0 — so a plant where the LLM
    simply couldn't extract active_power_kw/grid_current_a (not because
    output is actually zero) was being hard-locked CRITICAL as if it had
    confirmed zero output. Not knowing the value must never be treated as
    knowing it's zero."""
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "UNCONFIRMED", "grid_current_a": "UNCONFIRMED", "rated_capacity_kw": "20"},
        "evidence_findings": [{"observed_data": "ปกติทุกจุด", "engineering_diagnosis": ""}],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] != "CRITICAL"
    assert locked is False


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

