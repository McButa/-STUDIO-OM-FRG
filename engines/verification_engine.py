import json

from core.vision_client import ENGINEERING_ANALYST_PROMPT, execute_gemini_vision_staged
from engines.master_engine import file_parts

VERIFICATION_WRITER_PROMPT = """
คุณกำลังตรวจสอบซ้ำ (Verification Pass) เฉพาะข้อสรุปที่ระบุว่าสถานะ CRITICAL เท่านั้น
ใช้เฉพาะข้อมูลจาก [VERIFIED ENGINEERING ANALYSIS] (ผลวิเคราะห์อิสระรอบใหม่) เทียบกับ [ข้อสรุปเดิมที่ต้องตรวจสอบ]
ห้ามเพิ่มข้อมูลใหม่ที่ไม่มีในหลักฐาน
ตอบ JSON เท่านั้นในรูปแบบ:
{
  "verification_status": "CONFIRMED หรือ UNCONFIRMED",
  "notes": "string อธิบายเหตุผลสั้นๆ เป็นภาษาไทย"
}
ให้ "CONFIRMED" เฉพาะเมื่อผลวิเคราะห์อิสระรอบใหม่พบหลักฐานชัดเจน (alarm text ตรงกัน, ค่าวัดที่อ่านได้จริง,
หรือ EL/insulation test) ยืนยันปัญหาระดับวิกฤตได้ตรงกับข้อสรุปเดิม
ถ้าผลวิเคราะห์อิสระรอบใหม่ระบุ root_cause_status เป็น Suspected หรือ Unknown สำหรับประเด็นเดียวกัน
หรือหลักฐานไม่สอดคล้องกัน ให้ตอบ "UNCONFIRMED"
"""


def run_critical_verification(uploaded_files, report: dict, api_key: str) -> dict:
    """Independent second-look at CRITICAL findings before they reach the final report.

    Only called when overall_status == CRITICAL and that status was NOT already locked by a
    deterministic rule (grid current 0A, ground fault keyword, etc. — those are ground truth
    and don't need re-checking). Re-runs the evidence through a fresh analyst pass and asks a
    writer pass to confirm or reject the original CRITICAL claim. On any failure, the original
    CRITICAL status is kept untouched — a verification pass must never silently downgrade
    safety-relevant findings just because the check itself broke.
    """
    critical_findings = [
        f for f in report.get("evidence_findings", [])
        if isinstance(f, dict) and f.get("severity") == "CRITICAL"
    ]
    if not critical_findings:
        return report

    critical_sources = {f.get("source_file") for f in critical_findings}
    relevant_files = [
        f for f in uploaded_files
        if str(getattr(f, "name", "")) in critical_sources or str(getattr(f, "name", "")).lower().endswith(".txt")
    ] or list(uploaded_files)
    for f in relevant_files:
        try:
            f.seek(0)
        except (AttributeError, OSError):
            pass

    claim_summary = json.dumps(
        {
            "critical_findings": [
                {
                    "category": f.get("category"),
                    "observed_data": f.get("observed_data"),
                    "engineering_diagnosis": f.get("engineering_diagnosis"),
                }
                for f in critical_findings
            ],
            "root_causes": report.get("root_causes", []),
        },
        ensure_ascii=False,
    )
    writer_prompt = f"{VERIFICATION_WRITER_PROMPT}\n\n[ข้อสรุปเดิมที่ต้องตรวจสอบ]\n{claim_summary}"

    try:
        evidence_parts = file_parts(relevant_files)
        result = execute_gemini_vision_staged(evidence_parts, ENGINEERING_ANALYST_PROMPT, writer_prompt, api_key)
    except Exception as error:
        report["verification_note"] = (
            f"Verification pass ไม่สามารถทำงานได้ ({error}) — คงสถานะ CRITICAL เดิมไว้เพื่อความปลอดภัย "
            "แนะนำให้วิศวกรตรวจสอบหน้างานซ้ำด้วยตนเอง"
        )
        return report

    status = str(result.get("verification_status", "")).strip().upper()
    notes = str(result.get("notes", "")).strip()

    if status == "CONFIRMED":
        report["verification_note"] = notes or "Verification pass ยืนยันสถานะ CRITICAL ตรงกับผลวิเคราะห์อิสระ"
        return report

    # Not confirmed: downgrade to WARNING and flag for a human recheck rather than shipping an
    # unverified CRITICAL claim — but this only happens for soft (LLM-judged) CRITICAL status,
    # never for hard-ruled ones, which the caller is responsible for excluding.
    summary = report.get("plant_summary", {})
    summary["overall_status"] = "WARNING"
    report["plant_summary"] = summary
    report["verification_note"] = (
        (notes + " " if notes else "")
        + "สถานะถูกปรับจาก CRITICAL เป็น WARNING เนื่องจาก Verification Pass ไม่สามารถยืนยันหลักฐานได้ชัดเจน "
        "แนะนำให้วิศวกรตรวจสอบหน้างานซ้ำก่อนปิดงาน"
    )
    return report
