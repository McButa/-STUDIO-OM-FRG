from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError


Status = Literal["CRITICAL", "WARNING", "NORMAL"]
Severity = Literal["CRITICAL", "WARNING", "NORMAL", "INFORMATIONAL"]
Category = Literal[
    "Inverter & Monitoring", "Field Alarms", "String Electrical", "Thermography", "Visual Survey"
]


class PlantSummary(BaseModel):
    model_config = ConfigDict(extra="ignore")
    plant_name: str | None = None
    rated_capacity_kw: str | None = None
    audit_date: str | None = None
    overall_status: Status | None = None
    active_power_kw: str | None = None
    grid_current_a: str | None = None


class EvidenceFinding(BaseModel):
    model_config = ConfigDict(extra="ignore")
    category: Category
    source_file: str
    observed_data: str
    engineering_diagnosis: str
    severity: Severity


class RootCause(BaseModel):
    model_config = ConfigDict(extra="ignore")
    issue: str
    description: str
    supporting_evidence: str


class CorrectiveAction(BaseModel):
    model_config = ConfigDict(extra="ignore")
    step_number: int = Field(ge=1)
    title: str
    actions: list[str]


class SparePartTool(BaseModel):
    model_config = ConfigDict(extra="ignore")
    item_name: str
    recommended_qty: str
    purpose: str


class MasterReport(BaseModel):
    model_config = ConfigDict(extra="ignore")
    plant_summary: PlantSummary
    executive_summary: str
    evidence_findings: list[EvidenceFinding]
    root_causes: list[RootCause]
    corrective_actions: list[CorrectiveAction]
    spare_parts_tools: list[SparePartTool]


def validate_report(data: dict) -> dict:
    """Validate the master report and reject unsupported claims instead of inventing fallback text."""
    try:
        report = MasterReport.model_validate(data)
    except ValidationError as error:
        raise ValueError(f"Master report schema validation failed: {error}") from error

    result = report.model_dump()
    evidence_text = " ".join(
        f"{finding.source_file} {finding.observed_data} {finding.engineering_diagnosis}"
        for finding in report.evidence_findings
    ).lower()
    for cause in result["root_causes"]:
        claim = f"{cause['issue']} {cause['description']}".lower()
        proven_marker = any(marker in evidence_text for marker in ("alarm", "riso", "megger", "el test", "insulation"))
        if any(term in claim for term in ("microcrack", "micro-crack", "ground fault", "riso low")) and not proven_marker:
            cause["description"] = "UNCONFIRMED_HYPOTHESIS"
            cause["supporting_evidence"] = "UNCONFIRMED"
    return result
