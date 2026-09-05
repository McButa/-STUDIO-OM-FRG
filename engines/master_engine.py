import json
from datetime import date

from core.vision_client import execute_gemini_vision, optimize_image

# --- Stage 1: Extraction --------------------------------------------------
# This model's ONLY job is to describe what's visible in the evidence. It
# does not decide severity, and it must not use judgment words ("ปกติ",
# "ผิดปกติ", "urgent") — that judgment is computed afterward by deterministic
# engineering rules (core/threshold_rules.py), not guessed by the model in
# the same breath as it's still perceiving the evidence. This is the fix for
# the root cause behind nearly every bug found in this system so far: one
# single LLM call used to do perception AND judgment AND narrative writing
# together, so the same 0.836 MOhm reading could come out NORMAL one run and
# WARNING the next, entirely depending on how the model felt like phrasing
# things that pass — not on the number itself.
EXTRACTION_PROMPT = """
You are the STUDIO OM Solar O&M Evidence Extraction Engine.
Your ONLY job is to describe what is visible in the evidence. You do NOT judge whether anything is normal,
abnormal, safe, or unsafe, and you do NOT decide severity — severity is computed separately by deterministic
engineering rules, not by you. Do not use judgment words like "ปกติ", "ผิดปกติ", "urgent", "normal", "abnormal"
in observed_data — describe the reading itself, not your opinion of it.
Analyze only the current uploaded evidence and field notes. Historical/reference material is context, never
current evidence.
DO NOT invent numbers or default to template examples. Extract only visible numbers, labels, and text.
If a value is not visible or unproven, use null or "UNCONFIRMED".

ONE ROW PER UPLOADED FILE — MANDATORY:
Create exactly one evidence_findings entry per uploaded file. NEVER merge several separately-uploaded files
(e.g. Inv_2.jpg, Inv_3.jpg, Inv_4.jpg as distinct uploads) into a single row, even when they show the same
equipment type or a similar reading — a healthy unit's data must never be absorbed into a degraded neighbor's
row, or vice versa. If ONE uploaded file itself documents multiple pieces of equipment (e.g. a single photo of
a paper test log covering "DC_Inv_1-2.jpg" or "AC_Inv_1-6.jpg"), that is still only one uploaded file, so it
still gets exactly one row — describe everything visible in that one file's observed_data.
Every uploaded file must be referenced by exactly one finding's source_file. Do not skip any file.

STRUCTURED MEASUREMENTS (in addition to, never instead of, the observed_data narrative):
For every finding, also record every numeric reading you can see as a separate entry in "key_measurements".
Use these exact parameter names whenever the reading matches one of them (use others only when none of these fit):
active_power_kw, insulation_resistance_mohm, continuity_resistance_ohm, grid_frequency_hz, power_factor,
internal_temp_c, daily_energy_kwh, total_yield_kwh, grid_voltage_v, string_current_a, grid_current_a.
Give "value" as a bare number only (no unit text, no > or < symbol in the number itself).
If the source reads as an inequality (e.g. "Riso +/G >1000 MOhm" or "<0.5 Ohm"), set "comparator" to ">" or "<"
accordingly and "value" to that bound — do not silently turn ">1000" into an exact reading of 1000.
Use "comparator": "=" for a directly read value. Never leave key_measurements empty when a number is visible
in the evidence, even if that same number is also described in the observed_data text.

If any LCD, meter screen, or thermal scale is blurry, dark, or cropped, state in observed_data:
"ภาพไม่ชัดเจน/ไม่สามารถอ่านค่าเชิงตัวเลขได้ แนะนำให้บันทึกภาพซ้ำหน้างาน".
FIELD_NOTES.txt is optional; analyze visual and meter evidence when notes are absent.

Return JSON only using exactly this schema:
{
  "plant_summary": {
    "plant_name": "string",
    "rated_capacity_kw": "string",
    "audit_date": "string",
    "active_power_kw": "string",
    "grid_current_a": "string"
  },
  "evidence_findings": [
    {
      "category": "Inverter & Monitoring|Field Alarms|String Electrical|Thermography|Visual Survey",
      "source_file": "string",
      "observed_data": "string",
      "key_measurements": [
        {"parameter": "string (see fixed vocabulary above)", "value": 0, "unit": "string", "comparator": "=|>|<"}
      ]
    }
  ]
}
"""

