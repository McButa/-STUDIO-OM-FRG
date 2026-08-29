import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator


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


def _coerce_cost(value) -> float:
    """Strip currency text/commas from LLM output and cast to float. Missing/unparseable -> 0.0."""
    if value is None:
        return 0.0
    if isinstance(value, (int, float)):
        return float(value)
    cleaned = re.sub(r"[^\d.\-]", "", str(value))
    try:
        return float(cleaned) if cleaned else 0.0
    except ValueError:
        return 0.0


class InactionDamageItem(BaseModel):
    model_config = ConfigDict(extra="ignore")
    identified_fault: str
    component_at_risk: str
    escalation_mechanism: str
    min_damage_cost_thb: float = 0.0
    max_damage_cost_thb: float = 0.0
    min_prevention_cost_thb: float = 0.0
    max_prevention_cost_thb: float = 0.0

    @field_validator(
        "min_damage_cost_thb", "max_damage_cost_thb",
        "min_prevention_cost_thb", "max_prevention_cost_thb",
        mode="before",
    )
    @classmethod
    def _parse_cost(cls, value):
        return _coerce_cost(value)

    @model_validator(mode="after")
    def _swap_if_inverted(self):
        if self.max_damage_cost_thb < self.min_damage_cost_thb:
            self.min_damage_cost_thb, self.max_damage_cost_thb = (
                self.max_damage_cost_thb, self.min_damage_cost_thb,
            )
        if self.max_prevention_cost_thb < self.min_prevention_cost_thb:
            self.min_prevention_cost_thb, self.max_prevention_cost_thb = (
                self.max_prevention_cost_thb, self.min_prevention_cost_thb,
            )
        return self


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
    inaction_damage_matrix: list[InactionDamageItem] = Field(default_factory=list)
    corrective_actions: list[CorrectiveAction]
    spare_parts_tools: list[SparePartTool]


def validate_report(data: dict) -> dict:
    """Validate the master report and reject unsupported claims instead of inventing fallback text."""
    try:
        report = MasterReport.model_validate(data)
    except ValidationError as error:
        raise ValueError(f"Master report schema validation failed: {error}") from error

    result = report.model_dump()
    result["total_max_damage_exposure_thb"] = sum(
        item["max_damage_cost_thb"] for item in result["inaction_damage_matrix"]
    )
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
