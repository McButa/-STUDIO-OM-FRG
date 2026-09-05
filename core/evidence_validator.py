import re
from typing import Literal

from pydantic import BaseModel, ConfigDict, Field, ValidationError, field_validator, model_validator


Status = Literal["CRITICAL", "WARNING", "NORMAL"]
Severity = Literal["CRITICAL", "WARNING", "NORMAL", "INFORMATIONAL"]
Category = Literal[
    "Inverter & Monitoring", "Field Alarms", "String Electrical", "Thermography", "Visual Survey"
]


def coerce_float(value) -> float | None:
    """Strip unit text/commas from LLM output and cast to float. Missing/unparseable -> None
    (unlike _coerce_cost, None here is meaningful: 'not measured' must stay distinguishable from 0)."""
    if value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    cleaned = re.sub(r"[^\d.\-]", "", str(value))
    try:
        return float(cleaned) if cleaned not in ("", "-", ".") else None
    except ValueError:
        return None


def _coerce_cost(value) -> float:
    """Strip currency text/commas from LLM output and cast to float. Missing/unparseable -> 0.0."""
    parsed = coerce_float(value)
    return parsed if parsed is not None else 0.0


class PlantSummary(BaseModel):
    model_config = ConfigDict(extra="ignore")
    plant_name: str | None = None
    rated_capacity_kw: str | None = None
    audit_date: str | None = None
    overall_status: Status | None = None
    active_power_kw: str | None = None
    grid_current_a: str | None = None
    # Numeric versions parsed once here so no other file needs its own regex to read these values.
    rated_capacity_kw_num: float | None = None
    active_power_kw_num: float | None = None
    grid_current_a_num: float | None = None

    @model_validator(mode="after")
    def _parse_numeric_kpis(self):
        self.rated_capacity_kw_num = coerce_float(self.rated_capacity_kw)
        self.active_power_kw_num = coerce_float(self.active_power_kw)
        self.grid_current_a_num = coerce_float(self.grid_current_a)
        return self


class Measurement(BaseModel):
    """One numeric reading, captured as data instead of prose. The LLM's
    narrative wording changes every run (sometimes 'Active power: 3.867 kW',
    sometimes nothing at all); a structured field with a fixed vocabulary of
    parameter names is what makes downstream Python code able to compute
    totals/thresholds reliably instead of regexing whatever text showed up
    this time. `comparator` preserves inequality readings honestly — a paper
    Megger test reported as '>1000 MOhm' is a lower bound, not the number
    1000, and collapsing that distinction would misrepresent the evidence."""
    model_config = ConfigDict(extra="ignore")
    parameter: str
    value: float | None = None
    unit: str | None = None
    comparator: Literal["=", ">", "<"] = "="


class EvidenceFinding(BaseModel):
    model_config = ConfigDict(extra="ignore")
    category: Category
    source_file: str
    observed_data: str
    engineering_diagnosis: str
    severity: Severity
    key_measurements: list[Measurement] = Field(default_factory=list)
    # Set by core/threshold_rules.py, never by the LLM: records WHY an
    # automatic severity escalation happened, so the report never asserts
    # "violates safety standard" with more confidence than the evidence
    # actually supports. None = severity wasn't auto-escalated by a rule.
    corroboration: str | None = None


class RootCause(BaseModel):
    model_config = ConfigDict(extra="ignore")
    issue: str
    description: str
    supporting_evidence: str


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


def validate_evidence_coverage(evidence_findings: list, expected_filenames: list) -> list:
    """Two things must both hold, or the LLM's response is not trustworthy
    enough to accept:
      1. Every uploaded file is referenced by at least one finding — nothing
         silently dropped.
      2. No single finding's source_file matches MORE THAN ONE of the
         separately-uploaded filenames — that is the real bug found in
         production: 5 individually-uploaded inverter screenshots
         (Inv_2.jpg .. Inv_6.jpg) got merged into a single row, silently
         losing the fact that Inv_6 (13.541 MOhm, healthy) is a completely
         different unit from Inv_2-5 (0.836-0.921 MOhm, degraded).
      This does NOT reject a genuine single batch-test file whose CONTENT
      covers several inverters (e.g. 'DC_Inv_1-2.jpg', 'AC_Inv_1-6.jpg') —
      that file was itself uploaded as ONE file, so it only ever matches
      ONE entry in expected_filenames, never more than one.
    Returns a list of human-readable problem strings; empty list = OK.
    """
    problems = []
    referenced = set()
    for finding in evidence_findings:
        if not isinstance(finding, dict):
            continue
        source_file = str(finding.get("source_file", ""))
        matches = [fn for fn in expected_filenames if fn and fn in source_file]
        if len(matches) > 1:
            problems.append(
                f"finding source_file '{source_file}' merges {len(matches)} separately-uploaded "
                f"files into one row ({matches}) — each uploaded file needs its own row"
            )
        referenced.update(matches)

    missing = [fn for fn in expected_filenames if fn not in referenced]
    if missing:
        problems.append(f"no evidence_finding references uploaded file(s): {missing}")

    return problems


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

