"""
Deterministic measurement-threshold rules.

Why this file exists: severity used to be decided entirely by the LLM inside
one JSON call (engines/master_engine.py). Two runs on the exact same
Insulation Resistance reading (0.836 MOhm) came back NORMAL once and WARNING
once, because nothing in code ever checked the number itself. This module
fixes that class of bug for measured, numeric values.

Two sources of truth, in priority order:
  1. `key_measurements` — a structured list the prompt now requires on every
     evidence_finding (parameter/value/unit/comparator). This is the reliable
     path: a fixed vocabulary of parameter names, not prose the model phrases
     differently every run.
  2. Regex against observed_data/engineering_diagnosis text — kept as a
     fallback ONLY, for evidence that predates key_measurements or a run
     where the model still forgot to populate it. Never trusted over
     structured data when both are present.

Design goal (token/maintenance cost): a NEW failure mode that is expressed as
"a named quantity crossed a known numeric line" should only require adding one
entry to MEASUREMENT_RULES below — no prompt edits, no router changes, no new
functions. Only genuinely new *kinds* of check (e.g. cross-source conflicts,
which aren't a single threshold) need new code, and that already lives here
too (see `detect_cross_source_conflicts`).

Severity is only ever UPGRADED by these rules, never downgraded — an LLM call
that already flagged something worse is left alone; a rule only steps in when
the LLM under-called a measured value that crosses a known safety line.

What this file deliberately does NOT derive, and why (engineering/physics,
not just missing code):
  - grid_current_a at plant level: individual inverters are not guaranteed to
    be on the same phase, feeder, or measurement point, so their reported
    currents do not simply add into one meaningful "grid current" figure
    without knowing the actual electrical topology. Guessing here would be
    fabricating a number that looks precise but isn't physically justified.
  - rated_capacity_kw: this is a static nameplate/design value from site
    metadata, not something visible in a field photo to re-derive. If it's
    UNCONFIRMED, the fix is ensuring the site metadata reaches the prompt,
    not inventing a number from evidence that was never going to contain it.
  Active power IS safe to sum: real power delivered by parallel sources onto
  a common connection point is additive by basic conservation of energy,
  regardless of phase relationships — that's why only active_power_kw gets
  an automatic total below.
"""

import re

from core.peer_comparison import compare_to_peers

SEVERITY_RANK = {"NORMAL": 0, "INFORMATIONAL": 0, "WARNING": 1, "CRITICAL": 2}


def _higher(a: str, b: str) -> str:
    return a if SEVERITY_RANK.get(a, 0) >= SEVERITY_RANK.get(b, 0) else b


# --- Shared: which single inverter (if any) does this piece of evidence
# represent? A live monitoring dashboard screenshot names exactly one unit
# ("Inv_2.jpg"). A batch test sheet covering several units at once names a
# range ("DC_Inv_1-2.jpg", "AC_Inv_1-6.jpg") — that's a different kind of
# evidence (one aggregate test result, not one unit's live reading), even
# when the LLM happens to file both under the same category. Functions that
# need "one specific unit's own reading" (peer comparison, summing
# per-inverter totals) must use `_single_inverter_id`, not just filter by
# category, or a batch test's number silently gets treated as if it came
# from a single live unit.
_INVERTER_RANGE = re.compile(r"inv[_-]?(\d+)\s*-\s*(\d+)", re.IGNORECASE)
_INVERTER_SINGLE = re.compile(r"inv[_-]?(\d+)(?!\s*-)", re.IGNORECASE)


def _inverter_ids(source_file: str):
    range_match = _INVERTER_RANGE.search(source_file)
    if range_match:
        start, end = int(range_match.group(1)), int(range_match.group(2))
        return list(range(start, end + 1))
    single_match = _INVERTER_SINGLE.search(source_file)
    if single_match:
        return [int(single_match.group(1))]
    return []


def _single_inverter_id(source_file: str):
    """Returns the inverter id only when the filename names exactly ONE
    unit; returns None for a batch/range file (or no id at all) — the
    caller should then treat this finding as not representing a single
    unit's own live reading."""
    ids = _inverter_ids(source_file)
    return ids[0] if len(ids) == 1 else None


def _structured_lookup(finding: dict, parameter_names: set):
    """Look up a numeric reading from the finding's structured
    key_measurements list. Returns (value, comparator) or (None, None)."""
    for measurement in finding.get("key_measurements") or []:
        if not isinstance(measurement, dict):
            continue
        name = str(measurement.get("parameter", "")).strip().lower()
        if name not in parameter_names:
            continue
        value = measurement.get("value")
        if value is None:
            continue
        try:
            return float(value), measurement.get("comparator", "=") or "="
        except (TypeError, ValueError):
            continue
    return None, None


