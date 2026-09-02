import sqlite3
import json
import os
from datetime import datetime
from typing import Optional

DB_PATH = os.path.join(os.path.dirname(__file__), "studio_om.db")

def get_connection():
    conn = sqlite3.connect(DB_PATH)
    conn.row_factory = sqlite3.Row
    return conn

def init_database():
    """สร้างและอัปเดตโครงสร้างตาราง SQLite อัตโนมัติ (Safe Schema Migration)"""
    conn = get_connection()
    cursor = conn.cursor()

    # 1. ตารางข้อมูลไซต์งาน
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS plants (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT UNIQUE NOT NULL,
        location TEXT,
        capacity_kwp TEXT,
        inverter_info TEXT,
        approved_at TIMESTAMP,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP
    )
    """)

    # 2. ตารางประวัติรายงาน
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS reports (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        plant_id INTEGER,
        report_type TEXT NOT NULL DEFAULT 'DIAGNOSTIC',
        report_date TEXT,
        report_title TEXT,
        summary_text TEXT,
        tools_used TEXT,
        kpi_json TEXT,
        full_data_json TEXT,
        audit_id TEXT,
        status TEXT,
        docx_path TEXT,
        approved_at TIMESTAMP,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (plant_id) REFERENCES plants(id)
    )
    """)

    # 3. ตารางประวัติ Audits
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS audits (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        audit_id TEXT,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        plant_name TEXT NOT NULL,
        audit_date TEXT,
        status TEXT,
        active_power_kw TEXT,
        grid_current_a TEXT,
        summary_json TEXT,
        docx_path TEXT
    )
    """)

    # 4. ตารางคลังความรู้เคสซ่อมจริง
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS incident_cases (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        plant_id INTEGER,
        report_type TEXT NOT NULL DEFAULT 'DIAGNOSTIC',
        category TEXT NOT NULL,
        equipment TEXT,
        alarm_or_finding TEXT,
        root_cause TEXT,
        verified_solution TEXT,
        parts_used TEXT,
        approved_at TIMESTAMP,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (plant_id) REFERENCES plants(id)
    )
    """)

    # 5. ตารางความเสียหายทางการเงิน
    cursor.execute("""
    CREATE TABLE IF NOT EXISTS inaction_damage_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        audit_id TEXT,
        plant_id INTEGER,
        identified_fault TEXT,
        component_at_risk TEXT,
        min_damage_cost_thb REAL DEFAULT 0,
        max_damage_cost_thb REAL DEFAULT 0,
        min_prevention_cost_thb REAL DEFAULT 0,
        max_prevention_cost_thb REAL DEFAULT 0,
        created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
        FOREIGN KEY (plant_id) REFERENCES plants(id)
    )
    """)

    # Migration: ตรวจสอบและเพิ่มคอลัมน์ที่อาจขาดหายในกรณีฐานข้อมูลเดิม
    def ensure_column(table: str, column: str, col_type: str):
        cols = {row[1] for row in cursor.execute(f"PRAGMA table_info({table})").fetchall()}
        if column not in cols:
            try:
                cursor.execute(f"ALTER TABLE {table} ADD COLUMN {column} {col_type}")
            except sqlite3.OperationalError:
                pass

    ensure_column("plants", "approved_at", "TIMESTAMP")
    ensure_column("reports", "audit_id", "TEXT")
    ensure_column("reports", "status", "TEXT")
    ensure_column("reports", "docx_path", "TEXT")
    ensure_column("reports", "approved_at", "TIMESTAMP")
    ensure_column("reports", "full_data_json", "TEXT")
    ensure_column("audits", "audit_id", "TEXT")
    ensure_column("audits", "docx_path", "TEXT")
    ensure_column("incident_cases", "report_type", "TEXT NOT NULL DEFAULT 'DIAGNOSTIC'")
    ensure_column("incident_cases", "approved_at", "TIMESTAMP")

    # FTS5 Index สำหรับค้นหาเคส
    try:
        cursor.execute("""
        CREATE VIRTUAL TABLE IF NOT EXISTS incident_cases_fts USING fts5(
            alarm_or_finding, root_cause, category, content='incident_cases', content_rowid='id'
        )
        """)
    except sqlite3.OperationalError:
        pass

    conn.commit()
    conn.close()

