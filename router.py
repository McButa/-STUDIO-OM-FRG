import hashlib
import uuid
from datetime import datetime, timezone

from core.docx_generator import build_docx
from core.evidence_validator import coerce_float, validate_evidence_coverage, validate_report
from core.job_manifest import build_manifest, manifest_summary
from core.reference_reader import extract_reference_context
from core.threshold_rules import apply_measurement_thresholds, apply_peer_comparison, derive_plant_totals, detect_cross_source_conflicts, reconcile_narrative_with_findings
from database.db_manager import get_plant_history_context, get_previous_audit_kpis, get_similar_cases_context
from engines.master_engine import run_master_analysis
from engines.verification_engine import run_critical_verification

PROMPT_VERSION = "2026-09-04-master-v5-coverage-retry"
REPORT_SCHEMA_VERSION = "2.1"
MAX_COVERAGE_RETRIES = 2


def run_master_analysis_with_coverage_check(generate_fn, expected_filenames: list):
    """generate_fn: no-arg callable returning a fresh report dict (a closure
    over the real run_master_analysis call in production). Kept injectable
    so this retry logic is unit-testable without hitting the real API.

    Retries up to MAX_COVERAGE_RETRIES times if the LLM merges several
    separately-uploaded files into one evidence_finding row, or silently
    drops one — both are ways real information gets lost (e.g. a healthy
    inverter's reading getting absorbed into a degraded neighbor's row).
    Raises rather than silently shipping a report that failed every retry —
    matches evidence_validator.validate_report's 'reject instead of
    inventing fallback' rule."""
    problems = []
    report = None
    for _ in range(MAX_COVERAGE_RETRIES):
        report = generate_fn()
        problems = validate_evidence_coverage(report.get("evidence_findings", []), expected_filenames)
        if not problems:
            return report
    raise ValueError(
        f"AI ไม่สามารถวิเคราะห์ครบทุกไฟล์แยกรายการได้แม้ลองใหม่ {MAX_COVERAGE_RETRIES} ครั้ง: "
        + "; ".join(problems)
    )


def _file_sha256(file) -> str:
    try:
        position = file.tell()
        file.seek(0)
        digest = hashlib.sha256(file.read()).hexdigest()
        file.seek(position)
        return digest
    except (AttributeError, OSError):
        return "unavailable"


def build_job_cache_key(uploaded_files, api_key: str = "", plant_name: str = "", lang: str = "th", *args, **kwargs) -> str:
    digest = hashlib.sha256(hashlib.sha256((api_key or "").encode()).digest())
    digest.update(PROMPT_VERSION.encode("ascii"))
    digest.update(f"{plant_name}|{lang}".encode("utf-8"))
    for file in uploaded_files:
        digest.update(str(getattr(file, "name", "")).encode())
        digest.update(_file_sha256(file).encode())
    return digest.hexdigest()


def _plant_name(manifest):
    sites = {item.get("site") for item in manifest if item.get("site")}
    return next(iter(sites), "Unknown Site") if len(sites) == 1 else "Unknown Site"


NEGATION_MARKERS = (
    "ไม่พบ", "ไม่มี", "ไม่เกิด", "ไม่ปรากฏ", "ปราศจาก",
    "no ", "not ", "without", "free of", "no evidence of",
)


def _keyword_present_unnegated(text: str, keyword: str, window: int = 30) -> bool:
    """True if `keyword` appears in `text` (case-insensitive) at least once
    WITHOUT a negation word in the `window` characters right before it.
    Guards against text like 'ไม่พบภาวะกราวด์ฟอลต์ (Ground Fault)' — literally
    'no ground fault found' — being read as a positive hit on 'ground fault'
    just because the phrase appears somewhere in the sentence."""
    text_lower = text.lower()
    keyword_lower = keyword.lower()
    start = 0
    while True:
        idx = text_lower.find(keyword_lower, start)
        if idx == -1:
            return False
        preceding = text_lower[max(0, idx - window):idx]
        if not any(neg in preceding for neg in NEGATION_MARKERS):
            return True
        start = idx + len(keyword_lower)


