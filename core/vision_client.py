import json
import base64
import io
import requests
from PIL import Image as PILImage

ENGINEERING_ANALYST_PROMPT = """
คุณคือ Engineering Evidence Analyst ทำหน้าที่สกัดหลักฐานก่อนเขียนรายงาน
ห้ามแต่งตัวเลข ป้ายข้อความ อุปกรณ์ สาเหตุ หรือผลตรวจที่ไม่ปรากฏในรูปและ notes
ห้ามคัดลอกข้อมูลจาก historical context, reference knowledge หรือชื่อไฟล์มาเป็นหลักฐานปัจจุบัน
แยก observed fact, interpretation, possible causes, missing evidence และ recommended checks
ทุกค่าที่อ่านได้ต้องมี source และคงรูปแบบตามหลักฐาน ห้ามคำนวณหรือเติมค่า
DO NOT invent numbers or default to template examples. Only extract visible numbers, labels, and text.
If not visible or unproven, output null or "UNCONFIRMED".
ทุกข้อสรุปต้องระบุความมั่นใจ High/Medium/Low และสถานะ root cause เป็น
Confirmed/Probable/Suspected/Unknown หากหลักฐานไม่พอให้ใช้ Unknown
ตอบ JSON เท่านั้นในรูปแบบ:
{
    "evidence": [{"file": "string", "observed": "string", "numbers": ["string"],
        "labels": ["string"], "reliability": "High/Medium/Low"}],
    "findings": [{"issue": "string or UNCONFIRMED", "observations": ["string"],
        "interpretation": "string or UNCONFIRMED", "possible_causes": ["string"],
        "root_cause_status": "Confirmed/Probable/Suspected/Unknown",
        "missing_evidence": ["string"], "recommended_checks": ["string"],
        "confidence": "High/Medium/Low"}],
    "correlations": [{"evidence_refs": ["string"], "observations": ["string"],
        "interpretation": "string or UNCONFIRMED", "status": "Confirmed/Probable/Suspected/Unknown"}]
}
"""

REPORT_WRITER_GUARDRAIL = """
คุณกำลังทำหน้าที่ Report Writer เท่านั้น ไม่ใช่ผู้วิเคราะห์ซ้ำ
ใช้ข้อมูลจาก VERIFIED ENGINEERING ANALYSIS เท่านั้น ห้ามเพิ่มตัวเลข อุปกรณ์ สาเหตุ
ผลตรวจ หรือความแน่นอนใหม่ แม้ prompt จะมีตัวอย่างประกอบก็ตาม
หาก analysis ระบุ Unknown/Suspected ให้คงสถานะนั้น ห้ามเปลี่ยนเป็น Confirmed
DO NOT invent numbers or default to template examples. Only extract visible numbers, labels, and text.
If not visible or unproven, output null or "UNCONFIRMED".
"""


def _http_error_message(status_code: int) -> str:
    if status_code in {401, 403}:
        return "API Key ไม่ถูกต้องหรือไม่มีสิทธิ์ใช้งาน Gemini API"
    if status_code == 429:
        return "Gemini API ถูกจำกัดจำนวนคำขอชั่วคราว กรุณารอสักครู่แล้วลองใหม่"
    if status_code >= 500:
        return "Gemini API ขัดข้องชั่วคราว กรุณาลองใหม่อีกครั้ง"
    return f"Gemini API ตอบกลับ HTTP {status_code}"


def optimize_image(file_bytes: bytes, max_dim: int = 2400) -> str:
    """Resize only when needed and preserve text-heavy images losslessly where possible."""
    try:
        with PILImage.open(io.BytesIO(file_bytes)) as img:
            img = img.convert("RGB")
            buf = io.BytesIO()
            if max(img.size) > max_dim:
                img.thumbnail((max_dim, max_dim), PILImage.Resampling.LANCZOS)
            img.save(buf, format="PNG", optimize=True)
            return base64.b64encode(buf.getvalue()).decode("utf-8")
    except Exception:
        # Fallback กรณีอ่านไฟล์ตรงๆ
        return base64.b64encode(file_bytes).decode("utf-8")