def get_plant_history_context(plant_name: str, report_type: str = "") -> str:
    if not plant_name or plant_name == "Unknown Site":
        return ""

    conn = get_connection()
    cursor = conn.cursor()
    cursor.execute("SELECT * FROM plants WHERE name = ? AND approved_at IS NOT NULL", (plant_name.strip(),))
    plant = cursor.fetchone()
    
    if not plant:
        conn.close()
        return ""

    context = f"\n[ข้อมูลประวัติจริงของไซต์ {plant['name']} จากบันทึกในอดีต]\n"
    context += f"• ขนาดติดตั้ง: {plant['capacity_kwp'] or '-'}\n"
    context += f"• ข้อมูลอุปกรณ์: {plant['inverter_info'] or '-'}\n"

    if report_type:
        cursor.execute(
            "SELECT category, equipment, verified_solution FROM incident_cases WHERE plant_id = ? AND report_type = ?",
            (plant["id"], report_type.strip().upper())
        )
    else:
        cursor.execute("SELECT category, equipment, verified_solution FROM incident_cases WHERE plant_id = ?", (plant["id"],))
    cases = cursor.fetchall()
    if cases:
        context += "• ประวัติการแก้ไขปัญหาในอดีตของไซต์นี้:\n"
        for c in cases:
            context += f"  - {c['category']} ({c['equipment']}): {c['verified_solution']}\n"

    conn.close()
    return context

def _similar_cases_like_fallback(keywords: list, type_filter: str, plant_filter: str, cursor) -> list:
    cases_found = []
    for kw in keywords:
        if len(str(kw).strip()) < 3:
            continue
        cases_found.extend(cursor.execute("""
        SELECT p.name as plant_name, c.alarm_or_finding, c.root_cause, c.verified_solution, c.parts_used
        FROM incident_cases c
        JOIN plants p ON c.plant_id = p.id
        WHERE c.report_type = ? AND c.approved_at IS NOT NULL AND p.approved_at IS NOT NULL
          AND c.verified_solution != '' AND (? = '' OR p.name = ?)
          AND (c.category LIKE ? OR c.alarm_or_finding LIKE ?)
        LIMIT 4
        """, (type_filter, plant_filter, plant_filter, f"%{kw}%", f"%{kw}%")).fetchall())
    return cases_found

def get_similar_cases_context(keywords: list, report_type: str, plant_name: str = "") -> str:
    conn = get_connection()
    cursor = conn.cursor()
    type_filter = (report_type or "DIAGNOSTIC").strip().upper()
    plant_filter = (plant_name or "").strip()
    terms = [str(kw).strip() for kw in keywords if len(str(kw).strip()) >= 3]

    cases_found = []
    if terms:
        match_query = " OR ".join(f'"{term}"' for term in terms)
        try:
            def _fts_search(same_plant_only: bool, limit: int):
                sql = """
                SELECT p.name as plant_name, c.alarm_or_finding, c.root_cause, c.verified_solution, c.parts_used
                FROM incident_cases_fts f
                JOIN incident_cases c ON c.id = f.rowid
                JOIN plants p ON c.plant_id = p.id
                WHERE incident_cases_fts MATCH ?
                  AND c.report_type = ? AND c.approved_at IS NOT NULL AND p.approved_at IS NOT NULL
                  AND c.verified_solution != ''
                """
                params = [match_query, type_filter]
                if same_plant_only:
                    sql += " AND p.name = ?"
                    params.append(plant_filter)
                sql += " ORDER BY bm25(incident_cases_fts) LIMIT ?"
                params.append(limit)
                return cursor.execute(sql, params).fetchall()

            if plant_filter:
                cases_found.extend(_fts_search(True, 5))
            if len(cases_found) < 3:
                seen_pairs = {(c["alarm_or_finding"], c["plant_name"]) for c in cases_found}
                for row in _fts_search(False, 8):
                    if (row["alarm_or_finding"], row["plant_name"]) not in seen_pairs:
                        cases_found.append(row)
                        seen_pairs.add((row["alarm_or_finding"], row["plant_name"]))
        except sqlite3.OperationalError:
            cases_found = _similar_cases_like_fallback(terms, type_filter, plant_filter, cursor)

    conn.close()
    if not cases_found:
        return ""

    context = "\n[แนวทางแก้ไขมาตรฐานจากเคสจริงในอดีตของ STUDIO OM]\n"
    seen = set()
    token_budget_chars = 1500
    for c in cases_found:
        if c["alarm_or_finding"] in seen:
            continue
        entry = (
            f"• ปัญหา: {c['alarm_or_finding']} (ไซต์ {c['plant_name']})\n"
            f"  - วิธีแก้ไขที่ทำสำเร็จ: {c['verified_solution']}\n"
            f"  - อะไหล่ที่ใช้: {c['parts_used']}\n"
        )
        if len(context) + len(entry) > token_budget_chars:
            break
        seen.add(c["alarm_or_finding"])
        context += entry
    return context