# --- Table of deterministic rules --------------------------------------
# Each rule first looks for `structured_names` in key_measurements; if not
# found there, falls back to `label_pattern` + `value_pattern` against the
# finding's text. `applies_to_category` restricts which evidence_findings
# rows the rule scans, so a rule for a monitoring reading doesn't misfire on
# a paper Megger row using the same word.
MEASUREMENT_RULES = [
    {
        "name": "insulation_resistance_live",
        "applies_to_category": "Inverter & Monitoring",
        "structured_names": {"insulation_resistance_mohm"},
        "label_pattern": re.compile(
            r"insulation\s*resistance|ค่าฉนวน|ความต้านทานฉนวน|\briso\b",
            re.IGNORECASE,
        ),
        "value_pattern": re.compile(r"(>|<)?\s*([\d.]+)\s*(?:m\W?ohm|m\W?\u03a9|megaohm)", re.IGNORECASE),
        # (comparator, limit, severity) — value compared against limit.
        "thresholds": [("<", 0.5, "CRITICAL"), ("<", 1.0, "WARNING")],
        # For peer comparison: a smaller insulation-resistance reading is the
        # concerning direction.
        "bad_direction": "low",
    },
]


def _extract_value(text: str, value_pattern):
    match = value_pattern.search(text)
    if not match:
        return None, None
    sign, raw = match.group(1), match.group(2)
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None, None
    return value, sign


def _reading_for_rule(finding: dict, rule: dict):
    """Structured key_measurements first; text regex only as a fallback."""
    value, sign = _structured_lookup(finding, rule["structured_names"])
    if value is not None:
        return value, sign
    text = f"{finding.get('observed_data', '')} {finding.get('engineering_diagnosis', '')}"
    if not rule["label_pattern"].search(text):
        return None, None
    return _extract_value(text, rule["value_pattern"])


def _rule_severity(value: float, sign, thresholds):
    # A ">1000" reading is a lower bound (true value is at least this high);
    # a "<X" reading is an upper bound (true value could be far below X, so
    # evaluate conservatively against X itself). Either way, comparing the
    # captured number against the threshold table below is the correct,
    # physically-honest check for both cases.
    for comparator, limit, severity in thresholds:
        if comparator == "<" and value < limit:
            return severity
    return None


def apply_measurement_thresholds(report: dict) -> tuple:
    """Scan evidence_findings for known measured quantities and force severity
    to at least what the number itself requires. Mutates report in place.
    Returns (report, escalated_to_critical: bool) — escalated_to_critical tells
    the caller this CRITICAL came from a number crossing a known line, not an
    LLM judgment call, so it should be treated like the router's other
    hard-coded rules (ground truth, skip the verification pass)."""
    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report, False

    escalated_any = False
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        for rule in MEASUREMENT_RULES:
            if finding.get("category") != rule["applies_to_category"]:
                continue
            value, sign = _reading_for_rule(finding, rule)
            if value is None:
                continue
            rule_severity = _rule_severity(value, sign, rule["thresholds"])
            if not rule_severity:
                continue
            current = finding.get("severity", "NORMAL")
            new_severity = _higher(current, rule_severity)
            if new_severity != current:
                finding["severity"] = new_severity
                finding["corroboration"] = "threshold_only"  # refined by apply_peer_comparison, if it runs
                finding["engineering_diagnosis"] = (
                    finding.get("engineering_diagnosis", "").rstrip()
                    + f" [กฎอัตโนมัติ: {rule['name']} วัดได้ {value} MOhm ต่ำกว่าเกณฑ์ปลอดภัย บังคับ severity เป็น {new_severity}]"
                )
                escalated_any = True

    escalated_to_critical = False
    if escalated_any:
        summary = report.get("plant_summary", {})
        worst = "NORMAL"
        for finding in findings:
            if isinstance(finding, dict):
                worst = _higher(worst, finding.get("severity", "NORMAL"))
        new_status = _higher(summary.get("overall_status", "NORMAL"), worst)
        escalated_to_critical = new_status == "CRITICAL" and summary.get("overall_status") != "CRITICAL"
        summary["overall_status"] = new_status
        report["plant_summary"] = summary

    return report, escalated_to_critical


