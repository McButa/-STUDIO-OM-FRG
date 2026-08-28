import hashlib
import uuid
from datetime import datetime, timezone

from core.docx_generator import build_docx
from core.evidence_validator import validate_report
from core.job_manifest import build_manifest, manifest_summary
from core.reference_reader import extract_reference_context
from database.db_manager import get_plant_history_context, get_similar_cases_context
from engines.master_engine import run_master_analysis

PROMPT_VERSION = "2026-08-28-master-v2"
REPORT_SCHEMA_VERSION = "2.1"


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


def _enforce_engineering_rules(report: dict) -> dict:
    summary = report.get("plant_summary", {})
    try:
        p_act = float(str(summary.get("active_power_kw", "0")).replace("kW", "").strip() or 0)
        p_rated = float(str(summary.get("rated_capacity_kw", "0")).replace("kW", "").strip() or 0)
        i_grid = float(str(summary.get("grid_current_a", "0")).replace("A", "").strip() or 0)
    except (ValueError, TypeError):
        p_act, p_rated, i_grid = 0.0, 0.0, 0.0

    findings_text = " ".join([
        f"{f.get('observed_data', '')} {f.get('engineering_diagnosis', '')}"
        for f in report.get("evidence_findings", []) if isinstance(f, dict)
    ]).lower()

    # Rule 1: Zero Grid Current or severe power drop (<5%) -> Lock to CRITICAL
    if (p_rated > 0 and (p_act / p_rated) < 0.05 and i_grid == 0) or "grid a/b/c phase current: 0" in findings_text or "grid current: 0" in findings_text or "grid current เป็น 0" in findings_text:
        summary["overall_status"] = "CRITICAL"
    # Rule 2: Active Ground Fault / Short Circuit / Major Alarms -> Lock to CRITICAL
    elif any(k in findings_text for k in ["ground fault", "short circuit", "insulation fault", "major alarm", "ลัดวงจรลงดิน", "รั่วลงดิน"]):
        summary["overall_status"] = "CRITICAL"
    # Rule 3: Confirmed normal operation with 0 alarms
    elif summary.get("overall_status") == "NORMAL" and ("0 alarm" in findings_text or "ไม่มีความผิดปกติ" in findings_text):
        summary["overall_status"] = "NORMAL"

    report["plant_summary"] = summary
    return report


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
    report = run_master_analysis(uploaded_files, api_key, site_context, knowledge_context + reference_context, lang=lang, plant_name=context_plant or None)
    report = _enforce_engineering_rules(report)
    report = validate_report(report)
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