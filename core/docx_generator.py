import io
import os

from PIL import Image
from docx import Document
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.enum.text import WD_ALIGN_PARAGRAPH
from docx.oxml import parse_xml
from docx.oxml.ns import nsdecls
from docx.shared import Inches, Pt, RGBColor

SEVERITY_STYLE = {
    "CRITICAL": ("FFD2D2", "900000"), "วิกฤต": ("FFD2D2", "900000"),
    "WARNING": ("FFF0B3", "593800"),  "เตือน": ("FFF0B3", "593800"),
    "NORMAL": ("D4EDDA", "155724"),   "ปกติ": ("D4EDDA", "155724"),
    "INFORMATIONAL": ("DDEBF7", "1F4E79"), "ข้อมูลทั่วไป": ("DDEBF7", "1F4E79"),
}

TABLE_HEADERS = {
    "th": {
        "summary": ["โรงไฟฟ้า / ไซต์งาน", "ขนาดพิกัด (kWp)", "วันที่ตรวจสอบ", "สถานะระบบ", "กำลังผลิตจริง (kW)", "กระแสส่งเข้ากริด (A)"],
        "findings": ["หมวดการตรวจสอบ", "ไฟล์หลักฐาน", "ข้อมูลที่ตรวจพบ", "ผลการวินิจฉัยทางวิศวกรรม", "ระดับความรุนแรง"],
        "damage": ["จุดบกพร่องที่พบ", "อุปกรณ์ที่จะเสียหายตามมา", "กลไกความเสียหายต่อเนื่อง (หากปล่อยทิ้งไว้)", "ค่าเสียหายหากไม่ซ่อม", "ค่าใช้จ่ายป้องกันตอนนี้"],
        "roots": ["ประเด็นปัญหา", "คำอธิบายเชิงลึก", "หลักฐานสนับสนุน"],
        "actions": ["ขั้นตอน", "หัวข้อการแก้ไข", "รายละเอียดการปฏิบัติงาน"],
        "spares": ["รายการอุปกรณ์ / เครื่องมือ", "จำนวนที่แนะนำ", "วัตถุประสงค์การใช้งาน"],
    },
    "en": {
        "summary": ["Plant / Site", "Capacity (kWp)", "Audit Date", "Overall Status", "Active Power (kW)", "Grid Current (A)"],
        "findings": ["Category", "Source File", "Observed Data", "Engineering Diagnosis", "Severity"],
        "damage": ["Identified Fault", "Component at Risk", "Damage Escalation Mechanism", "Cost if Neglected", "Immediate Prevention Cost"],
        "roots": ["Issue", "Detailed Description", "Supporting Evidence"],
        "actions": ["Step", "Title", "Actions"],
        "spares": ["Item / Tool Name", "Recommended Qty", "Purpose"],
    }
}


def _text(value):
    return "" if value is None else str(value)


def _heading(doc, text, size=11):
    paragraph = doc.add_paragraph()
    run = paragraph.add_run(_text(text))
    run.bold = True
    run.font.name = "Arial"
    run.font.size = Pt(size)
    return paragraph


def _shade(cell, fill):
    cell._tc.get_or_add_tcPr().append(parse_xml(f'<w:shd {nsdecls("w")} w:fill="{fill}"/>'))


def _severity_cell(cell, value):
    style = SEVERITY_STYLE.get(_text(value).strip().upper()) or SEVERITY_STYLE.get(_text(value).strip())
    if not style:
        return
    _shade(cell, style[0])
    for paragraph in cell.paragraphs:
        for run in paragraph.runs:
            run.bold = True
            run.font.color.rgb = RGBColor.from_string(style[1])


def _table(doc, headers, rows, severity_column=None):
    if not rows:
        return
    table = doc.add_table(rows=1, cols=len(headers))
    table.alignment = WD_TABLE_ALIGNMENT.CENTER
    table.style = "Table Grid"
    for cell, header in zip(table.rows[0].cells, headers):
        cell.text = _text(header)
        _shade(cell, "17365D")
        for run in cell.paragraphs[0].runs:
            run.bold = True
            run.font.color.rgb = RGBColor(255, 255, 255)
    for row_index, row in enumerate(rows):
        cells = table.add_row().cells
        for index, (cell, value) in enumerate(zip(cells, row)):
            cell.text = _text(value)
            cell.margin_top = Inches(0.04)
            cell.margin_bottom = Inches(0.04)
            if row_index % 2:
                _shade(cell, "F3F6FA")
            if severity_column == index:
                _severity_cell(cell, value)
    return table


def _add_header(doc):
    logo_path = os.path.join(os.path.dirname(os.path.dirname(__file__)), "logo.png")
    for section in doc.sections:
        table = section.header.add_table(rows=1, cols=2, width=Inches(7.2))
        left, right = table.rows[0].cells
        try:
            if os.path.exists(logo_path):
                left.paragraphs[0].add_run().add_picture(logo_path, height=Inches(0.35))
            else:
                raise OSError("logo unavailable")
        except Exception:
            left.text = "STUDIO OM"
        right.paragraphs[0].alignment = WD_ALIGN_PARAGRAPH.RIGHT
        run = right.paragraphs[0].add_run("Solar O&M Engineering Report")
        run.bold = True
        run.font.name = "Arial"