# --- Peer comparison: corroborate or honestly qualify threshold escalations --
# apply_measurement_thresholds tags a finding "threshold_only" when the raw
# number alone crossed a line borrowed from a general standard (e.g. IEC
# 62446-1 Megger limits) that may not actually be the right limit for THIS
# equipment's live self-monitoring reading (see core/peer_comparison.py
# docstring for the full reasoning). This function runs after it and either:
#   - corroborates the escalation with real evidence (this unit performs far
#     worse than its peers under identical conditions right now), or
#   - honestly downgrades the CERTAINTY of the wording (not the severity —
#     severity stays elevated, so a real problem is never silently dropped
#     back to NORMAL) when no peer or reference data backs up the number.

def apply_peer_comparison(report: dict) -> dict:
    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report

    for rule in MEASUREMENT_RULES:
        bad_direction = rule.get("bad_direction")
        if not bad_direction:
            continue

        category_findings = [
            f for f in findings
            if isinstance(f, dict) and f.get("category") == rule["applies_to_category"]
        ]
        readings = []
        for idx, finding in enumerate(category_findings):
            if _single_inverter_id(str(finding.get("source_file", ""))) is None:
                # Not a single unit's own reading (either a multi-unit batch
                # test file, or no inverter id in the filename at all) — not
                # a valid peer for comparing individual units against each
                # other.
                continue
            value, sign = _reading_for_rule(finding, rule)
            if value is None:
                continue
            if sign not in ("=", None):
                # An inequality reading (">500", "<0.5") is a compliance bound
                # from a different measurement method (e.g. a Megger-style
                # test), not a directly comparable live reading. Kept as a
                # second guard even with the single-unit-id filter above,
                # since a mislabeled single-id file could still carry one.
                continue
            readings.append({"id": idx, "value": value, "finding": finding})

        peer_results = compare_to_peers(
            [{"id": r["id"], "value": r["value"]} for r in readings],
            bad_direction=bad_direction,
        )
        outlier_ids = {r["id"] for r in peer_results if r["is_outlier"]}
        peer_result_by_id = {r["id"]: r for r in peer_results}

        for r in readings:
            finding = r["finding"]
            if finding.get("corroboration") != "threshold_only":
                continue  # not an escalation from this rule, leave untouched
            if r["id"] in outlier_ids:
                pr = peer_result_by_id[r["id"]]
                finding["corroboration"] = f"peer_deviation:{pr['deviation_pct']}pct_below_best_peer"
                finding["engineering_diagnosis"] = (
                    finding.get("engineering_diagnosis", "").rstrip()
                    + f" [ยืนยันเพิ่มเติม: เบี่ยงเบนจากเครื่องเพื่อนร่วมชุดตรวจที่ดีที่สุด ({pr['baseline']} MOhm) อยู่ {pr['deviation_pct']}% "
                    "ซึ่งสูงกว่าค่าความแปรปรวนปกติของเครื่องรุ่นเดียวกันภายใต้เงื่อนไขเดียวกันอย่างมีนัยสำคัญ]"
                )
            else:
                finding["corroboration"] = "threshold_only_unverified"
                finding["engineering_diagnosis"] = (
                    finding.get("engineering_diagnosis", "").rstrip()
                    + " [หมายเหตุ: ยังไม่มีข้อมูลอ้างอิงเฉพาะรุ่นอุปกรณ์นี้ และไม่พบการเบี่ยงเบนจากเครื่องเพื่อนร่วมชุดตรวจอย่างมีนัยสำคัญ "
                    "ผลประเมินนี้อิงเกณฑ์ทั่วไปเบื้องต้นเท่านั้น แนะนำให้ตรวจสอบหน้างานเพื่อยืนยันก่อนสรุปเป็นข้อบกพร่องที่ยืนยันแล้ว]"
                )

    return report



# Not a single-number threshold, so it earns its own function rather than a
# MEASUREMENT_RULES entry — but it's still fully deterministic (no LLM call).

_RISO_VALUE = re.compile(r"(>|<)?\s*([\d.]+)\s*(?:m\W?ohm|m\W?\u03a9)", re.IGNORECASE)
_RISO_NAMES = {"insulation_resistance_mohm"}


def _riso_reading(finding: dict):
    value, sign = _structured_lookup(finding, _RISO_NAMES)
    if value is not None:
        return value, sign
    text = f"{finding.get('observed_data', '')} {finding.get('engineering_diagnosis', '')}"
    return _extract_value(text, _RISO_VALUE)