def _enforce_engineering_rules(report: dict) -> tuple:
    summary = report.get("plant_summary", {})
    p_act_raw = coerce_float(summary.get("active_power_kw"))
    p_rated_raw = coerce_float(summary.get("rated_capacity_kw"))
    i_grid_raw = coerce_float(summary.get("grid_current_a"))
    # `or 0.0` below is only for the arithmetic once we've already confirmed
    # (in the Rule 1 condition) that these aren't None — an UNCONFIRMED/
    # unparseable reading must never be silently read as a confirmed zero,
    # or "we don't know the output" gets treated as "output is zero" and
    # forces a false CRITICAL on an otherwise healthy plant.
    p_act = p_act_raw or 0.0
    p_rated = p_rated_raw or 0.0
    i_grid = i_grid_raw or 0.0

    findings_text = " ".join([
        f"{f.get('observed_data', '')} {f.get('engineering_diagnosis', '')}"
        for f in report.get("evidence_findings", []) if isinstance(f, dict)
    ]).lower()

    hard_locked = False
    # Rule 1: Zero Grid Current or severe power drop (<5%) -> Lock to CRITICAL
    values_confirmed = p_act_raw is not None and p_rated_raw is not None and i_grid_raw is not None
    if (values_confirmed and p_rated > 0 and (p_act / p_rated) < 0.05 and i_grid == 0) or "grid a/b/c phase current: 0" in findings_text or "grid current: 0" in findings_text or "grid current เป็น 0" in findings_text:
        summary["overall_status"] = "CRITICAL"
        hard_locked = True
    # Rule 2: Active Ground Fault / Short Circuit / Major Alarms -> Lock to CRITICAL
    elif any(
        _keyword_present_unnegated(findings_text, k)
        for k in ["ground fault", "short circuit", "insulation fault", "major alarm", "ลัดวงจรลงดิน", "รั่วลงดิน"]
    ):
        summary["overall_status"] = "CRITICAL"
        hard_locked = True
    # Rule 3: Confirmed normal operation with 0 alarms
    elif summary.get("overall_status") == "NORMAL" and ("0 alarm" in findings_text or "ไม่มีความผิดปกติ" in findings_text):
        summary["overall_status"] = "NORMAL"

    report["plant_summary"] = summary
    return report, hard_locked


def _compute_trend(report: dict, plant_name: str) -> dict | None:
    """เทียบตัวเลข KPI รอบนี้กับรอบก่อนหน้าด้วยโค้ดล้วนๆ ไม่ให้ LLM เดาแนวโน้มเอง"""
    previous = get_previous_audit_kpis(plant_name)
    if not previous:
        return None
    summary = report.get("plant_summary", {})
    curr_power = summary.get("active_power_kw_num")
    prev_power = coerce_float(previous.get("active_power_kw"))
    curr_current = summary.get("grid_current_a_num")
    prev_current = coerce_float(previous.get("grid_current_a"))

    def _pct_delta(curr, prev):
        if curr is None or prev is None or prev == 0:
            return None
        return round((curr - prev) / prev * 100, 1)

    power_delta = _pct_delta(curr_power, prev_power)
    current_delta = _pct_delta(curr_current, prev_current)
    if power_delta is None and current_delta is None:
        return None
    return {
        "previous_audit_date": previous.get("audit_date"),
        "previous_status": previous.get("status"),
        "active_power_delta_pct": power_delta,
        "grid_current_delta_pct": current_delta,
    }


def process_field_report(uploaded_files, api_key: str, plant_name: str = "", lang: str = "th") -> tuple:
    requested_plant = plant_name.strip()
    manifest = build_manifest(uploaded_files)
    for index, item in enumerate(manifest):
        item["sha256"] = _file_sha256(uploaded_files[index])
    detected_plant = _plant_name(manifest)
    context_plant = requested_plant if len(requested_plant) > 2 else detected_plant
    report_type = "MIXED_REPORT" if len({item["evidence_type"] for item in manifest}) > 1 else "MASTER_REPORT"
    site_context = get_plant_history_context(context_plant, report_type)
    reference_context, references = extract_reference_context(uploaded_files)
    knowledge_context = get_similar_cases_context([context_plant], report_type, context_plant)
    expected_filenames = [item["filename"] for item in manifest]
    report = run_master_analysis_with_coverage_check(
        lambda: run_master_analysis(uploaded_files, api_key, site_context, knowledge_context + reference_context, lang=lang, plant_name=context_plant or None),
        expected_filenames,
    )
    report = derive_plant_totals(report)
    report, status_hard_locked = _enforce_engineering_rules(report)
    report, measurement_locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    report = detect_cross_source_conflicts(report)
    report = reconcile_narrative_with_findings(report)
    status_hard_locked = status_hard_locked or measurement_locked
    report = validate_report(report)
    if report.get("plant_summary", {}).get("overall_status") == "CRITICAL" and not status_hard_locked:
        report = run_critical_verification(uploaded_files, report, api_key)
    trend = _compute_trend(report, context_plant)
    if trend:
        report["trend_analysis"] = trend
    report["input_files"] = [str(getattr(file, "name", "unknown")) for file in uploaded_files]
    report["evidence_manifest"] = manifest
    report["reference_documents"] = references
    report["analysis_metadata"] = {
        "audit_id": str(uuid.uuid4()),
        "schema_version": REPORT_SCHEMA_VERSION,
        "prompt_version": PROMPT_VERSION,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "evidence_count": len(manifest),
        "evidence_summary": manifest_summary(manifest),
    }
    if len(requested_plant) > 2:
        selected_plant = requested_plant
    else:
        selected_plant = report.get("plant_summary", {}).get("plant_name") or detected_plant or "Unknown Site"
    report["plant_summary"]["plant_name"] = selected_plant
    report["language"] = lang if lang in {"th", "en"} else "th"
    document = build_docx(report, uploaded_files)
    return report, document, report_type, site_context