def execute_gemini_vision(parts: list, api_key: str) -> dict:
    """ยิง Gemini โดยเลือกเฉพาะโมเดลที่ API key นี้ใช้งานได้จริง"""
    api_key = (api_key or "").strip()
    if not api_key:
        raise RuntimeError("กรุณาใส่ Google Gemini API Key ก่อนใช้งานระบบวิเคราะห์")

    headers = {
        "Content-Type": "application/json",
        "x-goog-api-key": api_key
    }
    payload = {
        "contents": [{"parts": parts}],
        "generationConfig": {
            "temperature": 0.1,
            "responseMimeType": "application/json"
        }
    }

    candidate_models = []
    discovery_errors = []
    for api_version in ("v1beta", "v1"):
        try:
            models_url = f"https://generativelanguage.googleapis.com/{api_version}/models"
            models_res = requests.get(models_url, headers=headers, timeout=15)
            if models_res.status_code == 200:
                model_payload = models_res.json()
                raw_models = model_payload.get("models", []) if isinstance(model_payload, dict) else model_payload
                if not isinstance(raw_models, list):
                    raw_models = []
                for model in raw_models:
                    if not isinstance(model, dict):
                        continue
                    methods = model.get("supportedGenerationMethods", [])
                    model_name = str(model.get("name", "")).removeprefix("models/")
                    if model_name and "generateContent" in methods:
                        candidate_models.append((api_version, model_name))
                if candidate_models:
                    break
            else:
                discovery_errors.append(f"{api_version} (Status {models_res.status_code})")
        except requests.Timeout:
            discovery_errors.append(f"{api_version}: timeout")
        except (requests.RequestException, ValueError, TypeError):
            discovery_errors.append(f"{api_version}: response ไม่ถูกต้อง")

    preferred_order = [
        "gemini-1.5-pro",
        "gemini-1.5-flash",
        "gemini-2.5-flash",
        "gemini-2.0-flash",
        "gemini-1.5-flash",
    ]
    candidate_models.sort(key=lambda item: (
        preferred_order.index(item[1]) if item[1] in preferred_order else len(preferred_order),
        "flash" not in item[1],
    ))
    if not candidate_models:
        raise RuntimeError(
            "Gemini API ไม่ส่งรายชื่อโมเดลที่รองรับ generateContent "
            f"(ตรวจสอบ: {', '.join(discovery_errors) or 'ไม่พบโมเดล'}) "
            "กรุณาตรวจสอบ API Key และเปิดใช้งาน Generative Language API"
        )

    last_err = "ไม่ทราบสาเหตุ"
    timed_out = False
    for api_version, model_name in candidate_models:
        url = f"https://generativelanguage.googleapis.com/{api_version}/models/{model_name}:generateContent"
        try:
            res = requests.post(url, headers=headers, json=payload, timeout=60)
            if res.status_code == 200:
                response_payload = res.json()
                candidates = response_payload.get("candidates", []) if isinstance(response_payload, dict) else []
                if not candidates:
                    raise ValueError("Gemini response did not include any candidates")
                parts_payload = candidates[0].get("content", {}).get("parts", []) if isinstance(candidates[0], dict) else []
                if not parts_payload:
                    raise ValueError("Gemini response did not include any content parts")
                # Some Gemini responses may include a list of part objects or a text field directly.
                raw_text = parts_payload[0].get("text", "") if isinstance(parts_payload[0], dict) else ""
                if not raw_text:
                    text_value = parts_payload[0] if isinstance(parts_payload[0], str) else str(parts_payload[0])
                    raw_text = text_value.strip()
                raw_text = raw_text.strip()
                if raw_text.startswith("```"):
                    raw_text = raw_text.split("```json")[-1].split("```")[0].strip()
                parsed = json.loads(raw_text)
                if isinstance(parsed, str):
                    parsed = json.loads(parsed)
                if not isinstance(parsed, dict):
                    raise ValueError("Gemini response must be a JSON object")
                return parsed
            else:
                last_err = _http_error_message(res.status_code)
        except requests.Timeout:
            timed_out = True
            last_err = "การเชื่อมต่อ Gemini API หมดเวลา"
        except requests.RequestException:
            last_err = "เชื่อมต่อ Gemini API ไม่สำเร็จ กรุณาตรวจสอบเครือข่าย"
        except (json.JSONDecodeError, ValueError, TypeError, KeyError, AttributeError) as error:
            last_err = str(error)
            continue

    if timed_out and last_err == "การเชื่อมต่อ Gemini API หมดเวลา":
        raise RuntimeError("Gemini API หมดเวลาตอบกลับ กรุณาลองใหม่อีกครั้ง")
    raise RuntimeError(f"เกิดข้อผิดพลาดในการเชื่อมต่อ Gemini API: {last_err}")


def execute_gemini_vision_staged(
    evidence_parts: list,
    analyst_prompt: str,
    writer_prompt: str,
    api_key: str,
) -> dict:
    """วิเคราะห์หลักฐานก่อน แล้วให้ Gemini ตัวเดิมเรียบเรียงผลที่ตรวจแล้ว."""
    analysis = execute_gemini_vision(
        [{"text": analyst_prompt}, *evidence_parts],
        api_key,
    )
    writer_input = (
        f"{REPORT_WRITER_GUARDRAIL}\n{writer_prompt}\n\n[VERIFIED ENGINEERING ANALYSIS]\n"
        f"{json.dumps(analysis, ensure_ascii=False)}"
    )
    return execute_gemini_vision([{"text": writer_input}], api_key)