def get_all_audits() -> list[dict]:
    """ดึงรายงานทั้งหมดอย่างปลอดภัย ไม่ทำให้ระบบ crash"""
    conn = get_connection()
    try:
        rows = conn.execute("""
            SELECT id, audit_id, created_at, plant_name, audit_date, status,
                   active_power_kw, grid_current_a, summary_json, docx_path
            FROM audits ORDER BY created_at DESC, id DESC
        """).fetchall()
        
        if not rows:
            rows = conn.execute("""
            SELECT r.id, r.audit_id, r.report_date, r.status, r.docx_path, r.full_data_json,
                   p.name AS plant_name
            FROM reports r
            JOIN plants p ON p.id = r.plant_id
            WHERE r.approved_at IS NOT NULL
            ORDER BY r.id DESC
            """).fetchall()
    except sqlite3.OperationalError:
        rows = []
    finally:
        conn.close()

    audits = []
    for row in rows:
        item = dict(row)
        item.setdefault("audit_id", str(item.get("id", "")))
        try:
            full_data = json.loads(item.pop("summary_json", item.pop("full_data_json", "{}")) or "{}")
        except (TypeError, ValueError):
            full_data = {}
        summary = full_data.get("plant_summary", {}) if isinstance(full_data, dict) else {}
        item["active_power_kw"] = summary.get("active_power_kw", item.get("active_power_kw", ""))
        item["executive_summary"] = full_data.get("executive_summary", "") if isinstance(full_data, dict) else ""
        audits.append(item)
    return audits

def get_audit_by_id(audit_id: str) -> dict | None:
    conn = get_connection()
    row = conn.execute(
        "SELECT summary_json, docx_path FROM audits WHERE audit_id = ? OR id = ? OR CAST(id AS TEXT) = ?",
        (str(audit_id), str(audit_id), str(audit_id)),
    ).fetchone()
    if not row:
        row = conn.execute(
            "SELECT full_data_json, docx_path FROM reports WHERE audit_id = ? AND approved_at IS NOT NULL",
            (str(audit_id),),
        ).fetchone()
    conn.close()
    if not row:
        return None
    try:
        raw_json = row["summary_json"] if "summary_json" in row.keys() and row["summary_json"] else row["full_data_json"]
        report = json.loads(raw_json or "{}")
    except (TypeError, ValueError):
        report = {}
    report["analysis_metadata"] = report.get("analysis_metadata", {})
    report["analysis_metadata"]["docx_path"] = row["docx_path"] or report["analysis_metadata"].get("docx_path", "")
    return report