def detect_cross_source_conflicts(report: dict) -> dict:
    """Flag when a paper/Megger insulation reading and a live monitoring
    insulation reading disagree for the same inverter, instead of silently
    trusting whichever source the model happened to weight more."""
    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report

    monitor_readings = {}   # inverter_id -> (value, sign, source_file)
    paper_readings = {}     # inverter_id -> (value, sign, source_file)

    for finding in findings:
        if not isinstance(finding, dict):
            continue
        source_file = str(finding.get("source_file", ""))
        value, sign = _riso_reading(finding)
        if value is None:
            continue
        ids = _inverter_ids(source_file)
        if not ids:
            continue
        bucket = monitor_readings if finding.get("category") == "Inverter & Monitoring" else (
            paper_readings if finding.get("category") == "String Electrical" else None
        )
        if bucket is None:
            continue
        for inv_id in ids:
            bucket[inv_id] = (value, sign, source_file)

    conflicts = []
    for inv_id, (m_value, m_sign, m_file) in monitor_readings.items():
        if inv_id not in paper_readings:
            continue
        p_value, p_sign, p_file = paper_readings[inv_id]
        monitor_low = m_sign != ">" and m_value < 1.0
        paper_high = p_sign == ">" or p_value >= 100.0
        if monitor_low and paper_high:
            conflicts.append({
                "category": "Inverter & Monitoring",
                "source_file": f"{m_file} vs {p_file}",
                "observed_data": (
                    f"Inverter {inv_id}: ค่าจากหน้าจอ Monitoring (real-time) = {m_value} MOhm "
                    f"แต่ค่าจากใบทดสอบ Megger (isolated) = {p_sign or ''}{p_value} MOhm"
                ),
                "engineering_diagnosis": (
                    "ค่าทั้งสองแหล่งขัดแย้งกันสำหรับอุปกรณ์เดียวกัน — การวัดแบบ isolated (ตัดวงจร) "
                    "กับค่าที่รายงานระหว่างทำงานจริงต่างกันมาก จำเป็นต้องตรวจสอบซ้ำหน้างานก่อนสรุปสาเหตุ "
                    "[กฎอัตโนมัติ: cross_source_conflict]"
                ),
                "severity": "WARNING",
                "key_measurements": [],
            })

    if conflicts:
        report["evidence_findings"] = findings + conflicts
        summary = report.get("plant_summary", {})
        summary["overall_status"] = _higher(summary.get("overall_status", "NORMAL"), "WARNING")
        report["plant_summary"] = summary

    return report


# --- Deterministic recovery for plant-level totals -----------------------
# The LLM sometimes writes real per-inverter numbers but answers
# "UNCONFIRMED" for the plant-level total anyway (it has to correctly sum 6+
# separate readings in the same pass as everything else). Summing is a
# Python problem, not an LLM judgment call — do it deterministically
# whenever every per-item number is actually present. Only active_power_kw
# is summed here — see the module docstring for why grid_current_a and
# rated_capacity_kw are deliberately never auto-derived.

_ACTIVE_POWER_TEXT = re.compile(r"active\s*power[:\s]*([\d.]+)\s*kw", re.IGNORECASE)
_ACTIVE_POWER_NAMES = {"active_power_kw"}
_UNRESOLVED_VALUES = {None, "", "unconfirmed", "n/a", "null"}


def _active_power_reading(finding: dict):
    value, _ = _structured_lookup(finding, _ACTIVE_POWER_NAMES)
    if value is not None:
        return value
    text = f"{finding.get('observed_data', '')} {finding.get('engineering_diagnosis', '')}"
    match = _ACTIVE_POWER_TEXT.search(text)
    return float(match.group(1)) if match else None


def derive_plant_totals(report: dict) -> dict:
    summary = report.get("plant_summary", {})
    current = summary.get("active_power_kw")
    current_str = str(current).strip().lower() if current is not None else ""
    if current_str not in _UNRESOLVED_VALUES:
        return report  # Gemini already gave a usable number — don't second-guess it

    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report

    inverter_findings = [
        f for f in findings
        if isinstance(f, dict) and f.get("category") == "Inverter & Monitoring"
        and _single_inverter_id(str(f.get("source_file", ""))) is not None
    ]
    per_inverter_kw = [_active_power_reading(f) for f in inverter_findings]

    # Only fill in the total when every inverter reading is present — a
    # partial sum (e.g. 4 of 6 units) would silently understate output,
    # which is worse than honestly leaving it UNCONFIRMED.
    if per_inverter_kw and all(v is not None for v in per_inverter_kw):
        summary["active_power_kw"] = str(round(sum(per_inverter_kw), 3))
        report["plant_summary"] = summary

    return report


