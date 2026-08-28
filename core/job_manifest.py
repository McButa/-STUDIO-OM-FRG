import re
from dataclasses import asdict, dataclass
from datetime import date
from typing import Any


SUPPORTED_EVIDENCE_TYPES = {
    "ALARM",
    "STATUS",
    "MEASUREMENT",
    "THERMAL",
    "VISUAL",
    "CHECKLIST",
    "REFERENCE",
    "NOTE",
    "UNKNOWN",
}

TYPE_ALIASES = {
    "alarm": "ALARM",
    "fault": "ALARM",
    "error": "ALARM",
    "status": "STATUS",
    "monitoring": "STATUS",
    "smartlogger": "STATUS",
    "webmonitor": "STATUS",
    "overview": "STATUS",
    "measurement": "MEASUREMENT",
    "measure": "MEASUREMENT",
    "current": "MEASUREMENT",
    "clamp": "MEASUREMENT",
    "string": "MEASUREMENT",
    "thermal": "THERMAL",
    "ir": "THERMAL",
    "thermography": "THERMAL",
    "visual": "VISUAL",
    "rgb": "VISUAL",
    "drone": "VISUAL",
    "aerial": "VISUAL",
    "checklist": "CHECKLIST",
    "pm": "CHECKLIST",
    "reference": "REFERENCE",
    "manual": "REFERENCE",
}


@dataclass(frozen=True)
class EvidenceFile:
    filename: str
    source: str
    equipment: str | None
    evidence_type: str
    site: str | None
    job_date: str | None

    def to_dict(self) -> dict[str, Any]:
        return asdict(self)


def _normalise_token(value: str) -> str:
    return re.sub(r"[^a-z0-9ก-๙]+", "_", value.lower()).strip("_")


def _parse_job_prefix(filename: str) -> tuple[str | None, str | None]:
    stem = re.sub(r"\.[^.]+$", "", filename)
    match = re.match(r"^(?P<site>.+?)_(?P<job_date>\d{4}-\d{2}-\d{2})(?:_|$)", stem)
    if not match:
        return None, None
    try:
        date.fromisoformat(match.group("job_date"))
    except ValueError:
        return match.group("site"), None
    return match.group("site").replace("_", " ").strip(), match.group("job_date")


def parse_evidence_file(filename: str) -> EvidenceFile:
    name = str(filename or "unknown").strip()
    lower_name = name.lower()
    stem = re.sub(r"\.[^.]+$", "", lower_name)
    tokens = [token for token in re.split(r"[_\-\s]+", stem) if token]
    site, job_date = _parse_job_prefix(name)

    if lower_name.endswith(".txt"):
        return EvidenceFile(name, "FIELD_NOTES", None, "NOTE", site, job_date)
    if lower_name.endswith(".pdf"):
        return EvidenceFile(name, "REFERENCE", None, "REFERENCE", site, job_date)

    evidence_type = "UNKNOWN"
    if any(TYPE_ALIASES.get(token) == "ALARM" for token in tokens):
        evidence_type = "ALARM"
    else:
        for token in tokens:
            if token in TYPE_ALIASES:
                evidence_type = TYPE_ALIASES[token]
                break
    equipment = None
    equipment_tokens = tokens
    job_match = re.match(r"^.+?_\d{4}-\d{2}-\d{2}_(?P<rest>.+)$", stem)
    if job_match:
        equipment_tokens = [token for token in re.split(r"[_\-\s]+", job_match.group("rest")) if token]
    if equipment_tokens:
        equipment_match = re.match(r"^(inv(?:erter)?\d+|scb\d+|string\d+|meter\d+)$", equipment_tokens[0])
        if equipment_match:
            equipment = equipment_tokens[0].upper()

    return EvidenceFile(name, "FIELD_EVIDENCE", equipment, evidence_type, site, job_date)


def build_manifest(uploaded_files) -> list[dict[str, Any]]:
    return [parse_evidence_file(getattr(file, "name", "unknown")).to_dict() for file in uploaded_files]


def manifest_summary(manifest: list[dict[str, Any]]) -> str:
    if not manifest:
        return "ไม่มีไฟล์หลักฐาน"
    lines = []
    for item in manifest:
        lines.append(
            f"- {item['filename']}: source={item['source']}, "
            f"equipment={item['equipment'] or 'ไม่ระบุ'}, type={item['evidence_type']}, "
            f"site={item['site'] or 'ไม่ระบุ'}, date={item['job_date'] or 'ไม่ระบุ'}"
        )
    return "\n".join(lines)
