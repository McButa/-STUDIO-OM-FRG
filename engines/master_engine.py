import json
import io
from datetime import date

from core.vision_client import execute_gemini_vision, optimize_image

MASTER_ENGINE_PROMPT = """
You are the STUDIO OM Solar O&M Engineering Synthesis Engine.
Analyze only the current uploaded evidence and field notes. Historical/reference material is context, never current evidence.
DO NOT invent numbers or default to template examples. Extract only visible numbers, labels, and text.
If a value, diagnosis, cause, or action is not visible or proven, use null or "UNCONFIRMED".
A root cause is proven only by explicit alarm text, measurement evidence, EL evidence, or insulation test evidence.
Keep observed_data separate from engineering_diagnosis. Cross-correlate independent evidence sources, but mark unsupported conclusions UNCONFIRMED.
If current evidence shows normal operation, 0 alarms, no hotspots, and normal measured currents, set overall_status strictly to NORMAL.
For a normal operation result, set corrective_actions and spare_parts_tools to one entry stating exactly: "ระบบทำงานสมบูรณ์ตามเกณฑ์มาตรฐาน ไม่พบความผิดปกติที่ต้องซ่อมแซมเร่งด่วน".
If any LCD, meter screen, or thermal scale is blurry, dark, or cropped, do not guess numbers. State exactly: "ภาพไม่ชัดเจน/ไม่สามารถอ่านค่าเชิงตัวเลขได้ แนะนำให้บันทึกภาพซ้ำหน้างาน".
FIELD_NOTES.txt is optional; analyze visual and meter evidence when notes are absent.
Return JSON only using exactly this schema:
{
  "plant_summary": {"plant_name": "string", "rated_capacity_kw": "string", "audit_date": "string",
    "overall_status": "CRITICAL|WARNING|NORMAL", "active_power_kw": "string", "grid_current_a": "string"},
  "executive_summary": "string",
  "evidence_findings": [{"category": "Inverter & Monitoring|Field Alarms|String Electrical|Thermography|Visual Survey",
    "source_file": "string", "observed_data": "string", "engineering_diagnosis": "string",
    "severity": "CRITICAL|WARNING|NORMAL|INFORMATIONAL"}],
  "root_causes": [{"issue": "string", "description": "string", "supporting_evidence": "string"}],
    "consequential_damage_risk_matrix": [{"risk_id": "string", "affected_asset": "string",
        "failure_mode": "string", "consequence": "string", "likelihood": "RARE|UNLIKELY|POSSIBLE|LIKELY|ALMOST_CERTAIN",
        "severity": "INSIGNIFICANT|MINOR|MODERATE|MAJOR|CATASTROPHIC", "risk_score": 1,
        "risk_level": "LOW|MEDIUM|HIGH|EXTREME", "financial_impact": "string", "downtime_impact": "string",
        "safety_impact": "string", "mitigation": "string", "evidence_basis": "string"}],
  "corrective_actions": [{"step_number": 1, "title": "string", "actions": ["string"]}],
  "spare_parts_tools": [{"item_name": "string", "recommended_qty": "string", "purpose": "string"}]
}
"""

LANGUAGE_INSTRUCTIONS = {
    "th": "Write all narrative fields in professional engineering Thai. Keep technical terms such as Inverter, String, Active Power, Megger Test, and Hotspot where clearer.",
    "en": "Write all narrative fields in professional technical English. Keep equipment names and measurement units exactly as observed.",
}


def _file_parts(uploaded_files):
    parts = []
    for file in uploaded_files:
        name = str(getattr(file, "name", "unknown"))
        lower = name.lower()
        if lower.endswith(".txt"):
            content = file.read().decode("utf-8", errors="ignore")
            file.seek(0)
            parts.append({"text": f"FIELD NOTES {name}:\n{content[:8000]}"})
        elif lower.endswith((".png", ".jpg", ".jpeg", ".webp")):
            encoded = optimize_image(file.read(), max_dim=2400)
            file.seek(0)
            parts.append({"text": f"CURRENT EVIDENCE IMAGE: {name}"})
            parts.append({"inline_data": {"mime_type": "image/png", "data": encoded}})
        elif lower.endswith(".pdf"):
            try:
                from pypdf import PdfReader
                file.seek(0)
                reader = PdfReader(io.BytesIO(file.read()))
                file.seek(0)
                text = "\n".join((page.extract_text() or "") for page in reader.pages).strip()
                parts.append({"text": f"REFERENCE DOCUMENT (not current evidence) {name}:\n{text[:12000]}"})
            except Exception:
                file.seek(0)
                parts.append({"text": f"REFERENCE DOCUMENT (not current evidence; text unavailable): {name}"})
    return parts


def _parse_json_response(value):
    if isinstance(value, dict):
        return value
    if not isinstance(value, str):
        raise RuntimeError("Master engine returned an invalid JSON response")
    text = value.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[1] if "\n" in text else text
        text = text.rsplit("```", 1)[0].strip()
    try:
        parsed = json.loads(text)
    except json.JSONDecodeError as error:
        raise RuntimeError("Master engine returned malformed JSON") from error
    if not isinstance(parsed, dict):
        raise RuntimeError("Master engine JSON response must be an object")
    return parsed


def run_master_analysis(uploaded_files, api_key: str, site_context: str = "", knowledge_context: str = "", lang: str = "th", plant_name: str | None = None) -> dict:
    lang = lang if lang in LANGUAGE_INSTRUCTIONS else "th"
    context = (
        "CURRENT EVIDENCE ONLY.\n"
        f"{LANGUAGE_INSTRUCTIONS[lang]}\n"
        f"User-supplied plant name (metadata only): {plant_name or 'UNCONFIRMED'}\n"
        f"Historical site context (not evidence): {site_context}\n"
        f"Reference context (not evidence): {knowledge_context}\n"
        f"Audit date: {date.today().isoformat()}"
    )
    result = execute_gemini_vision(
        [{"text": f"{MASTER_ENGINE_PROMPT}\n{context}"}, *_file_parts(uploaded_files)],
        api_key,
    )
    return _parse_json_response(result)