# --- Narrative/data consistency guard -------------------------------------
# apply_measurement_thresholds, apply_peer_comparison, and
# detect_cross_source_conflicts only ever touch evidence_findings and
# plant_summary. But executive_summary, root_causes, and corrective_actions
# are written by the LLM in the SAME call as evidence_findings, based on
# ITS OWN (pre-escalation) judgment — if the LLM decided everything was
# NORMAL, those sections say so in full prose, and nothing above ever goes
# back to update them once a rule forces a finding to WARNING/CRITICAL
# afterward. The result: a report whose header says WARNING while the
# executive summary confidently says "no abnormality found," and whose root
# causes / corrective actions sections are empty or generic "all clear" —
# which is precisely the kind of internally-contradictory, untrustworthy
# report this whole effort exists to prevent.
#
# This function does NOT try to fabricate the missing engineering analysis
# itself (writing a plausible-sounding root cause/corrective action without
# being sure it's right would just be a different flavor of the same
# problem). It only guarantees the report can never claim "all clear" while
# escalated findings exist elsewhere in it — by adding an unmissable,
# factual pointer back to the findings that a human still needs to act on.

def reconcile_narrative_with_findings(report: dict) -> dict:
    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report

    escalated = [
        f for f in findings
        if isinstance(f, dict) and f.get("severity") in ("WARNING", "CRITICAL")
    ]
    if not escalated:
        return report

    escalated_files = ", ".join(sorted({str(f.get("source_file", "")) for f in escalated}))
    banner = (
        f"[หมายเหตุจากระบบตรวจสอบอัตโนมัติ: มี {len(escalated)} รายการที่ถูกยกระดับเป็น WARNING/CRITICAL "
        f"โดยกฎวิศวกรรมอัตโนมัติ ({escalated_files}) กรุณาอ่านหัวข้อผลการตรวจสอบ (ข้อ 3) โดยละเอียด "
        "ก่อนสรุปว่าระบบไม่มีความผิดปกติ — บทสรุปด้านล่างนี้อาจเขียนขึ้นก่อนการยกระดับดังกล่าว]\n\n"
    )
    summary_text = report.get("executive_summary", "") or ""
    if "หมายเหตุจากระบบตรวจสอบอัตโนมัติ" not in summary_text:
        report["executive_summary"] = banner + summary_text

    root_causes = report.get("root_causes", [])
    if not isinstance(root_causes, list):
        root_causes = []
    covered_files = {str(rc.get("supporting_evidence", "")) for rc in root_causes if isinstance(rc, dict)}
    for f in escalated:
        source_file = str(f.get("source_file", ""))
        if any(source_file in c for c in covered_files):
            continue
        root_causes.append({
            "issue": f"{f.get('category', '')} — {source_file} (severity: {f.get('severity')})",
            "description": (
                f.get("engineering_diagnosis", "")
                or "ยกระดับโดยกฎวิศวกรรมอัตโนมัติ ยังไม่มีคำอธิบายเชิงวิเคราะห์จาก AI ระบุไว้ในรอบนี้ "
                   "ต้องตรวจสอบข้อมูลในหัวข้อผลการตรวจสอบเพิ่มเติมก่อนสรุปสาเหตุ"
            ),
            "supporting_evidence": source_file,
        })
    report["root_causes"] = root_causes

    corrective_actions = report.get("corrective_actions", [])
    if not isinstance(corrective_actions, list):
        corrective_actions = []
    has_followup_action = any(
        isinstance(a, dict) and any(f.get("source_file", "") in " ".join(a.get("actions", [])) for f in escalated)
        for a in corrective_actions
    )
    if not has_followup_action:
        next_step_number = max([a.get("step_number", 0) for a in corrective_actions if isinstance(a, dict)], default=0) + 1
        corrective_actions.append({
            "step_number": next_step_number,
            "title": "ตรวจสอบซ้ำหน้างานสำหรับรายการที่ถูกยกระดับโดยระบบอัตโนมัติ",
            "actions": [
                f"ตรวจสอบซ้ำหน้างาน: {escalated_files}",
                "ยืนยันสาเหตุและความรุนแรงจริงก่อนวางแผนซ่อมบำรุงหรือปิดเคส",
            ],
        })
    report["corrective_actions"] = corrective_actions

    return report

