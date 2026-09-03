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

SEVERITY_RANK = {"NORMAL": 0, "INFORMATIONAL": 0, "WARNING": 1, "CRITICAL": 2}


def _higher(a: str, b: str) -> str:
    return a if SEVERITY_RANK.get(a, 0) >= SEVERITY_RANK.get(b, 0) else b


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


# --- Cross-source conflict detection ------------------------------------
# Not a single-number threshold, so it earns its own function rather than a
# MEASUREMENT_RULES entry — but it's still fully deterministic (no LLM call).

_INVERTER_RANGE = re.compile(r"inv[_-]?(\d+)\s*-\s*(\d+)", re.IGNORECASE)
_INVERTER_SINGLE = re.compile(r"inv[_-]?(\d+)(?!\s*-)", re.IGNORECASE)
_RISO_VALUE = re.compile(r"(>|<)?\s*([\d.]+)\s*(?:m\W?ohm|m\W?\u03a9)", re.IGNORECASE)
_RISO_NAMES = {"insulation_resistance_mohm"}


def _inverter_ids(source_file: str):
    range_match = _INVERTER_RANGE.search(source_file)
    if range_match:
        start, end = int(range_match.group(1)), int(range_match.group(2))
        return list(range(start, end + 1))
    single_match = _INVERTER_SINGLE.search(source_file)
    if single_match:
        return [int(single_match.group(1))]
    return []


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

    inverter_findings = [f for f in findings if isinstance(f, dict) and f.get("category") == "Inverter & Monitoring"]
    per_inverter_kw = [_active_power_reading(f) for f in inverter_findings]

    # Only fill in the total when every inverter reading is present — a
    # partial sum (e.g. 4 of 6 units) would silently understate output,
    # which is worse than honestly leaving it UNCONFIRMED.
    if per_inverter_kw and all(v is not None for v in per_inverter_kw):
        summary["active_power_kw"] = str(round(sum(per_inverter_kw), 3))
        report["plant_summary"] = summary

    return report