def save_approved_report_to_db(data: dict, report_type: str = "", engineer_solutions: Optional[list] = None):
    conn = get_connection()
    cursor = conn.cursor()
    
    p_info = data.get("plant_summary", {})
    plant_name = str(p_info.get("plant_name") or "").strip()
    if not plant_name or plant_name == "Unknown Site":
        plant_name = f"Site_{datetime.now().strftime('%Y%m%d_%H%M')}"
    resolved_report_type = (report_type or data.get("report_type") or "DIAGNOSTIC").strip().upper()
    
    cursor.execute("SELECT id FROM plants WHERE name = ? AND approved_at IS NOT NULL", (plant_name,))
    row = cursor.fetchone()
    if row:
        plant_id = row["id"]
    else:
        cap_val = str(p_info.get("rated_capacity_kw") or "")
        cursor.execute(
            "INSERT INTO plants (name, location, capacity_kwp, inverter_info, approved_at) VALUES (?, ?, ?, ?, ?)",
            (plant_name, "", cap_val, "", datetime.now().isoformat(timespec="seconds"))
        )
        plant_id = cursor.lastrowid

    cursor.execute("""
        INSERT INTO reports (plant_id, report_type, report_date, report_title, summary_text, tools_used, kpi_json, full_data_json, audit_id, status, docx_path, approved_at)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        plant_id,
        resolved_report_type,
        p_info.get("audit_date", datetime.today().strftime("%d %B %Y")),
        "STUDIO OM Solar O&M Engineering Report",
        data.get("executive_summary", ""),
        "",
        json.dumps(p_info, ensure_ascii=False),
        json.dumps(data, ensure_ascii=False),
        data.get("analysis_metadata", {}).get("audit_id", ""),
        p_info.get("overall_status", ""),
        data.get("analysis_metadata", {}).get("docx_path", ""),
        datetime.now().isoformat(timespec="seconds"),
    ))
    report_id = cursor.lastrowid

    cursor.execute("""
        INSERT INTO audits
        (audit_id, plant_name, audit_date, status, active_power_kw, grid_current_a, summary_json, docx_path)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
    """, (
        data.get("analysis_metadata", {}).get("audit_id", ""),
        plant_name,
        p_info.get("audit_date", ""),
        p_info.get("overall_status", ""),
        p_info.get("active_power_kw", ""),
        p_info.get("grid_current_a", ""),
        json.dumps(data, ensure_ascii=False),
        data.get("analysis_metadata", {}).get("docx_path", ""),
    ))

    has_fts = True
    for index, item in enumerate(data.get("evidence_findings", [])):
        if not (isinstance(item, dict) and item.get("observed_data")):
            continue
        sol_entry = (engineer_solutions[index] if engineer_solutions and index < len(engineer_solutions) else {}) or {}
        verified_solution = str(sol_entry.get("solution") or "")
        parts_used = str(sol_entry.get("parts") or "")
        cursor.execute("""
            INSERT INTO incident_cases (plant_id, report_type, category, equipment, alarm_or_finding, root_cause, verified_solution, parts_used, approved_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            plant_id, resolved_report_type, item.get("category", "-"), item.get("source_file", ""),
            item.get("observed_data", ""), item.get("engineering_diagnosis", ""),
            verified_solution, parts_used, datetime.now().isoformat(timespec="seconds")
        ))
        incident_id = cursor.lastrowid
        if has_fts and verified_solution:
            try:
                cursor.execute(
                    "INSERT INTO incident_cases_fts (rowid, alarm_or_finding, root_cause, category) VALUES (?, ?, ?, ?)",
                    (incident_id, item.get("observed_data", ""), item.get("engineering_diagnosis", ""), item.get("category", "")),
                )
            except sqlite3.OperationalError:
                has_fts = False

    audit_id = data.get("analysis_metadata", {}).get("audit_id", "")
    for item in data.get("inaction_damage_matrix", []):
        if not isinstance(item, dict):
            continue
        cursor.execute("""
            INSERT INTO inaction_damage_items
            (audit_id, plant_id, identified_fault, component_at_risk, min_damage_cost_thb, max_damage_cost_thb, min_prevention_cost_thb, max_prevention_cost_thb)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """, (
            audit_id, plant_id, item.get("identified_fault", ""), item.get("component_at_risk", ""),
            float(item.get("min_damage_cost_thb") or 0), float(item.get("max_damage_cost_thb") or 0),
            float(item.get("min_prevention_cost_thb") or 0), float(item.get("max_prevention_cost_thb") or 0),
        ))

    conn.commit()
    conn.close()
    return report_id

def get_previous_audit_kpis(plant_name: str) -> Optional[dict]:
    plant_name = (plant_name or "").strip()
    if not plant_name:
        return None
    conn = get_connection()
    cursor = conn.cursor()
    row = cursor.execute("""
        SELECT audit_date, status, active_power_kw, grid_current_a
        FROM audits WHERE plant_name = ? ORDER BY id DESC LIMIT 1
    """, (plant_name,)).fetchone()
    conn.close()
    return dict(row) if row else None

def get_total_damage_exposure(plant_name: str = "") -> float:
    """SUM ความเสี่ยงทางการเงินสูงสุด (max_damage_cost_thb) รวมทั้งหมด หรือกรองเฉพาะไซต์เดียว"""
    conn = get_connection()
    cursor = conn.cursor()
    if plant_name.strip():
        cursor.execute("""
            SELECT COALESCE(SUM(d.max_damage_cost_thb), 0)
            FROM inaction_damage_items d JOIN plants p ON d.plant_id = p.id
            WHERE p.name = ?
        """, (plant_name.strip(),))
    else:
        cursor.execute("SELECT COALESCE(SUM(max_damage_cost_thb), 0) FROM inaction_damage_items")
    total = cursor.fetchone()[0]
    conn.close()
    return float(total or 0)

# ทำการ initialize โครงสร้างทันทีเมื่อโหลดโมดูล
init_database()