def _add_photos(doc, uploaded_files):
    for file in uploaded_files or []:
        name = _text(getattr(file, "name", "evidence"))
        if not name.lower().endswith((".png", ".jpg", ".jpeg", ".webp")):
            continue
        paragraph = doc.add_paragraph()
        paragraph.alignment = WD_ALIGN_PARAGRAPH.CENTER
        caption = paragraph.add_run(name)
        caption.bold = True
        try:
            file.seek(0)
            with Image.open(file) as image:
                image.thumbnail((1400, 1000), Image.Resampling.LANCZOS)
                buffer = io.BytesIO()
                image.convert("RGB").save(buffer, format="JPEG", quality=95, subsampling=0)
                buffer.seek(0)
                doc.add_paragraph().add_run().add_picture(buffer, width=Inches(6.0))
            file.seek(0)
        except Exception:
            file.seek(0)


def build_docx(report: dict, uploaded_files=None) -> io.BytesIO:
    doc = Document()
    _add_header(doc)
    for section in doc.sections:
        section.top_margin = Inches(0.65)
        section.bottom_margin = Inches(0.6)
        section.left_margin = Inches(0.65)
        section.right_margin = Inches(0.65)

    language = report.get("language", "th")
    lang_key = "th" if language == "th" else "en"
    headers_map = TABLE_HEADERS.get(lang_key, TABLE_HEADERS["th"])

    labels = {
        "th": (
            "1. สรุปผู้บริหารและสถานะภาพรวม",
            "2. การประเมินความเสียหายต่อเนื่องและค่าใช้จ่ายหากปล่อยทิ้งไว้ (Consequential Risk Matrix)",
            "3. ผลการตรวจสอบและวินิจฉัยจากหลักฐานจริง",
            "4. สาเหตุรากของปัญหา (Root Causes)",
            "5. แผนปฏิบัติการแก้ไขเชิงวิศวกรรม (Corrective Actions)",
            "6. รายการเครื่องมือและอะไหล่ที่ต้องจัดเตรียม (Spare Parts & Tooling)",
            "ภาคผนวก A  หลักฐานภาพถ่ายหน้างาน"
        ),
        "en": (
            "1. Executive Summary & Overview",
            "2. Consequential Damage & Inaction Risk Matrix",
            "3. Evidence-Based Technical Findings",
            "4. Root Cause Analysis",
            "5. Corrective Action Plan",
            "6. Spare Parts and Tooling List",
            "Appendix A  Field Evidence Photos"
        ),
    }.get(lang_key, labels["th"] if "labels" in locals() else None)

    summary = report.get("plant_summary", {})
    _heading(doc, "STUDIO OM | SOLAR O&M ENGINEERING REPORT", 10)
    _heading(doc, summary.get("plant_name") or "Solar O&M Engineering Report", 16)
    
    # 1. Summary Table
    _table(doc, headers_map["summary"], [[
        summary.get("plant_name"), summary.get("rated_capacity_kw"), summary.get("audit_date"),
        summary.get("overall_status"), summary.get("active_power_kw"), summary.get("grid_current_a"),
    ]], severity_column=3)

    # 2. Executive Summary
    _heading(doc, labels[0], 12)
    doc.add_paragraph(_text(report.get("executive_summary")))

    # 3. Consequential Damage Matrix (New Feature!)
    damage_rows = [
        [item.get("identified_fault"), item.get("component_at_risk"), item.get("escalation_mechanism"), item.get("estimated_damage_cost_thb"), item.get("immediate_prevention_cost_thb")]
        for item in report.get("inaction_damage_matrix", []) if isinstance(item, dict)
    ]
    if damage_rows:
        _heading(doc, labels[1], 12)
        _table(doc, headers_map["damage"], damage_rows)

    # 4. Evidence Findings
    _heading(doc, labels[2], 12)
    _table(doc, headers_map["findings"], [
        [item.get("category"), item.get("source_file"), item.get("observed_data"), item.get("engineering_diagnosis"), item.get("severity")]
        for item in report.get("evidence_findings", []) if isinstance(item, dict)
    ], severity_column=4)

    # 5. Root Causes
    _heading(doc, labels[3], 12)
    _table(doc, headers_map["roots"], [
        [item.get("issue"), item.get("description"), item.get("supporting_evidence")]
        for item in report.get("root_causes", []) if isinstance(item, dict)
    ])

    # 6. Corrective Actions
    _heading(doc, labels[4], 12)
    for action in report.get("corrective_actions", []):
        if isinstance(action, dict):
            _heading(doc, f"{action.get('step_number', '')}. {action.get('title', '')}", 10)
            for step in action.get("actions", []):
                doc.add_paragraph(_text(step), style="List Bullet")

    # 7. Spare Parts
    _heading(doc, labels[5], 12)
    _table(doc, headers_map["spares"], [
        [item.get("item_name"), item.get("recommended_qty"), item.get("purpose")]
        for item in report.get("spare_parts_tools", []) if isinstance(item, dict)
    ])

    # 8. Appendix Photos
    if uploaded_files:
        _heading(doc, labels[6], 12)
        _add_photos(doc, uploaded_files)

    output = io.BytesIO()
    doc.save(output)
    output.seek(0)
    return output