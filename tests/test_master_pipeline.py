import io
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

import router
from core.evidence_validator import validate_report
from core.docx_generator import build_docx
from engines.master_engine import _parse_json_response
import database.db_manager as db_manager


class Upload:
    def __init__(self, name, content=None):
        self.name = name
        self._bytes = io.BytesIO(content or b"")

    def read(self):
        return self._bytes.read()

    def seek(self, position):
        self._bytes.seek(position)


def valid_report():
    return {
        "plant_summary": {
            "plant_name": "ABC", "rated_capacity_kw": "500", "audit_date": "2026-08-28",
            "overall_status": "WARNING", "active_power_kw": "0.091", "grid_current_a": "10.18",
        },
        "executive_summary": "Current evidence summary.",
        "evidence_findings": [{
            "category": "Inverter & Monitoring", "source_file": "ABC_STATUS.png",
            "observed_data": "Active power 0.091 kW", "engineering_diagnosis": "Review shutdown state",
            "severity": "WARNING",
        }],
        "root_causes": [],
        "corrective_actions": [{"step_number": 1, "title": "Verify", "actions": ["Inspect current evidence"]}],
        "spare_parts_tools": [],
    }


def test_master_report_validates_and_generates_docx():
    report = validate_report(valid_report())
    document = build_docx(report)
    assert report["plant_summary"]["active_power_kw"] == "0.091"
    assert len(document.getvalue()) > 1000


def test_router_makes_one_master_call(monkeypatch):
    image = io.BytesIO()
    Image.new("RGB", (20, 20), "white").save(image, format="PNG")
    files = [Upload("ABC_2026-08-28_SMARTLOGGER_STATUS.png", image.getvalue())]
    calls = []

    monkeypatch.setattr(router, "run_master_analysis", lambda *args, **kwargs: calls.append((args, kwargs)) or valid_report())
    monkeypatch.setattr(router, "get_plant_history_context", lambda *args: "")
    monkeypatch.setattr(router, "get_similar_cases_context", lambda *args: "")
    monkeypatch.setattr(router, "extract_reference_context", lambda files: ("", []))

    report, document, report_type, _ = router.process_field_report(files, "key")

    assert len(calls) == 1
    assert report_type == "MASTER_REPORT"
    assert report["evidence_manifest"][0]["evidence_type"] == "STATUS"
    assert len(document.getvalue()) > 1000


def test_unproven_root_cause_is_marked_unconfirmed():
    report = valid_report()
    report["root_causes"] = [{
        "issue": "Microcrack", "description": "Confirmed module damage", "supporting_evidence": "Image",
    }]
    result = validate_report(report)
    assert result["root_causes"][0]["description"] == "UNCONFIRMED_HYPOTHESIS"


def test_master_json_parser_strips_markdown_fence():
    assert _parse_json_response('```json\n{"ok": true}\n```') == {"ok": True}


def test_cache_key_changes_with_language_and_plant():
    file = Upload("ABC_STATUS.png")
    assert router.build_job_cache_key([file], "key", "ABC", "th") != router.build_job_cache_key([file], "key", "ABC", "en")
    assert router.build_job_cache_key([file], "key", "ABC", "th") != router.build_job_cache_key([file], "key", "XYZ", "th")


def test_historical_memory_loads_audit_and_report(tmp_path, monkeypatch):
    monkeypatch.setattr(db_manager, "DB_PATH", str(tmp_path / "memory.db"))
    db_manager.init_database()
    report = valid_report()
    report["analysis_metadata"] = {"audit_id": "audit-42", "docx_path": "reports/audit-42.docx"}
    db_manager.save_approved_report_to_db(report)

    audits = db_manager.get_all_audits()
    loaded = db_manager.get_audit_by_id("audit-42")

    assert audits[0]["audit_id"] == "audit-42"
    assert audits[0]["active_power_kw"] == "0.091"
    assert loaded["executive_summary"] == "Current evidence summary."
    assert loaded["analysis_metadata"]["docx_path"] == "reports/audit-42.docx"