# --- Stage 3: Narrative writing -------------------------------------------
# By the time this runs, core/threshold_rules.py has already decided every
# finding's final severity deterministically, and router.py has computed
# plant_summary.overall_status from those findings (never the other way
# around). This model only explains and acts on numbers it is FORBIDDEN
# from changing — it never re-sees the images, only the finalized JSON, so
# there's no way for it to quietly re-litigate a severity a second time.
NARRATIVE_PROMPT = """
You are the STUDIO OM Report Narrative Writer. You do NOT re-analyze evidence, and you must NEVER change any
severity, value, observed_data, or key_measurements given to you below — those were already decided by
deterministic engineering rules and are final. Your only job is to write the narrative sections that explain
and act on the ALREADY-DECIDED findings given to you.

Every finding with severity WARNING or CRITICAL must be referenced by name (source_file) in root_causes.
If every finding is NORMAL, set corrective_actions, spare_parts_tools, and inaction_damage_matrix to one entry
stating: "ระบบทำงานสมบูรณ์ตามเกณฑ์มาตรฐาน ไม่พบความผิดปกติที่ต้องซ่อมแซมเร่งด่วน".

CRITICAL INACTION DAMAGE ANALYSIS:
For each WARNING or CRITICAL finding, analyze the consequential equipment damage that WILL OCCUR if neglected
(e.g. Ground fault -> Inverter MPPT power board fire/short-circuit costing 80,000-150,000 THB vs 500-1,500 THB
MC4 repair; Hotspot -> Cell delamination/shattered glass costing 4,500-9,000 THB module replacement vs 0-500 THB
cleaning). Output damage and prevention costs as RAW NUMBERS ONLY (no commas, no currency symbols, no text) in
min_damage_cost_thb, max_damage_cost_thb, min_prevention_cost_thb, max_prevention_cost_thb.
DO NOT invent numbers for anything else. If a cause is not proven by the given findings, use "UNCONFIRMED".

Return JSON only using exactly this schema:
{
  "executive_summary": "string",
  "inaction_damage_matrix": [
    {
      "identified_fault": "string",
      "component_at_risk": "string",
      "escalation_mechanism": "string",
      "min_damage_cost_thb": 0,
      "max_damage_cost_thb": 0,
      "min_prevention_cost_thb": 0,
      "max_prevention_cost_thb": 0
    }
  ],
  "root_causes": [
    {"issue": "string", "description": "string", "supporting_evidence": "string"}
  ],
  "corrective_actions": [
    {"step_number": 1, "title": "string", "actions": ["string"]}
  ],
  "spare_parts_tools": [
    {"item_name": "string", "recommended_qty": "string", "purpose": "string"}
  ]
}
"""

LANGUAGE_INSTRUCTIONS = {
    "th": "Write all narrative fields and analysis in professional engineering Thai. Keep standard technical terms (Inverter, String, Active Power, Megger Test, MC4, Hotspot) where appropriate.",
    "en": "Write all narrative fields and analysis in professional technical English. Keep equipment names and measurement units exactly as observed.",
}


def file_parts(uploaded_files):
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
                reader = PdfReader(file)
                pdf_text = "\n".join([page.extract_text() or "" for page in reader.pages[:10]])
                file.seek(0)
                parts.append({"text": f"REFERENCE DOCUMENT CONTENT ({name}):\n{pdf_text[:8000]}"})
            except Exception:
                file.seek(0)
                parts.append({"text": f"REFERENCE DOCUMENT: {name}"})
    return parts


_file_parts = file_parts  # kept for internal call sites within this module


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


def run_extraction(uploaded_files, api_key: str, site_context: str = "", knowledge_context: str = "", lang: str = "th", plant_name: str | None = None) -> dict:
    """Stage 1: perception only. Returns plant_summary (raw, unresolved
    numbers welcome) + evidence_findings (observed_data + key_measurements,
    NO severity field at all — that's added by core/threshold_rules.py in
    the deterministic stage that runs between this and run_narrative_writing)."""
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
        [{"text": f"{EXTRACTION_PROMPT}\n{context}"}, *_file_parts(uploaded_files)],
        api_key,
    )
    return _parse_json_response(result)


def run_narrative_writing(report: dict, api_key: str, lang: str = "th") -> dict:
    """Stage 3: prose only, text-in/text-out (no images re-sent — cheaper,
    and there's no path for the model to re-judge severity from a photo a
    second time). `report` must already have final severities (i.e. this
    runs AFTER core/threshold_rules.py). Returns a dict with just the
    narrative fields — caller merges them into the final report."""
    lang = lang if lang in LANGUAGE_INSTRUCTIONS else "th"
    payload = {
        "plant_summary": report.get("plant_summary", {}),
        "evidence_findings": report.get("evidence_findings", []),
    }
    context = (
        f"{LANGUAGE_INSTRUCTIONS[lang]}\n\n"
        "[FINALIZED ENGINEERING FINDINGS — READ ONLY, DO NOT MODIFY]\n"
        f"{json.dumps(payload, ensure_ascii=False)}"
    )
    result = execute_gemini_vision(
        [{"text": f"{NARRATIVE_PROMPT}\n{context}"}],
        api_key,
    )
    return _parse_json_response(result)

