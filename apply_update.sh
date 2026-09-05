#!/bin/bash
set -e
cd /workspaces/-STUDIO-OM-FRG

mkdir -p core tests engines tests/fixtures

cat > app.py << 'PYEOF'
import base64
import os
import streamlit as st

st.set_page_config(
    page_title="STUDIO OM Field Report Engine (Production)",
    page_icon="⚡",
    layout="wide"
)


def _app_password() -> str:
    # st.secrets.get(...) still raises StreamlitSecretNotFoundError if no
    # secrets.toml exists anywhere at all (it only behaves like dict.get once
    # a secrets file is present) — fall back to env var / default instead of
    # crashing the whole app before the login screen even renders.
    try:
        secret_password = st.secrets.get("APP_PASSWORD")
    except Exception:
        secret_password = None
    return str(secret_password or os.getenv("APP_PASSWORD", "om2026"))


def _render_login():
    logo_data = ""
    if os.path.isfile("logo.png"):
        with open("logo.png", "rb") as logo_file:
            logo_data = base64.b64encode(logo_file.read()).decode("ascii")
    logo_markup = f'<img src="data:image/png;base64,{logo_data}" alt="Studio OM logo">' if logo_data else ""
    st.markdown(
        """
        <style>
        [data-testid="stHeader"], [data-testid="stToolbar"],
        [data-testid="stDecoration"], footer, [data-testid="stSidebar"] {
            visibility: hidden;
            display: none;
        }
        .stApp {
            background: radial-gradient(circle at 50% 30%, #1e293b, #0f172a 52%, #020617);
        }
        .login-shell {
            min-height: 82vh;
            display: flex;
            align-items: center;
            justify-content: center;
        }
        .login-card {
            width: min(440px, 92vw);
            padding: 2.6rem 2.4rem 2.2rem;
            text-align: center;
            background: rgba(15, 23, 42, .68);
            border: 1px solid rgba(148, 163, 184, .24);
            border-radius: 24px;
            box-shadow: 0 24px 80px rgba(0, 0, 0, .42), inset 0 1px rgba(255, 255, 255, .08);
            backdrop-filter: blur(20px);
        }
        .login-card img {
            width: min(290px, 78vw);
            max-height: 180px;
            object-fit: contain;
            filter: drop-shadow(0 0 20px rgba(125, 211, 252, .32));
            margin-bottom: 1rem;
        }
        .login-slogan {
            color: #e2e8f0;
            font-size: 1rem;
            letter-spacing: .08em;
            margin-bottom: 1.8rem;
        }
        div[data-testid="stForm"] {
            width: min(440px, 92vw);
            margin: -12rem auto 0;
            background: transparent;
            border: 0;
            padding: 0;
        }
        div[data-testid="stFormSubmitButton"] button {
            width: 100%;
            border: 0;
            color: #082f49;
            background: linear-gradient(135deg, #bae6fd, #60a5fa);
            font-weight: 700;
            transition: transform .2s ease, box-shadow .2s ease;
        }
        div[data-testid="stFormSubmitButton"] button:hover {
            transform: translateY(-2px);
            box-shadow: 0 8px 24px rgba(96, 165, 250, .34);
        }
        </style>
        """,
        unsafe_allow_html=True,
    )
    st.markdown(
        f"""
        <div class="login-shell"><div class="login-card">
            {logo_markup}
            <div class="login-slogan">Studio OM® — We build TECH for Energy</div>
        </div></div>
        """,
        unsafe_allow_html=True,
    )
    with st.form("login_form"):
        password = st.text_input("รหัสผ่าน", type="password", placeholder="กรอกรหัสผ่านเพื่อเข้าใช้งาน...", label_visibility="collapsed")
        submitted = st.form_submit_button("🔓 ปลดล็อกเข้าสู่ระบบ / Unlock", use_container_width=True)
    if submitted:
        if password == _app_password():
            st.session_state["authenticated"] = True
            st.rerun()
        st.error("รหัสผ่านไม่ถูกต้อง กรุณาลองใหม่อีกครั้ง")


if not st.session_state.get("authenticated", False):
    _render_login()
    st.stop()

from router import build_job_cache_key, process_field_report
from database.db_manager import (
    get_all_audits,
    get_audit_by_id,
    get_connection,
    save_approved_report_to_db,
)

# Sidebar
st.sidebar.header("⚙️ การเชื่อมต่อ AI")
st.sidebar.markdown("👤 ผู้ใช้งาน: **O&M Engineer**")
if st.sidebar.button("🚪 ออกจากระบบ (Logout)", use_container_width=True):
    st.session_state["authenticated"] = False
    st.rerun()
api_key = st.sidebar.text_input("Google Gemini API Key", type="password", help="วาง Google Gemini API Key")
language_label = st.sidebar.selectbox("Report Language", ["🇹🇭 ภาษาไทย", "🇬🇧 English"], index=0)
report_language = "th" if language_label.startswith("🇹🇭") else "en"

if "report_uploader_key" not in st.session_state:
    st.session_state["report_uploader_key"] = 0


def reset_report_session():
    for key in ("active_data", "active_docx", "active_type"):
        st.session_state.pop(key, None)
    st.session_state["report_uploader_key"] += 1


def store_report_result(cache_key, result):
    st.session_state.setdefault("report_cache", {})[cache_key] = result
    st.session_state["active_data"], docx_bytes, st.session_state["active_type"], _ = result
    st.session_state["active_docx"] = docx_bytes

tab_report, tab_knowledge = st.tabs(["🚀 สร้างรายงานหน้างาน (Autonomous Generator)", "📚 คลังประวัติไซต์และเคสซ่อม (Studio OM Memory)"])

# ==============================================================
# TAB 1: ระบบวิเคราะห์และสร้างรายงานอัตโนมัติ 0-Click
# ==============================================================
with tab_report:
    st.title("📋 STUDIO OM Field Report Engine")
    st.caption("ระบบวิเคราะห์ O&M โซลาร์เซลล์อัตโนมัติระดับ Production (Zero-Touch AI Ingestion)")
    st.divider()

    reset_col, status_col = st.columns([1, 4])
    with reset_col:
        if st.button("🗑️ เริ่มงานใหม่", use_container_width=True):
            reset_report_session()
            st.rerun()

    uploaded_files = st.file_uploader(
        "ลากไฟล์หลักฐานหน้างาน, notes.txt และเอกสารอ้างอิง PDF มาวางที่นี่",
        accept_multiple_files=True,
        type=["jpg", "jpeg", "png", "webp", "txt", "pdf"],
        key=f"report_uploader_{st.session_state['report_uploader_key']}"
    )

    default_plant = ""
    if uploaded_files:
        default_plant = str(uploaded_files[0].name).rsplit(".", 1)[0].split("_")[0]
    if "plant_name_input" not in st.session_state or not st.session_state["plant_name_input"]:
        st.session_state["plant_name_input"] = default_plant
    plant_name_input = st.sidebar.text_input("Plant Name", key="plant_name_input")

    if uploaded_files:
        st.write(f"📁 พร้อมประมวลผล: **{len(uploaded_files)} ไฟล์**")
        
        if st.button("⚡ ส่งให้ AI วิเคราะห์รูปภาพและสร้างรายงาน Word ทันที", type="primary", use_container_width=True):
            if not api_key:
                st.error("❌ กรุณาใส่ Google Gemini API Key ที่แถบด้านซ้ายก่อนเริ่มวิเคราะห์")
            else:
                with st.spinner("🤖 AI กำลังจำแนกประเภทงาน อ่านภาพความละเอียดสูง และดึงความจำจาก Database..."):
                    try:
                        for key in ["active_data", "active_docx", "active_type"]:
                            st.session_state.pop(key, None)
                        cache_key = build_job_cache_key(uploaded_files, api_key, plant_name_input, report_language)
                        cached_result = st.session_state.get("report_cache", {}).get(cache_key)
                        if cached_result:
                            store_report_result(cache_key, cached_result)
                            st.success("✅ ใช้ผลรายงานจาก cache เดิม ไม่เรียก Gemini ซ้ำ")
                        else:
                            result = process_field_report(uploaded_files, api_key, plant_name_input, report_language)
                            data, docx_bytes, job_type, site_ctx = result
                            store_report_result(cache_key, (data, docx_bytes.getvalue(), job_type, site_ctx))
                            st.success(f"✅ สำเร็จ! ระบบตรวจพบและสับรางอัตโนมัติไปยัง: **[{job_type}]**")
                    except Exception as e:
                        st.error(f"เกิดข้อผิดพลาดในการประมวลผล: {e}")

    # แสดงผลลัพธ์
    if "active_data" in st.session_state:
        data = st.session_state["active_data"]
        p_info = data.get("plant_summary", {})

        st.divider()
        st.subheader(f"📊 ผลการวินิจฉัยไซต์งาน: {p_info.get('plant_name', '-')}")
        st.caption(f"สถานะรวม: {p_info.get('overall_status', '-')}")

        c1, c2, c3 = st.columns(3)
        c1.metric("ชื่อไซต์งาน", p_info.get("plant_name", "-"))
        c2.metric("Active power (kW)", p_info.get("active_power_kw") or "-")
        c3.metric("Grid current (A)", p_info.get("grid_current_a") or "-")

        st.info(f"**สรุปสถานการณ์เชิงวิศวกรรม:** {data.get('executive_summary', '-')}")

        st.markdown("**บันทึกวิธีแก้ไขจริงและอะไหล่ที่ใช้ (ไว้เป็นความรู้ให้เคสหน้า):**")
        for i, finding in enumerate(data.get("evidence_findings", [])):
            with st.expander(f"{finding.get('severity', '')} | {finding.get('category', '')} | {finding.get('source_file', '')}"):
                st.write(finding.get("observed_data", ""))
                st.caption(finding.get("engineering_diagnosis", ""))
                if finding.get("severity") in ("CRITICAL", "WARNING"):
                    st.text_input("วิธีแก้ที่ทำจริง", key=f"solution_{i}", placeholder="เช่น เปลี่ยน MC4 connector ที่ชำรุด")
                    st.text_input("อะไหล่ที่ใช้จริง", key=f"parts_{i}", placeholder="เช่น MC4 x2")

        plant_slug = str(p_info.get("plant_name", "Site")).replace(" ", "_")
        col_dl, col_save = st.columns(2)
        with col_dl:
            st.download_button(
                label=f"📥 ดาวน์โหลดเอกสาร Word (.docx) — STUDIO_OM_{plant_slug}_Report.docx",
                data=st.session_state["active_docx"],
                file_name=f"STUDIO_OM_{plant_slug}_Report.docx",
                mime="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                type="primary",
                use_container_width=True
            )
        with col_save:
            if st.button("💾 อนุมัติรายงานและบันทึกความรู้เข้า Database", use_container_width=True):
                os.makedirs("reports", exist_ok=True)
                audit_id = data.get("analysis_metadata", {}).get("audit_id", "audit")
                docx_path = os.path.join("reports", f"STUDIO_OM_{audit_id}.docx")
                with open(docx_path, "wb") as output_file:
                    output_file.write(st.session_state["active_docx"])
                data.setdefault("analysis_metadata", {})["docx_path"] = docx_path
                engineer_solutions = [
                    {"solution": st.session_state.get(f"solution_{i}", ""), "parts": st.session_state.get(f"parts_{i}", "")}
                    for i in range(len(data.get("evidence_findings", [])))
                ]
                rep_id = save_approved_report_to_db(
                    data,
                    report_type=st.session_state.get("active_type", ""),
                    engineer_solutions=engineer_solutions,
                )
                st.success(f"🎉 บันทึกรายงาน ID #{rep_id} และเคสความรู้เข้า Database สำเร็จเรียบร้อย!")

# ==============================================================
# TAB 2: คลังประวัติไซต์งานและเคสอ้างอิง
# ==============================================================
with tab_knowledge:
    st.title("📚 คลังประวัติไซต์งานและเคสซ่อม (Studio OM Memory)")
    st.caption("ประวัติการตรวจเช็คย้อนหลัง และคลังเคสปัญหาที่ได้รับการแก้ไขจริง")
    if st.button("🔄 รีเฟรชข้อมูลคลังความจำ", key="refresh_memory", use_container_width=False):
        st.rerun()
    st.divider()

    audits = get_all_audits()
    if audits:
        st.subheader("Audit Reports")
        st.dataframe(
            [
                {
                    "Audit ID": audit.get("audit_id", ""),
                    "Date": audit.get("report_date", ""),
                    "Plant Name": audit.get("plant_name", ""),
                    "Status": audit.get("status", ""),
                    "Active Power (kW)": audit.get("active_power_kw", ""),
                }
                for audit in audits
            ],
            use_container_width=True,
            hide_index=True,
        )
        audit_options = [audit.get("audit_id") for audit in audits if audit.get("audit_id")]
        if audit_options:
            selected_audit_id = st.selectbox("เลือก Audit เพื่อดูรายละเอียด", audit_options)
            selected_audit = get_audit_by_id(selected_audit_id)
            if selected_audit:
                selected_summary = selected_audit.get("plant_summary", {})
                st.markdown(
                    f"**{selected_summary.get('plant_name', '-')}**  |  "
                    f"สถานะ: `{selected_summary.get('overall_status', '-')}`  |  "
                    f"Active Power: `{selected_summary.get('active_power_kw') or '-'}` kW"
                )
                st.info(selected_audit.get("executive_summary", ""))
                for finding in selected_audit.get("evidence_findings", []):
                    with st.expander(f"{finding.get('severity', '')} | {finding.get('category', '')}"):
                        st.write(finding.get("observed_data", ""))
                        st.caption(finding.get("engineering_diagnosis", ""))
                docx_path = selected_audit.get("analysis_metadata", {}).get("docx_path", "")
                if docx_path and os.path.isfile(docx_path):
                    with open(docx_path, "rb") as report_file:
                        st.download_button(
                            "📥 ดาวน์โหลดรายงานย้อนหลัง (.docx)",
                            data=report_file.read(),
                            file_name=os.path.basename(docx_path),
                            mime="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
                            key=f"download_{selected_audit_id}",
                        )
                else:
                    st.warning("ไม่พบไฟล์ DOCX ของ Audit นี้ในโฟลเดอร์ reports")
    else:
        st.info("ยังไม่มีรายงานที่อนุมัติและบันทึกไว้ในคลังประวัติ")

    conn = get_connection()
    cursor = conn.cursor()

    col_db1, col_db2 = st.columns(2)
    with col_db1:
        st.subheader("🏢 ไซต์งานที่ลงทะเบียนในระบบ")
        plants = cursor.execute("SELECT * FROM plants WHERE approved_at IS NOT NULL ORDER BY id DESC").fetchall()
        for p in plants:
            with st.expander(f"📍 {p['name']} ({p['capacity_kwp']})"):
                st.write(f"• **สถานที่:** {p['location']}")
                st.write(f"• **อุปกรณ์:** {p['inverter_info']}")
                reps = cursor.execute("SELECT report_date, report_type, summary_text FROM reports WHERE plant_id = ? AND approved_at IS NOT NULL", (p["id"],)).fetchall()
                if reps:
                    st.write("**ประวัติการตรวจเช็คที่ผ่านมา:**")
                    for r in reps:
                        st.caption(f"- [{r['report_date']}] {r['report_type']}: {r['summary_text']}")

    with col_db2:
        st.subheader("🛠️ คลังเคสปัญหาและวิธีแก้ไขมาตรฐาน")
        incidents = cursor.execute("""
        SELECT p.name as plant_name, c.category, c.equipment, c.alarm_or_finding, c.root_cause, c.verified_solution, c.parts_used
        FROM incident_cases c
        JOIN plants p ON c.plant_id = p.id
        WHERE c.approved_at IS NOT NULL AND p.approved_at IS NOT NULL
        ORDER BY c.id DESC
        """).fetchall()
        
        for inc in incidents:
            with st.expander(f"⚠️ {inc['alarm_or_finding']} ({inc['plant_name']})"):
                st.write(f"• **หมวดหมู่:** {inc['category']}")
                st.write(f"• **อุปกรณ์:** {inc['equipment']}")
                st.write(f"• **สาเหตุที่พิสูจน์แล้ว:** {inc['root_cause']}")
                st.write(f"• **วิธีแก้ไขมาตรฐาน:** {inc['verified_solution']}")
                st.write(f"• **อะไหล่ที่ใช้:** {inc['parts_used']}")

    conn.close()
PYEOF

cat > router.py << 'PYEOF'
import hashlib
import uuid
from datetime import datetime, timezone

from core.csv_reader import read_inverter_timeseries_csv
from core.docx_generator import build_docx
from core.evidence_validator import coerce_float, validate_evidence_coverage, validate_report
from core.job_manifest import build_manifest, manifest_summary
from core.reference_reader import extract_reference_context
from core.threshold_rules import (
    apply_measurement_thresholds,
    apply_peer_comparison,
    derive_plant_totals,
    detect_cross_source_conflicts,
    fill_default_diagnosis,
    finalize_overall_status,
    initialize_finding_defaults,
    reconcile_narrative_with_findings,
)
from database.db_manager import get_plant_history_context, get_previous_audit_kpis, get_similar_cases_context
from engines.master_engine import run_extraction, run_narrative_writing
from engines.verification_engine import run_critical_verification

PROMPT_VERSION = "2026-09-05-master-v6-extract-analyze-narrate"
REPORT_SCHEMA_VERSION = "2.1"
MAX_COVERAGE_RETRIES = 2


def run_master_analysis_with_coverage_check(generate_fn, expected_filenames: list):
    """generate_fn: no-arg callable returning a fresh report dict (a closure
    over the real run_master_analysis call in production). Kept injectable
    so this retry logic is unit-testable without hitting the real API.

    Retries up to MAX_COVERAGE_RETRIES times if the LLM merges several
    separately-uploaded files into one evidence_finding row, or silently
    drops one — both are ways real information gets lost (e.g. a healthy
    inverter's reading getting absorbed into a degraded neighbor's row).
    Raises rather than silently shipping a report that failed every retry —
    matches evidence_validator.validate_report's 'reject instead of
    inventing fallback' rule."""
    problems = []
    report = None
    for _ in range(MAX_COVERAGE_RETRIES):
        report = generate_fn()
        problems = validate_evidence_coverage(report.get("evidence_findings", []), expected_filenames)
        if not problems:
            return report
    raise ValueError(
        f"AI ไม่สามารถวิเคราะห์ครบทุกไฟล์แยกรายการได้แม้ลองใหม่ {MAX_COVERAGE_RETRIES} ครั้ง: "
        + "; ".join(problems)
    )


def _file_sha256(file) -> str:
    try:
        position = file.tell()
        file.seek(0)
        digest = hashlib.sha256(file.read()).hexdigest()
        file.seek(position)
        return digest
    except (AttributeError, OSError):
        return "unavailable"


def build_job_cache_key(uploaded_files, api_key: str = "", plant_name: str = "", lang: str = "th", *args, **kwargs) -> str:
    digest = hashlib.sha256(hashlib.sha256((api_key or "").encode()).digest())
    digest.update(PROMPT_VERSION.encode("ascii"))
    digest.update(f"{plant_name}|{lang}".encode("utf-8"))
    for file in uploaded_files:
        digest.update(str(getattr(file, "name", "")).encode())
        digest.update(_file_sha256(file).encode())
    return digest.hexdigest()


def _plant_name(manifest):
    sites = {item.get("site") for item in manifest if item.get("site")}
    return next(iter(sites), "Unknown Site") if len(sites) == 1 else "Unknown Site"


NEGATION_MARKERS = (
    "ไม่พบ", "ไม่มี", "ไม่เกิด", "ไม่ปรากฏ", "ปราศจาก",
    "no ", "not ", "without", "free of", "no evidence of",
)


def _keyword_present_unnegated(text: str, keyword: str, window: int = 30) -> bool:
    """True if `keyword` appears in `text` (case-insensitive) at least once
    WITHOUT a negation word in the `window` characters right before it.
    Guards against text like 'ไม่พบภาวะกราวด์ฟอลต์ (Ground Fault)' — literally
    'no ground fault found' — being read as a positive hit on 'ground fault'
    just because the phrase appears somewhere in the sentence."""
    text_lower = text.lower()
    keyword_lower = keyword.lower()
    start = 0
    while True:
        idx = text_lower.find(keyword_lower, start)
        if idx == -1:
            return False
        preceding = text_lower[max(0, idx - window):idx]
        if not any(neg in preceding for neg in NEGATION_MARKERS):
            return True
        start = idx + len(keyword_lower)


def _enforce_engineering_rules(report: dict) -> tuple:
    summary = report.get("plant_summary", {})
    p_act_raw = coerce_float(summary.get("active_power_kw"))
    p_rated_raw = coerce_float(summary.get("rated_capacity_kw"))
    i_grid_raw = coerce_float(summary.get("grid_current_a"))
    # `or 0.0` below is only for the arithmetic once we've already confirmed
    # (in the Rule 1 condition) that these aren't None — an UNCONFIRMED/
    # unparseable reading must never be silently read as a confirmed zero,
    # or "we don't know the output" gets treated as "output is zero" and
    # forces a false CRITICAL on an otherwise healthy plant.
    p_act = p_act_raw or 0.0
    p_rated = p_rated_raw or 0.0
    i_grid = i_grid_raw or 0.0

    findings_text = " ".join([
        f"{f.get('observed_data', '')} {f.get('engineering_diagnosis', '')}"
        for f in report.get("evidence_findings", []) if isinstance(f, dict)
    ]).lower()

    hard_locked = False
    # Rule 1: Zero Grid Current or severe power drop (<5%) -> Lock to CRITICAL
    values_confirmed = p_act_raw is not None and p_rated_raw is not None and i_grid_raw is not None
    if (values_confirmed and p_rated > 0 and (p_act / p_rated) < 0.05 and i_grid == 0) or "grid a/b/c phase current: 0" in findings_text or "grid current: 0" in findings_text or "grid current เป็น 0" in findings_text:
        summary["overall_status"] = "CRITICAL"
        hard_locked = True
    # Rule 2: Active Ground Fault / Short Circuit / Major Alarms -> Lock to CRITICAL
    elif any(
        _keyword_present_unnegated(findings_text, k)
        for k in ["ground fault", "short circuit", "insulation fault", "major alarm", "ลัดวงจรลงดิน", "รั่วลงดิน"]
    ):
        summary["overall_status"] = "CRITICAL"
        hard_locked = True
    # Rule 3: Confirmed normal operation with 0 alarms
    elif summary.get("overall_status") == "NORMAL" and ("0 alarm" in findings_text or "ไม่มีความผิดปกติ" in findings_text):
        summary["overall_status"] = "NORMAL"

    report["plant_summary"] = summary
    return report, hard_locked


def _compute_trend(report: dict, plant_name: str) -> dict | None:
    """เทียบตัวเลข KPI รอบนี้กับรอบก่อนหน้าด้วยโค้ดล้วนๆ ไม่ให้ LLM เดาแนวโน้มเอง"""
    previous = get_previous_audit_kpis(plant_name)
    if not previous:
        return None
    summary = report.get("plant_summary", {})
    curr_power = summary.get("active_power_kw_num")
    prev_power = coerce_float(previous.get("active_power_kw"))
    curr_current = summary.get("grid_current_a_num")
    prev_current = coerce_float(previous.get("grid_current_a"))

    def _pct_delta(curr, prev):
        if curr is None or prev is None or prev == 0:
            return None
        return round((curr - prev) / prev * 100, 1)

    power_delta = _pct_delta(curr_power, prev_power)
    current_delta = _pct_delta(curr_current, prev_current)
    if power_delta is None and current_delta is None:
        return None
    return {
        "previous_audit_date": previous.get("audit_date"),
        "previous_status": previous.get("status"),
        "active_power_delta_pct": power_delta,
        "grid_current_delta_pct": current_delta,
    }


def process_field_report(uploaded_files, api_key: str, plant_name: str = "", lang: str = "th") -> tuple:
    requested_plant = plant_name.strip()
    manifest = build_manifest(uploaded_files)
    for index, item in enumerate(manifest):
        item["sha256"] = _file_sha256(uploaded_files[index])
    detected_plant = _plant_name(manifest)
    context_plant = requested_plant if len(requested_plant) > 2 else detected_plant
    report_type = "MIXED_REPORT" if len({item["evidence_type"] for item in manifest}) > 1 else "MASTER_REPORT"
    site_context = get_plant_history_context(context_plant, report_type)
    reference_context, references = extract_reference_context(uploaded_files)
    knowledge_context = get_similar_cases_context([context_plant], report_type, context_plant)

    # --- CSV time-series logs are parsed deterministically in Python, not
    # sent to Gemini at all: a full day of 5-minute readings is exact
    # arithmetic (uptime, per-string comparison, yield delta), not something
    # to have an LLM re-derive from raw text at real token cost and with the
    # same reliability problem this whole system exists to remove. ---
    csv_indices = [i for i, item in enumerate(manifest) if item["filename"].lower().endswith(".csv")]
    csv_findings = []
    for i in csv_indices:
        file_obj, filename = uploaded_files[i], manifest[i]["filename"]
        try:
            raw = file_obj.read()
            file_obj.seek(0)
            csv_findings.append(read_inverter_timeseries_csv(raw, filename))
        except Exception as error:
            csv_findings.append({
                "category": "Inverter & Monitoring",
                "source_file": filename,
                "observed_data": "ไม่สามารถแปลผลไฟล์ CSV นี้ได้อัตโนมัติ กรุณาตรวจสอบด้วยตนเอง",
                "severity": "INFORMATIONAL",
                "engineering_diagnosis": f"รูปแบบไฟล์ไม่ตรงกับที่ตัวแปลผลอัตโนมัติรองรับในขณะนี้: {error}",
                "key_measurements": [],
            })
    non_csv_files = [f for i, f in enumerate(uploaded_files) if i not in csv_indices]
    expected_filenames = [item["filename"] for i, item in enumerate(manifest) if i not in csv_indices]

    report = run_master_analysis_with_coverage_check(
        lambda: run_extraction(non_csv_files, api_key, site_context, knowledge_context + reference_context, lang=lang, plant_name=context_plant or None),
        expected_filenames,
    )
    report.setdefault("evidence_findings", [])
    report["evidence_findings"].extend(csv_findings)

    # --- Stage 2: deterministic engineering analysis (pure code, no LLM) ---
    # Severity is decided ENTIRELY in this block now. run_extraction() above
    # produces no severity/overall_status at all, so there is no LLM guess
    # to override here — only rules.
    report = initialize_finding_defaults(report)
    report = derive_plant_totals(report)
    report, status_hard_locked = _enforce_engineering_rules(report)
    report, measurement_locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    report = detect_cross_source_conflicts(report)
    report = fill_default_diagnosis(report)
    report = finalize_overall_status(report)
    status_hard_locked = status_hard_locked or measurement_locked

    # --- Stage 3: narrative writing (LLM #2, text-only — no images resent,
    # no path for the model to re-judge severity from a photo a second time) ---
    narrative = run_narrative_writing(report, api_key, lang=lang)
    for key in ("executive_summary", "inaction_damage_matrix", "root_causes", "corrective_actions", "spare_parts_tools"):
        if key in narrative:
            report[key] = narrative[key]
    report = reconcile_narrative_with_findings(report)  # safety net, not the primary mechanism anymore
    report = validate_report(report)
    if report.get("plant_summary", {}).get("overall_status") == "CRITICAL" and not status_hard_locked:
        report = run_critical_verification(uploaded_files, report, api_key)
    trend = _compute_trend(report, context_plant)
    if trend:
        report["trend_analysis"] = trend
    report["input_files"] = [str(getattr(file, "name", "unknown")) for file in uploaded_files]
    report["evidence_manifest"] = manifest
    report["reference_documents"] = references
    report["analysis_metadata"] = {
        "audit_id": str(uuid.uuid4()),
        "schema_version": REPORT_SCHEMA_VERSION,
        "prompt_version": PROMPT_VERSION,
        "generated_at_utc": datetime.now(timezone.utc).isoformat(),
        "evidence_count": len(manifest),
        "evidence_summary": manifest_summary(manifest),
    }
    if len(requested_plant) > 2:
        selected_plant = requested_plant
    else:
        selected_plant = report.get("plant_summary", {}).get("plant_name") or detected_plant or "Unknown Site"
    report["plant_summary"]["plant_name"] = selected_plant
    report["language"] = lang if lang in {"th", "en"} else "th"
    document = build_docx(report, uploaded_files)
    return report, document, report_type, site_context
PYEOF

cat > core/threshold_rules.py << 'PYEOF'
"""
Deterministic measurement-threshold rules.

Why this file exists: severity used to be decided entirely by the LLM inside
one JSON call (engines/master_engine.py). Two runs on the exact same
Insulation Resistance reading (0.836 MOhm) came back NORMAL once and WARNING
once, because nothing in code ever checked the number itself. This module
fixes that class of bug for measured, numeric values.

Two sources of truth, in priority order:
  1. `key_measurements` — a structured list the prompt now requires on every
     evidence_finding (parameter/value/unit/comparator). This is the reliable
     path: a fixed vocabulary of parameter names, not prose the model phrases
     differently every run.
  2. Regex against observed_data/engineering_diagnosis text — kept as a
     fallback ONLY, for evidence that predates key_measurements or a run
     where the model still forgot to populate it. Never trusted over
     structured data when both are present.

Design goal (token/maintenance cost): a NEW failure mode that is expressed as
"a named quantity crossed a known numeric line" should only require adding one
entry to MEASUREMENT_RULES below — no prompt edits, no router changes, no new
functions. Only genuinely new *kinds* of check (e.g. cross-source conflicts,
which aren't a single threshold) need new code, and that already lives here
too (see `detect_cross_source_conflicts`).

Severity is only ever UPGRADED by these rules, never downgraded — an LLM call
that already flagged something worse is left alone; a rule only steps in when
the LLM under-called a measured value that crosses a known safety line.

What this file deliberately does NOT derive, and why (engineering/physics,
not just missing code):
  - grid_current_a at plant level: individual inverters are not guaranteed to
    be on the same phase, feeder, or measurement point, so their reported
    currents do not simply add into one meaningful "grid current" figure
    without knowing the actual electrical topology. Guessing here would be
    fabricating a number that looks precise but isn't physically justified.
  - rated_capacity_kw: this is a static nameplate/design value from site
    metadata, not something visible in a field photo to re-derive. If it's
    UNCONFIRMED, the fix is ensuring the site metadata reaches the prompt,
    not inventing a number from evidence that was never going to contain it.
  Active power IS safe to sum: real power delivered by parallel sources onto
  a common connection point is additive by basic conservation of energy,
  regardless of phase relationships — that's why only active_power_kw gets
  an automatic total below.
"""

import re

from core.peer_comparison import compare_to_peers

SEVERITY_RANK = {"NORMAL": 0, "INFORMATIONAL": 0, "WARNING": 1, "CRITICAL": 2}


def _higher(a: str, b: str) -> str:
    return a if SEVERITY_RANK.get(a, 0) >= SEVERITY_RANK.get(b, 0) else b


# --- Shared: which single inverter (if any) does this piece of evidence
# represent? A live monitoring dashboard screenshot names exactly one unit
# ("Inv_2.jpg"). A batch test sheet covering several units at once names a
# range ("DC_Inv_1-2.jpg", "AC_Inv_1-6.jpg") — that's a different kind of
# evidence (one aggregate test result, not one unit's live reading), even
# when the LLM happens to file both under the same category. Functions that
# need "one specific unit's own reading" (peer comparison, summing
# per-inverter totals) must use `_single_inverter_id`, not just filter by
# category, or a batch test's number silently gets treated as if it came
# from a single live unit.
_INVERTER_RANGE = re.compile(r"inv[_-]?(\d+)\s*-\s*(\d+)", re.IGNORECASE)
_INVERTER_SINGLE = re.compile(r"inv[_-]?(\d+)(?!\s*-)", re.IGNORECASE)


def _inverter_ids(source_file: str):
    range_match = _INVERTER_RANGE.search(source_file)
    if range_match:
        start, end = int(range_match.group(1)), int(range_match.group(2))
        return list(range(start, end + 1))
    single_match = _INVERTER_SINGLE.search(source_file)
    if single_match:
        return [int(single_match.group(1))]
    return []


def _single_inverter_id(source_file: str):
    """Returns the inverter id only when the filename names exactly ONE
    unit; returns None for a batch/range file (or no id at all) — the
    caller should then treat this finding as not representing a single
    unit's own live reading."""
    ids = _inverter_ids(source_file)
    return ids[0] if len(ids) == 1 else None


def _structured_lookup(finding: dict, parameter_names: set):
    """Look up a numeric reading from the finding's structured
    key_measurements list. Returns (value, comparator) or (None, None)."""
    for measurement in finding.get("key_measurements") or []:
        if not isinstance(measurement, dict):
            continue
        name = str(measurement.get("parameter", "")).strip().lower()
        if name not in parameter_names:
            continue
        value = measurement.get("value")
        if value is None:
            continue
        try:
            return float(value), measurement.get("comparator", "=") or "="
        except (TypeError, ValueError):
            continue
    return None, None


# --- Table of deterministic rules --------------------------------------
# Each rule first looks for `structured_names` in key_measurements; if not
# found there, falls back to `label_pattern` + `value_pattern` against the
# finding's text. `applies_to_category` restricts which evidence_findings
# rows the rule scans, so a rule for a monitoring reading doesn't misfire on
# a paper Megger row using the same word.
MEASUREMENT_RULES = [
    {
        "name": "insulation_resistance_live",
        "applies_to_category": "Inverter & Monitoring",
        "structured_names": {"insulation_resistance_mohm"},
        "label_pattern": re.compile(
            r"insulation\s*resistance|ค่าฉนวน|ความต้านทานฉนวน|\briso\b",
            re.IGNORECASE,
        ),
        "value_pattern": re.compile(r"(>|<)?\s*([\d.]+)\s*(?:m\W?ohm|m\W?\u03a9|megaohm)", re.IGNORECASE),
        # (comparator, limit, severity) — value compared against limit.
        "thresholds": [("<", 0.5, "CRITICAL"), ("<", 1.0, "WARNING")],
        # For peer comparison: a smaller insulation-resistance reading is the
        # concerning direction.
        "bad_direction": "low",
    },
]


def _extract_value(text: str, value_pattern):
    match = value_pattern.search(text)
    if not match:
        return None, None
    sign, raw = match.group(1), match.group(2)
    try:
        value = float(raw)
    except (TypeError, ValueError):
        return None, None
    return value, sign


def _reading_for_rule(finding: dict, rule: dict):
    """Structured key_measurements first; text regex only as a fallback."""
    value, sign = _structured_lookup(finding, rule["structured_names"])
    if value is not None:
        return value, sign
    text = f"{finding.get('observed_data', '')} {finding.get('engineering_diagnosis', '')}"
    if not rule["label_pattern"].search(text):
        return None, None
    return _extract_value(text, rule["value_pattern"])


def _rule_severity(value: float, sign, thresholds):
    # A ">1000" reading is a lower bound (true value is at least this high);
    # a "<X" reading is an upper bound (true value could be far below X, so
    # evaluate conservatively against X itself). Either way, comparing the
    # captured number against the threshold table below is the correct,
    # physically-honest check for both cases.
    for comparator, limit, severity in thresholds:
        if comparator == "<" and value < limit:
            return severity
    return None


def apply_measurement_thresholds(report: dict) -> tuple:
    """Scan evidence_findings for known measured quantities and force severity
    to at least what the number itself requires. Mutates report in place.
    Returns (report, escalated_to_critical: bool) — escalated_to_critical tells
    the caller this CRITICAL came from a number crossing a known line, not an
    LLM judgment call, so it should be treated like the router's other
    hard-coded rules (ground truth, skip the verification pass)."""
    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report, False

    escalated_any = False
    for finding in findings:
        if not isinstance(finding, dict):
            continue
        for rule in MEASUREMENT_RULES:
            if finding.get("category") != rule["applies_to_category"]:
                continue
            value, sign = _reading_for_rule(finding, rule)
            if value is None:
                continue
            rule_severity = _rule_severity(value, sign, rule["thresholds"])
            if not rule_severity:
                continue
            current = finding.get("severity", "NORMAL")
            new_severity = _higher(current, rule_severity)
            if new_severity != current:
                finding["severity"] = new_severity
                finding["corroboration"] = "threshold_only"  # refined by apply_peer_comparison, if it runs
                finding["engineering_diagnosis"] = (
                    finding.get("engineering_diagnosis", "").rstrip()
                    + f" [กฎอัตโนมัติ: {rule['name']} วัดได้ {value} MOhm ต่ำกว่าเกณฑ์ปลอดภัย บังคับ severity เป็น {new_severity}]"
                )
                escalated_any = True

    escalated_to_critical = False
    if escalated_any:
        summary = report.get("plant_summary", {})
        worst = "NORMAL"
        for finding in findings:
            if isinstance(finding, dict):
                worst = _higher(worst, finding.get("severity", "NORMAL"))
        new_status = _higher(summary.get("overall_status", "NORMAL"), worst)
        escalated_to_critical = new_status == "CRITICAL" and summary.get("overall_status") != "CRITICAL"
        summary["overall_status"] = new_status
        report["plant_summary"] = summary

    return report, escalated_to_critical


# --- Peer comparison: corroborate or honestly qualify threshold escalations --
# apply_measurement_thresholds tags a finding "threshold_only" when the raw
# number alone crossed a line borrowed from a general standard (e.g. IEC
# 62446-1 Megger limits) that may not actually be the right limit for THIS
# equipment's live self-monitoring reading (see core/peer_comparison.py
# docstring for the full reasoning). This function runs after it and either:
#   - corroborates the escalation with real evidence (this unit performs far
#     worse than its peers under identical conditions right now), or
#   - honestly downgrades the CERTAINTY of the wording (not the severity —
#     severity stays elevated, so a real problem is never silently dropped
#     back to NORMAL) when no peer or reference data backs up the number.

def apply_peer_comparison(report: dict) -> dict:
    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report

    for rule in MEASUREMENT_RULES:
        bad_direction = rule.get("bad_direction")
        if not bad_direction:
            continue

        category_findings = [
            f for f in findings
            if isinstance(f, dict) and f.get("category") == rule["applies_to_category"]
        ]
        readings = []
        for idx, finding in enumerate(category_findings):
            if _single_inverter_id(str(finding.get("source_file", ""))) is None:
                # Not a single unit's own reading (either a multi-unit batch
                # test file, or no inverter id in the filename at all) — not
                # a valid peer for comparing individual units against each
                # other.
                continue
            value, sign = _reading_for_rule(finding, rule)
            if value is None:
                continue
            if sign not in ("=", None):
                # An inequality reading (">500", "<0.5") is a compliance bound
                # from a different measurement method (e.g. a Megger-style
                # test), not a directly comparable live reading. Kept as a
                # second guard even with the single-unit-id filter above,
                # since a mislabeled single-id file could still carry one.
                continue
            readings.append({"id": idx, "value": value, "finding": finding})

        peer_results = compare_to_peers(
            [{"id": r["id"], "value": r["value"]} for r in readings],
            bad_direction=bad_direction,
        )
        outlier_ids = {r["id"] for r in peer_results if r["is_outlier"]}
        peer_result_by_id = {r["id"]: r for r in peer_results}

        for r in readings:
            finding = r["finding"]
            if finding.get("corroboration") != "threshold_only":
                continue  # not an escalation from this rule, leave untouched
            if r["id"] in outlier_ids:
                pr = peer_result_by_id[r["id"]]
                finding["corroboration"] = f"peer_deviation:{pr['deviation_pct']}pct_below_best_peer"
                finding["engineering_diagnosis"] = (
                    finding.get("engineering_diagnosis", "").rstrip()
                    + f" [ยืนยันเพิ่มเติม: เบี่ยงเบนจากเครื่องเพื่อนร่วมชุดตรวจที่ดีที่สุด ({pr['baseline']} MOhm) อยู่ {pr['deviation_pct']}% "
                    "ซึ่งสูงกว่าค่าความแปรปรวนปกติของเครื่องรุ่นเดียวกันภายใต้เงื่อนไขเดียวกันอย่างมีนัยสำคัญ]"
                )
            else:
                finding["corroboration"] = "threshold_only_unverified"
                finding["engineering_diagnosis"] = (
                    finding.get("engineering_diagnosis", "").rstrip()
                    + " [หมายเหตุ: ยังไม่มีข้อมูลอ้างอิงเฉพาะรุ่นอุปกรณ์นี้ และไม่พบการเบี่ยงเบนจากเครื่องเพื่อนร่วมชุดตรวจอย่างมีนัยสำคัญ "
                    "ผลประเมินนี้อิงเกณฑ์ทั่วไปเบื้องต้นเท่านั้น แนะนำให้ตรวจสอบหน้างานเพื่อยืนยันก่อนสรุปเป็นข้อบกพร่องที่ยืนยันแล้ว]"
                )

    return report



# Not a single-number threshold, so it earns its own function rather than a
# MEASUREMENT_RULES entry — but it's still fully deterministic (no LLM call).

_RISO_VALUE = re.compile(r"(>|<)?\s*([\d.]+)\s*(?:m\W?ohm|m\W?\u03a9)", re.IGNORECASE)
_RISO_NAMES = {"insulation_resistance_mohm"}


def _riso_reading(finding: dict):
    value, sign = _structured_lookup(finding, _RISO_NAMES)
    if value is not None:
        return value, sign
    text = f"{finding.get('observed_data', '')} {finding.get('engineering_diagnosis', '')}"
    return _extract_value(text, _RISO_VALUE)


def detect_cross_source_conflicts(report: dict) -> dict:
    """Flag when a paper/Megger insulation reading and a live monitoring
    insulation reading disagree for the same inverter, instead of silently
    trusting whichever source the model happened to weight more."""
    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report

    monitor_readings = {}   # inverter_id -> (value, sign, source_file)
    paper_readings = {}     # inverter_id -> (value, sign, source_file)

    for finding in findings:
        if not isinstance(finding, dict):
            continue
        source_file = str(finding.get("source_file", ""))
        value, sign = _riso_reading(finding)
        if value is None:
            continue
        ids = _inverter_ids(source_file)
        if not ids:
            continue
        bucket = monitor_readings if finding.get("category") == "Inverter & Monitoring" else (
            paper_readings if finding.get("category") == "String Electrical" else None
        )
        if bucket is None:
            continue
        for inv_id in ids:
            bucket[inv_id] = (value, sign, source_file)

    conflicts = []
    for inv_id, (m_value, m_sign, m_file) in monitor_readings.items():
        if inv_id not in paper_readings:
            continue
        p_value, p_sign, p_file = paper_readings[inv_id]
        monitor_low = m_sign != ">" and m_value < 1.0
        paper_high = p_sign == ">" or p_value >= 100.0
        if monitor_low and paper_high:
            conflicts.append({
                "category": "Inverter & Monitoring",
                "source_file": f"{m_file} vs {p_file}",
                "observed_data": (
                    f"Inverter {inv_id}: ค่าจากหน้าจอ Monitoring (real-time) = {m_value} MOhm "
                    f"แต่ค่าจากใบทดสอบ Megger (isolated) = {p_sign or ''}{p_value} MOhm"
                ),
                "engineering_diagnosis": (
                    "ค่าทั้งสองแหล่งขัดแย้งกันสำหรับอุปกรณ์เดียวกัน — การวัดแบบ isolated (ตัดวงจร) "
                    "กับค่าที่รายงานระหว่างทำงานจริงต่างกันมาก จำเป็นต้องตรวจสอบซ้ำหน้างานก่อนสรุปสาเหตุ "
                    "[กฎอัตโนมัติ: cross_source_conflict]"
                ),
                "severity": "WARNING",
                "key_measurements": [],
            })

    if conflicts:
        report["evidence_findings"] = findings + conflicts
        summary = report.get("plant_summary", {})
        summary["overall_status"] = _higher(summary.get("overall_status", "NORMAL"), "WARNING")
        report["plant_summary"] = summary

    return report


# --- Deterministic recovery for plant-level totals -----------------------
# The LLM sometimes writes real per-inverter numbers but answers
# "UNCONFIRMED" for the plant-level total anyway (it has to correctly sum 6+
# separate readings in the same pass as everything else). Summing is a
# Python problem, not an LLM judgment call — do it deterministically
# whenever every per-item number is actually present. Only active_power_kw
# is summed here — see the module docstring for why grid_current_a and
# rated_capacity_kw are deliberately never auto-derived.

_ACTIVE_POWER_TEXT = re.compile(r"active\s*power[:\s]*([\d.]+)\s*kw", re.IGNORECASE)
_ACTIVE_POWER_NAMES = {"active_power_kw"}
_UNRESOLVED_VALUES = {None, "", "unconfirmed", "n/a", "null"}


def _active_power_reading(finding: dict):
    value, _ = _structured_lookup(finding, _ACTIVE_POWER_NAMES)
    if value is not None:
        return value
    text = f"{finding.get('observed_data', '')} {finding.get('engineering_diagnosis', '')}"
    match = _ACTIVE_POWER_TEXT.search(text)
    return float(match.group(1)) if match else None


def derive_plant_totals(report: dict) -> dict:
    summary = report.get("plant_summary", {})
    current = summary.get("active_power_kw")
    current_str = str(current).strip().lower() if current is not None else ""
    if current_str not in _UNRESOLVED_VALUES:
        return report  # Gemini already gave a usable number — don't second-guess it

    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report

    inverter_findings = [
        f for f in findings
        if isinstance(f, dict) and f.get("category") == "Inverter & Monitoring"
        and _single_inverter_id(str(f.get("source_file", ""))) is not None
    ]
    per_inverter_kw = [_active_power_reading(f) for f in inverter_findings]

    # Only fill in the total when every inverter reading is present — a
    # partial sum (e.g. 4 of 6 units) would silently understate output,
    # which is worse than honestly leaving it UNCONFIRMED.
    if per_inverter_kw and all(v is not None for v in per_inverter_kw):
        summary["active_power_kw"] = str(round(sum(per_inverter_kw), 3))
        report["plant_summary"] = summary

    return report


# --- Narrative/data consistency guard -------------------------------------
# apply_measurement_thresholds, apply_peer_comparison, and
# detect_cross_source_conflicts only ever touch evidence_findings and
# plant_summary. But executive_summary, root_causes, and corrective_actions
# are written by the LLM in the SAME call as evidence_findings, based on
# ITS OWN (pre-escalation) judgment — if the LLM decided everything was
# NORMAL, those sections say so in full prose, and nothing above ever goes
# back to update them once a rule forces a finding to WARNING/CRITICAL
# afterward. The result: a report whose header says WARNING while the
# executive summary confidently says "no abnormality found," and whose root
# causes / corrective actions sections are empty or generic "all clear" —
# which is precisely the kind of internally-contradictory, untrustworthy
# report this whole effort exists to prevent.
#
# This function does NOT try to fabricate the missing engineering analysis
# itself (writing a plausible-sounding root cause/corrective action without
# being sure it's right would just be a different flavor of the same
# problem). It only guarantees the report can never claim "all clear" while
# escalated findings exist elsewhere in it — by adding an unmissable,
# factual pointer back to the findings that a human still needs to act on.

def reconcile_narrative_with_findings(report: dict) -> dict:
    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report

    escalated = [
        f for f in findings
        if isinstance(f, dict) and f.get("severity") in ("WARNING", "CRITICAL")
    ]
    if not escalated:
        return report

    escalated_files = ", ".join(sorted({str(f.get("source_file", "")) for f in escalated}))
    banner = (
        f"[หมายเหตุจากระบบตรวจสอบอัตโนมัติ: มี {len(escalated)} รายการที่ถูกยกระดับเป็น WARNING/CRITICAL "
        f"โดยกฎวิศวกรรมอัตโนมัติ ({escalated_files}) กรุณาอ่านหัวข้อผลการตรวจสอบ (ข้อ 3) โดยละเอียด "
        "ก่อนสรุปว่าระบบไม่มีความผิดปกติ — บทสรุปด้านล่างนี้อาจเขียนขึ้นก่อนการยกระดับดังกล่าว]\n\n"
    )
    summary_text = report.get("executive_summary", "") or ""
    if "หมายเหตุจากระบบตรวจสอบอัตโนมัติ" not in summary_text:
        report["executive_summary"] = banner + summary_text

    root_causes = report.get("root_causes", [])
    if not isinstance(root_causes, list):
        root_causes = []
    covered_files = {str(rc.get("supporting_evidence", "")) for rc in root_causes if isinstance(rc, dict)}
    for f in escalated:
        source_file = str(f.get("source_file", ""))
        if any(source_file in c for c in covered_files):
            continue
        root_causes.append({
            "issue": f"{f.get('category', '')} — {source_file} (severity: {f.get('severity')})",
            "description": (
                f.get("engineering_diagnosis", "")
                or "ยกระดับโดยกฎวิศวกรรมอัตโนมัติ ยังไม่มีคำอธิบายเชิงวิเคราะห์จาก AI ระบุไว้ในรอบนี้ "
                   "ต้องตรวจสอบข้อมูลในหัวข้อผลการตรวจสอบเพิ่มเติมก่อนสรุปสาเหตุ"
            ),
            "supporting_evidence": source_file,
        })
    report["root_causes"] = root_causes

    corrective_actions = report.get("corrective_actions", [])
    if not isinstance(corrective_actions, list):
        corrective_actions = []
    has_followup_action = any(
        isinstance(a, dict) and any(f.get("source_file", "") in " ".join(a.get("actions", [])) for f in escalated)
        for a in corrective_actions
    )
    if not has_followup_action:
        next_step_number = max([a.get("step_number", 0) for a in corrective_actions if isinstance(a, dict)], default=0) + 1
        corrective_actions.append({
            "step_number": next_step_number,
            "title": "ตรวจสอบซ้ำหน้างานสำหรับรายการที่ถูกยกระดับโดยระบบอัตโนมัติ",
            "actions": [
                f"ตรวจสอบซ้ำหน้างาน: {escalated_files}",
                "ยืนยันสาเหตุและความรุนแรงจริงก่อนวางแผนซ่อมบำรุงหรือปิดเคส",
            ],
        })
    report["corrective_actions"] = corrective_actions

    return report


# --- Pipeline-stage helpers for the extraction/analysis/narrative split ---
# These three functions are what actually let severity be a code-only
# decision now, instead of "the LLM guesses, and code sometimes overrides
# it." run_extraction() (engines/master_engine.py) no longer produces a
# severity or overall_status field at all — these fill in the code-owned
# defaults, then everything above (apply_measurement_thresholds,
# apply_peer_comparison, detect_cross_source_conflicts, _enforce_engineering_
# rules) does the actual judging, then these close out what's left.

_DEFAULT_DIAGNOSIS = (
    "อ่านค่าตามที่ปรากฏในหลักฐาน ไม่มีกฎตรวจสอบอัตโนมัติที่ระบุความผิดปกติสำหรับพารามิเตอร์นี้ "
    "(หมายเหตุ: นี่ไม่ใช่การยืนยันว่าปกติ 100% เพียงแต่ยังไม่มีเกณฑ์ตรวจสอบอัตโนมัติครอบคลุมค่านี้)"
)


def initialize_finding_defaults(report: dict) -> dict:
    """Run immediately after run_extraction(). The extraction stage no
    longer produces severity/engineering_diagnosis at all (that's the whole
    point), so every finding needs these code-owned fields to exist before
    any rule tries to read or upgrade them."""
    findings = report.get("evidence_findings", [])
    for f in findings:
        if isinstance(f, dict):
            f.setdefault("severity", "NORMAL")
            f.setdefault("engineering_diagnosis", "")
            f.setdefault("key_measurements", [])
    return report


def fill_default_diagnosis(report: dict) -> dict:
    """After every rule has had its chance to act, any finding still
    carrying an empty engineering_diagnosis never triggered a rule at all —
    say so honestly instead of leaving a blank cell in the report, and
    instead of letting the narrative-writing stage invent something to fill
    the gap."""
    for f in report.get("evidence_findings", []):
        if isinstance(f, dict) and not str(f.get("engineering_diagnosis", "")).strip():
            f["engineering_diagnosis"] = _DEFAULT_DIAGNOSIS
    return report


def finalize_overall_status(report: dict) -> dict:
    """overall_status is now ALWAYS derived from the findings themselves,
    never asserted independently by an LLM — this is what closes the bug
    where a report's header said CRITICAL while not one single finding was
    CRITICAL (there was nothing stopping an LLM from writing a plant-level
    status disconnected from its own per-item severities). A hard-locked
    status already set by _enforce_engineering_rules (e.g. confirmed zero
    grid current, which is a plant-level fact rather than any one photo's
    severity) is preserved via _higher — never downgraded, only ever
    matched or exceeded by the worst finding."""
    findings = report.get("evidence_findings", [])
    worst = "NORMAL"
    for f in findings:
        if isinstance(f, dict):
            worst = _higher(worst, f.get("severity", "NORMAL"))
    summary = report.get("plant_summary", {})
    summary["overall_status"] = _higher(summary.get("overall_status", "NORMAL"), worst)
    report["plant_summary"] = summary
    return report

PYEOF

cat > core/evidence_validator.py << 'PYEOF'
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

PYEOF

cat > core/peer_comparison.py << 'PYEOF'
"""
Directional peer comparison for measured values across equipment of the same
category, in the same evidence batch (same site visit).

WHY NOT median/MAD (the "textbook" outlier stat): I tried it first, by hand,
against the exact Global House Phitsanulok numbers before writing this file.
Insulation resistance readings were [Inv1: 20, Inv2: 0.836, Inv3: 0.867,
Inv4: 0.921, Inv5: 0.872, Inv6: 13.541] MOhm. Four of the six units read low
— so the median sits inside the LOW cluster, and a standard median/MAD
outlier test flags Inv1 and Inv6 (the two healthy units) as the "anomaly"
and leaves Inv2-5 (the actually degraded ones) alone. That is exactly
backwards, and it is precisely the kind of technically-correct-but-
engineering-wrong mistake this whole exercise is trying to eliminate.
Majority-vote statistics cannot tell you which direction is "bad" — only a
human (or a known physical direction of concern) can.

So instead: every parameter this module is used for must declare a
`bad_direction` ("low" or "high" — is a smaller or larger number the
concerning one). The comparison baseline is the BEST reading currently
observed among the peers (max, if low=bad; min, if high=bad) — i.e. "what
these units are demonstrably capable of reading right now, under today's
identical conditions." A unit is flagged when it falls meaningfully short of
that achievable baseline, regardless of whether it's in the majority or the
minority of the batch. This correctly flags Inv2-5 above (they're ~95%
below what Inv1 proves is achievable right now) and correctly leaves a
uniform "all six units read 70-90 degC" batch alone (nothing falls far
short of its peers' best, even though the absolute numbers might be high).
"""

MIN_PEERS = 4  # below this, "peer comparison" isn't statistically meaningful
DEFAULT_RELATIVE_THRESHOLD_PCT = 40.0


def compare_to_peers(readings: list, bad_direction: str, relative_threshold_pct: float = DEFAULT_RELATIVE_THRESHOLD_PCT, min_peers: int = MIN_PEERS) -> list:
    """
    readings: list of {"id": <anything>, "value": float}, all for the SAME
        parameter, SAME category, SAME evidence batch.
    bad_direction: "low" (smaller value = worse, e.g. insulation resistance)
        or "high" (larger value = worse, e.g. temperature).
    relative_threshold_pct: how far short of the best peer's reading (as a
        percentage of that reading) a unit must fall before it's flagged.
        Not an absolute engineering limit — a statement about this specific
        batch, right now: "meaningfully worse than what peers just proved is
        achievable under the same conditions."
    min_peers: fewer than this many comparable readings and peer comparison
        doesn't mean anything statistically — returns [] rather than forcing
        a comparison out of too little data.

    Returns a list of dicts (one per input reading, same order), each with
    the original keys plus: baseline, deviation_pct, is_outlier.
    Returns [] if len(readings) < min_peers.
    """
    if bad_direction not in ("low", "high"):
        raise ValueError("bad_direction must be 'low' or 'high'")
    if len(readings) < min_peers:
        return []

    values = [r["value"] for r in readings]
    baseline = max(values) if bad_direction == "low" else min(values)

    results = []
    for r in readings:
        value = r["value"]
        if baseline == 0:
            deviation_pct = 0.0
        elif bad_direction == "low":
            deviation_pct = max((baseline - value) / baseline * 100, 0.0)
        else:
            deviation_pct = max((value - baseline) / baseline * 100, 0.0)
        results.append({
            **r,
            "baseline": baseline,
            "deviation_pct": round(deviation_pct, 1),
            "is_outlier": deviation_pct >= relative_threshold_pct,
        })
    return results

PYEOF

cat > core/csv_reader.py << 'PYEOF'
"""
Time-series inverter/logger CSV reader.

Why this file exists: an inverter data-log export (e.g. a Huawei/FusionSolar
style "Inverter_..._INVERTER-01_....csv") is a full day of 5-minute-interval
readings — commonly 200-300 rows x 30+ columns. Sending that as raw text to
an LLM would be expensive AND would reintroduce exactly the "same input,
different answer" unreliability this whole system exists to eliminate for a
domain (arithmetic over a table) that Python does exactly and for free. So
this file does ALL the actual computation — min/max/mean, uptime/downtime,
per-string comparison — in plain Python, and produces a ready-made
evidence_finding with a human-readable Thai summary + structured
key_measurements. No Gemini call is needed for this file type at all.

Column layouts differ by logger brand/export settings ("บางทีแต่ละทีมีข้างใน
ไม่เหมือนกัน" — the exact concern this module is built to survive), so nothing
here assumes a fixed row number for the header or a fixed column order —
only that certain columns can be recognized by keyword in their names.
"""

import csv
import io
import re
import statistics
from datetime import datetime

from core.peer_comparison import compare_to_peers
from core.threshold_rules import _higher

# Keyword patterns used to recognize a column regardless of exact wording/
# unit formatting, since exports vary ("Active power(kW)" vs "Active Power
# (kW)" vs "有功功率(kW)", etc. — we match on the English keyword substrings
# actually seen across common exports; a column that matches none of these
# is simply not summarized, not guessed at).
_COLUMN_PATTERNS = {
    "timestamp": re.compile(r"start time|^time$|timestamp", re.IGNORECASE),
    "active_power": re.compile(r"active power", re.IGNORECASE),
    "status": re.compile(r"inverter status|^status$", re.IGNORECASE),
    "internal_temp": re.compile(r"internal temperature", re.IGNORECASE),
    "total_yield": re.compile(r"total yield", re.IGNORECASE),
    "grid_current": re.compile(r"grid current", re.IGNORECASE),
}
_PV_STRING_CURRENT = re.compile(r"pv\s*(\d+)\s*input current", re.IGNORECASE)

# Status text is free-form ("OFF : instructed shutdown", "Standby :  no
# sunlight", "Grid connected", "Grid connected : self derating") — bucket by
# keyword rather than exact string match, since wording varies by brand/fw.
_STATUS_BUCKETS = [
    ("off_commanded", re.compile(r"\boff\b.*shutdown|instructed shutdown", re.IGNORECASE)),
    ("standby_no_sun", re.compile(r"standby.*(no sun|no light)", re.IGNORECASE)),
    ("fault_alarm", re.compile(r"fault|alarm|error|trip", re.IGNORECASE)),
    ("derating", re.compile(r"derat", re.IGNORECASE)),
    ("producing", re.compile(r"grid connected", re.IGNORECASE)),
]


def _bucket_status(text: str) -> str:
    for bucket, pattern in _STATUS_BUCKETS:
        if pattern.search(text):
            return bucket
    return "other"


def _sniff_header_row(rows: list) -> int:
    """Find the real header row among leading metadata lines (export
    timestamps, legend text, etc.) by looking for a row that names actual
    measurement columns, rather than assuming a fixed row number."""
    for i, row in enumerate(rows[:30]):
        joined = ",".join(row).lower()
        if ("time" in joined) and any(k in joined for k in ("power", "voltage", "current", "yield", "temperature")):
            return i
    raise ValueError("ไม่พบแถวหัวตาราง (header) ที่จดจำได้ในไฟล์ CSV นี้ — รูปแบบไฟล์อาจไม่ตรงกับที่รองรับไว้")


def _to_float(value):
    if value is None:
        return None
    try:
        cleaned = value.strip()
        if not cleaned or cleaned.upper() in ("N/A", "-", "NA"):
            return None
        return float(cleaned)
    except (TypeError, ValueError, AttributeError):
        return None


def _parse_timestamp(value: str):
    for fmt in ("%Y-%m-%d %H:%M:%S", "%Y/%m/%d %H:%M:%S"):
        try:
            return datetime.strptime(value.strip(), fmt)
        except (ValueError, AttributeError):
            continue
    return None


def read_inverter_timeseries_csv(raw_bytes: bytes, source_file: str) -> dict:
    """Parse one inverter's day-log CSV and return a ready-made
    evidence_finding dict (category, source_file, observed_data,
    key_measurements). Raises ValueError with a Thai message if the file
    doesn't look like a recognizable inverter log at all — the caller
    should surface that as an UNCONFIRMED/needs-review note rather than
    silently dropping the file."""
    text = raw_bytes.decode("utf-8-sig", errors="ignore")
    all_rows = list(csv.reader(io.StringIO(text)))
    if not all_rows:
        raise ValueError("ไฟล์ CSV ว่างเปล่าหรืออ่านไม่ได้")

    header_idx = _sniff_header_row(all_rows)
    header = [h.strip() for h in all_rows[header_idx]]
    data_rows = [r for r in all_rows[header_idx + 1:] if any(cell.strip() for cell in r)]

    col_index = {}
    pv_string_cols = {}  # string number -> column index
    for i, name in enumerate(header):
        for key, pattern in _COLUMN_PATTERNS.items():
            if key not in col_index and pattern.search(name):
                col_index[key] = i
        pv_match = _PV_STRING_CURRENT.search(name)
        if pv_match:
            pv_string_cols[int(pv_match.group(1))] = i

    if "timestamp" not in col_index or not data_rows:
        raise ValueError("ไม่พบคอลัมน์เวลา หรือไม่มีข้อมูลแถวใดเลยในไฟล์ CSV นี้")

    def col(row, key):
        idx = col_index.get(key)
        return row[idx].strip() if idx is not None and idx < len(row) else None

    timestamps = [_parse_timestamp(col(r, "timestamp")) for r in data_rows]
    valid_rows = [(ts, r) for ts, r in zip(timestamps, data_rows) if ts is not None]
    if not valid_rows:
        raise ValueError("อ่านค่าเวลาจากไฟล์ CSV นี้ไม่ได้แม้แต่แถวเดียว")
    valid_rows.sort(key=lambda pair: pair[0])
    start_ts, _ = valid_rows[0]
    end_ts, _ = valid_rows[-1]

    # --- Active power stats ---
    active_power_values = [v for _, r in valid_rows if (v := _to_float(col(r, "active_power"))) is not None]
    peak_active_power = max(active_power_values) if active_power_values else None

    # --- Status time breakdown (bucketed) ---
    interval_minutes = None
    if len(valid_rows) >= 2:
        deltas = [(valid_rows[i][0] - valid_rows[i - 1][0]).total_seconds() / 60 for i in range(1, len(valid_rows))]
        interval_minutes = statistics.median(deltas)
    status_minutes = {}
    if "status" in col_index and interval_minutes:
        for _, r in valid_rows:
            raw_status = col(r, "status") or ""
            bucket = _bucket_status(raw_status)
            status_minutes[bucket] = status_minutes.get(bucket, 0) + interval_minutes

    # --- Total yield delta (cumulative counter) ---
    yield_values = [v for _, r in valid_rows if (v := _to_float(col(r, "total_yield"))) is not None]
    yield_delta = None
    if len(yield_values) >= 2:
        first_y, last_y = yield_values[0], yield_values[-1]
        if last_y >= first_y:
            yield_delta = round(last_y - first_y, 3)
        # if the counter went DOWN, it likely reset mid-window — don't
        # report a fabricated negative "production" figure

    # --- Internal temperature ---
    temp_values = [v for _, r in valid_rows if (v := _to_float(col(r, "internal_temp"))) is not None]
    temp_max = max(temp_values) if temp_values else None
    temp_min = min(temp_values) if temp_values else None

    # --- Per-PV-string peak current, peer-compared to find a dead/weak string ---
    string_peaks = {}
    for string_no, idx in pv_string_cols.items():
        values = [v for _, r in valid_rows if idx < len(r) and (v := _to_float(r[idx])) is not None]
        if values:
            string_peaks[string_no] = max(values)
    string_peer_results = compare_to_peers(
        [{"id": sn, "value": v} for sn, v in string_peaks.items()],
        bad_direction="low",
    )
    weak_strings = [r for r in string_peer_results if r["is_outlier"]]

    # --- Build human-readable summary (Thai) ---
    lines = []
    lines.append(
        f"ข้อมูล time-series จาก {start_ts.strftime('%Y-%m-%d %H:%M')} ถึง {end_ts.strftime('%Y-%m-%d %H:%M')} "
        f"({len(valid_rows)} จุดข้อมูล)"
    )
    if peak_active_power is not None:
        lines.append(f"กำลังผลิตสูงสุดที่บันทึกได้ในช่วงนี้: {peak_active_power} kW")
    if yield_delta is not None:
        lines.append(f"พลังงานที่ผลิตได้สะสมในช่วงนี้ (Total yield delta): {yield_delta} kWh")
    if temp_max is not None:
        lines.append(f"อุณหภูมิภายในเครื่อง: ต่ำสุด {temp_min}°C สูงสุด {temp_max}°C")
    if status_minutes:
        readable = ", ".join(f"{k}: {round(v)} นาที" for k, v in sorted(status_minutes.items(), key=lambda kv: -kv[1]))
        lines.append(f"สถานะเครื่องแยกตามช่วงเวลา: {readable}")
        off_commanded = status_minutes.get("off_commanded", 0)
        if off_commanded >= 180:  # 3+ hours of commanded-off is worth a human's attention
            hh, mm = divmod(round(off_commanded), 60)
            lines.append(
                f"หมายเหตุ: เครื่องอยู่ในสถานะ 'OFF : instructed shutdown' (ปิดโดยคำสั่ง ไม่ใช่ปิดเพราะไม่มีแดด) "
                f"ยาวนาน {hh} ชั่วโมง {mm} นาที ในช่วงเวลานี้ — ควรตรวจสอบว่าเป็นการปิดเพื่อบำรุงรักษาตามแผน "
                "หรือมีคนลืมเปิดเครื่องกลับ"
            )
    if weak_strings:
        weak_ids = ", ".join(f"PV{r['id']}" for r in weak_strings)
        best = max(string_peaks.values()) if string_peaks else None
        lines.append(
            f"หมายเหตุ: กระแสสูงสุดของสตริง {weak_ids} ต่ำกว่าสตริงที่ดีที่สุดในชุดเดียวกัน (สูงสุด {best} A) "
            "อย่างมีนัยสำคัญ ควรตรวจสอบสตริงนี้ (แผงบังแดด/สายหลุด/ฟิวส์ขาด)"
        )

    key_measurements = []
    if peak_active_power is not None:
        key_measurements.append({"parameter": "active_power_kw_peak", "value": peak_active_power, "unit": "kW", "comparator": "="})
    if yield_delta is not None:
        key_measurements.append({"parameter": "daily_energy_kwh_delta", "value": yield_delta, "unit": "kWh", "comparator": "="})
    if temp_max is not None:
        key_measurements.append({"parameter": "internal_temp_c_max", "value": temp_max, "unit": "C", "comparator": "="})
    if status_minutes.get("off_commanded"):
        key_measurements.append({"parameter": "off_commanded_minutes", "value": round(status_minutes["off_commanded"]), "unit": "min", "comparator": "="})

    # Severity is decided right here, in code — this whole finding is
    # already 100% computed, there's no LLM judgment step for it to pass
    # through. A weak-string proportion >= 30% of the array materially
    # impairs production (not just one bad apple), so it's CRITICAL rather
    # than WARNING; a smaller proportion, or just extended off-time, is
    # WARNING (worth a human's attention, not yet a confirmed major loss).
    severity = "NORMAL"
    if weak_strings and string_peaks:
        weak_fraction = len(weak_strings) / len(string_peaks)
        severity = _higher(severity, "CRITICAL" if weak_fraction >= 0.3 else "WARNING")
    if status_minutes.get("off_commanded", 0) >= 180:
        severity = _higher(severity, "WARNING")

    return {
        "category": "Inverter & Monitoring",
        "source_file": source_file,
        "observed_data": " ".join(lines),
        "severity": severity,
        "engineering_diagnosis": (
            f"[คำนวณจากไฟล์ CSV โดยตรง: พบสตริง {len(weak_strings)} จาก {len(string_peaks)} สตริง ที่กระแสสูงสุดต่ำกว่าสตริงที่ดีที่สุดอย่างมีนัยสำคัญ]"
            if weak_strings else ""
        ),
        "key_measurements": key_measurements,
    }

PYEOF

cat > engines/master_engine.py << 'PYEOF'
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

PYEOF

cat > tests/test_threshold_rules.py << 'PYEOF'
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.threshold_rules import (
    apply_measurement_thresholds,
    apply_peer_comparison,
    derive_plant_totals,
    detect_cross_source_conflicts,
    fill_default_diagnosis,
    finalize_overall_status,
    initialize_finding_defaults,
    reconcile_narrative_with_findings,
)
from router import _enforce_engineering_rules


def _finding(category, source_file, observed_data, severity="NORMAL", diagnosis=""):
    return {
        "category": category,
        "source_file": source_file,
        "observed_data": observed_data,
        "engineering_diagnosis": diagnosis,
        "severity": severity,
    }


def _report(findings, overall_status="NORMAL"):
    return {
        "plant_summary": {"overall_status": overall_status},
        "evidence_findings": findings,
    }


# --- The exact bug this file exists to prevent --------------------------

def test_low_riso_reading_is_never_left_as_normal_regardless_of_llm_output():
    """Golden case from Global House Phitsanulok: Inverter 2 monitoring screen
    reads Insulation resistance 0.836 MOhm. One real run of the LLM called
    this NORMAL, another called it WARNING, for the identical number. After
    this rule, it must always come out WARNING no matter what the LLM said."""
    report = _report([
        _finding(
            "Inverter & Monitoring", "Inv_2.jpg",
            "Inverter status: Grid connected, Active power: 3.867 kW, Insulation resistance: 0.836 MOhm",
            severity="NORMAL",  # this is what one real run produced — must be overridden
        ),
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "WARNING"
    assert report["plant_summary"]["overall_status"] == "WARNING"
    assert locked is False  # WARNING doesn't need to skip the verification pass, only CRITICAL does


def test_very_low_riso_escalates_to_critical_and_locks_status():
    report = _report([
        _finding(
            "Inverter & Monitoring", "Inv_9.jpg",
            "Insulation resistance: 0.2 MOhm", severity="NORMAL",
        ),
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "CRITICAL"
    assert report["plant_summary"]["overall_status"] == "CRITICAL"
    assert locked is True


def test_rule_never_downgrades_an_llm_severity_that_was_already_worse():
    report = _report([
        _finding(
            "Inverter & Monitoring", "Inv_2.jpg",
            "Insulation resistance: 0.836 MOhm", severity="CRITICAL",
        ),
    ], overall_status="CRITICAL")
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "CRITICAL"


def test_healthy_reading_is_left_alone():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "Insulation resistance: 20.000 MOhm"),
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "NORMAL"
    assert report["plant_summary"]["overall_status"] == "NORMAL"
    assert locked is False


def test_string_electrical_category_is_not_scanned_by_the_live_monitoring_rule():
    # Paper Megger readings live under a different category and a different
    # safety story (isolated test) — this rule must not fire on them.
    report = _report([
        _finding("String Electrical", "DC_Inv_1-2.jpg", "Riso +/G >1000 MOhm"),
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "NORMAL"


# --- Cross-source conflict (paper Megger vs live monitoring) ------------

def test_conflicting_paper_and_monitor_readings_are_flagged():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "Insulation resistance: 0.836 MOhm"),
        _finding("String Electrical", "DC_Inv_1-2.jpg", "Riso +/G >1000 MOhm"),
    ])
    report = detect_cross_source_conflicts(report)
    conflict_rows = [f for f in report["evidence_findings"] if "cross_source_conflict" in f.get("engineering_diagnosis", "")]
    assert len(conflict_rows) == 1
    assert "Inverter 2" in conflict_rows[0]["observed_data"]
    assert report["plant_summary"]["overall_status"] == "WARNING"


def test_no_conflict_flagged_when_both_sources_agree():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "Insulation resistance: 20.000 MOhm"),
        _finding("String Electrical", "DC_Inv_1-2.jpg", "Riso +/G >1000 MOhm"),
    ])
    report = detect_cross_source_conflicts(report)
    assert len(report["evidence_findings"]) == 2  # nothing appended


def test_thai_label_ka_chanuan_is_also_caught_not_just_english_wording():
    """The real 2026-09-03 report writer output '...ค่าฉนวน 0.836 MOhm' — Thai
    for insulation value — instead of the English phrase. An English-only
    regex would have silently missed this and shipped the exact same bug
    again under a different label."""
    report = _report([
        _finding(
            "Inverter & Monitoring", "Inv_2.jpg",
            "Active power 3.867 kW, ค่าฉนวน 0.836 MOhm",
            severity="NORMAL", diagnosis="ค่าฉนวนอยู่ในเกณฑ์ยอมรับได้",
        ),
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "WARNING"


# --- Structured key_measurements (primary path, added after the schema change) --

def test_structured_insulation_reading_is_used_even_with_no_matching_text():
    """The whole point of key_measurements: this must work even when the
    model's prose doesn't mention 'insulation resistance' or 'ค่าฉนวน' at
    all — exactly the run where the old text-only regex came up empty."""
    report = _report([
        {
            "category": "Inverter & Monitoring", "source_file": "Inv_2.jpg",
            "observed_data": "หน้าจอแสดงค่าปกติทั่วไป", "engineering_diagnosis": "",
            "severity": "NORMAL",
            "key_measurements": [{"parameter": "insulation_resistance_mohm", "value": 0.836, "unit": "MOhm", "comparator": "="}],
        },
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "WARNING"


def test_structured_reading_takes_priority_over_conflicting_text():
    # If both are present, the structured number wins — it's the field the
    # prompt now requires to be accurate, text is free-form and can drift.
    report = _report([
        {
            "category": "Inverter & Monitoring", "source_file": "Inv_2.jpg",
            "observed_data": "Insulation resistance: 20 MOhm (พิมพ์ผิดในข้อความ)",
            "engineering_diagnosis": "", "severity": "NORMAL",
            "key_measurements": [{"parameter": "insulation_resistance_mohm", "value": 0.3, "unit": "MOhm", "comparator": "="}],
        },
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "CRITICAL"


def test_comparator_greater_than_in_structured_data_is_not_flagged():
    # A Megger '>1000 MOhm' reading structured as value=1000, comparator='>'
    # must not be misread as an exact 1000 that somehow trips a < threshold.
    report = _report([
        {
            "category": "Inverter & Monitoring", "source_file": "Inv_1.jpg",
            "observed_data": "", "engineering_diagnosis": "", "severity": "NORMAL",
            "key_measurements": [{"parameter": "insulation_resistance_mohm", "value": 1000, "unit": "MOhm", "comparator": ">"}],
        },
    ])
    report, locked = apply_measurement_thresholds(report)
    assert report["evidence_findings"][0]["severity"] == "NORMAL"


def test_active_power_summed_from_structured_data_across_all_inverters():
    report = {
        "plant_summary": {"overall_status": "WARNING", "active_power_kw": "UNCONFIRMED"},
        "evidence_findings": [
            {"category": "Inverter & Monitoring", "source_file": "Inv_1.jpg", "observed_data": "", "engineering_diagnosis": "", "severity": "NORMAL",
             "key_measurements": [{"parameter": "active_power_kw", "value": 1.067, "comparator": "="}]},
            {"category": "Inverter & Monitoring", "source_file": "Inv_2.jpg", "observed_data": "", "engineering_diagnosis": "", "severity": "WARNING",
             "key_measurements": [{"parameter": "active_power_kw", "value": 3.867, "comparator": "="}]},
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "4.934"


def test_structured_and_text_active_power_can_mix_across_findings():
    # One finding has structured data, another only has it in prose — the
    # fallback still lets the sum go through instead of giving up entirely.
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": None},
        "evidence_findings": [
            {"category": "Inverter & Monitoring", "source_file": "Inv_1.jpg", "observed_data": "", "engineering_diagnosis": "", "severity": "NORMAL",
             "key_measurements": [{"parameter": "active_power_kw", "value": 1.067, "comparator": "="}]},
            {"category": "Inverter & Monitoring", "source_file": "Inv_2.jpg", "observed_data": "Active power: 3.867 kW", "engineering_diagnosis": "", "severity": "NORMAL",
             "key_measurements": []},
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "4.934"


def test_grid_current_and_rated_capacity_are_never_touched_by_this_module():
    """Physics/engineering guardrail: this module must never invent a plant-
    level grid_current_a or rated_capacity_kw, even when it could technically
    sum something — per-inverter currents aren't safely additive without
    known circuit topology, and rated capacity isn't derivable from photos
    at all. Only active_power_kw gets an automatic total."""
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "UNCONFIRMED", "grid_current_a": "UNCONFIRMED", "rated_capacity_kw": "UNCONFIRMED"},
        "evidence_findings": [
            {"category": "Inverter & Monitoring", "source_file": "Inv_1.jpg", "observed_data": "", "engineering_diagnosis": "", "severity": "NORMAL",
             "key_measurements": [
                 {"parameter": "active_power_kw", "value": 1.067, "comparator": "="},
                 {"parameter": "grid_current_a", "value": 5.6, "comparator": "="},
             ]},
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "1.067"
    assert report["plant_summary"]["grid_current_a"] == "UNCONFIRMED"
    assert report["plant_summary"]["rated_capacity_kw"] == "UNCONFIRMED"


# --- Deterministic recovery of plant-level totals ------------------------

def test_unconfirmed_active_power_is_summed_from_per_inverter_readings():
    """Live run on 2026-09-03: the top summary line showed 'กำลังผลิตจริง:
    UNCONFIRMED' even though every single Inverter & Monitoring finding had a
    real Active power reading (3.867, 3.925, 4.165 kW, ...). Summing is not
    an LLM judgment call — do it in Python whenever the per-item numbers are
    actually present in evidence_findings."""
    report = {
        "plant_summary": {"overall_status": "WARNING", "active_power_kw": "UNCONFIRMED"},
        "evidence_findings": [
            _finding("Inverter & Monitoring", "Inv_1.jpg", "Active power: 1.067 kW"),
            _finding("Inverter & Monitoring", "Inv_2.jpg", "Active power: 3.867 kW"),
            _finding("Inverter & Monitoring", "Inv_3.jpg", "Active power: 3.925 kW"),
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "8.859"


def test_partial_per_inverter_data_is_not_summed_to_avoid_understating_output():
    # Only 2 of 3 inverter findings have a parseable reading — summing just
    # those two would silently under-report total output, so leave it alone.
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": None},
        "evidence_findings": [
            _finding("Inverter & Monitoring", "Inv_1.jpg", "Active power: 1.067 kW"),
            _finding("Inverter & Monitoring", "Inv_2.jpg", "Active power: 3.867 kW"),
            _finding("Inverter & Monitoring", "Inv_3.jpg", "Inverter offline, no reading"),
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] is None


def test_existing_active_power_value_is_never_overwritten():
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "18.2"},
        "evidence_findings": [
            _finding("Inverter & Monitoring", "Inv_1.jpg", "Active power: 999 kW"),
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "18.2"


def test_batch_test_file_does_not_pollute_peer_baseline():
    """Real bug from a live report: 'AC_Inv_1-6.jpg' (an AC-side Megger test
    covering all 6 inverters at once, reading '>500 MOhm') got filed under
    'Inverter & Monitoring' — the same category as the 6 individual live
    dashboard screenshots. Comparing against it inflated the peer baseline
    to 500 MOhm (a compliance bound from a different measurement method)
    instead of 20 MOhm (the real best live reading, from Inv_1.jpg), which
    overstated Inv_2's deviation as 99.8% instead of the correct 95.8%."""
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "Insulation resistance 20.000 MOhm"),
        _finding("Inverter & Monitoring", "Inv_2.jpg", "Insulation resistance 0.836 MOhm"),
        _finding("Inverter & Monitoring", "Inv_3.jpg", "Insulation resistance 0.867 MOhm"),
        _finding("Inverter & Monitoring", "Inv_4.jpg", "Insulation resistance 0.921 MOhm"),
        _finding("Inverter & Monitoring", "AC_Inv_1-6.jpg", "ผลการวัดแสดงค่า >500 MOhm ทุกเฟส"),
    ])
    report, locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    inv2 = [f for f in report["evidence_findings"] if f["source_file"] == "Inv_2.jpg"][0]
    assert inv2["corroboration"] == "peer_deviation:95.8pct_below_best_peer"


def test_batch_test_file_does_not_block_active_power_sum():
    """Same root cause, different function: AC_Inv_1-6.jpg has no active-power
    reading at all, so requiring EVERY 'Inverter & Monitoring' finding to
    have one (including this batch file) meant the sum was abandoned even
    though all 6 real inverters had a valid reading."""
    report = {
        "plant_summary": {"active_power_kw": "UNCONFIRMED"},
        "evidence_findings": [
            _finding("Inverter & Monitoring", "Inv_1.jpg", "Active power 1.067 kW"),
            _finding("Inverter & Monitoring", "Inv_2.jpg", "Active power 3.867 kW"),
            _finding("Inverter & Monitoring", "AC_Inv_1-6.jpg", "ผลการวัดแสดงค่า >500 MOhm ทุกเฟส"),
        ],
    }
    report = derive_plant_totals(report)
    assert report["plant_summary"]["active_power_kw"] == "4.934"


# --- Peer comparison integration (corroborate or honestly qualify) ------

def test_global_house_full_batch_gets_corroborated_by_peer_deviation():
    """Full 6-inverter batch: the WARNING escalation for Inv2-5 should come
    out CORROBORATED (peer_deviation), because Inv1/Inv6 prove 13-20 MOhm was
    achievable under the same conditions right now — this is no longer just
    'a number crossed a generic line', it's a verified anomaly."""
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "Insulation resistance: 20.000 MOhm"),
        _finding("Inverter & Monitoring", "Inv_2.jpg", "Insulation resistance: 0.836 MOhm"),
        _finding("Inverter & Monitoring", "Inv_3.jpg", "Insulation resistance: 0.867 MOhm"),
        _finding("Inverter & Monitoring", "Inv_4.jpg", "Insulation resistance: 0.921 MOhm"),
        _finding("Inverter & Monitoring", "Inv_5.jpg", "Insulation resistance: 0.872 MOhm"),
        _finding("Inverter & Monitoring", "Inv_6.jpg", "Insulation resistance: 13.541 MOhm"),
    ])
    report, locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    findings_by_file = {f["source_file"]: f for f in report["evidence_findings"]}
    for f in ["Inv_2.jpg", "Inv_3.jpg", "Inv_4.jpg", "Inv_5.jpg"]:
        assert findings_by_file[f]["severity"] == "WARNING"
        assert findings_by_file[f]["corroboration"].startswith("peer_deviation:")
    assert findings_by_file["Inv_1.jpg"]["severity"] == "NORMAL"
    assert findings_by_file["Inv_6.jpg"]["severity"] == "NORMAL"


def test_single_low_reading_with_no_peers_stays_warning_but_wording_is_honestly_qualified():
    """This is the exact concern the user raised: without knowing this
    inverter model's real normal range, and with no peers to compare against,
    the system must NOT confidently claim 'violates safety standard'. But it
    also must not silently drop back to NORMAL — that reintroduces the
    original disaster (a real risk called normal). Severity stays WARNING;
    only the certainty of the wording changes."""
    report = _report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "Insulation resistance: 0.836 MOhm"),
    ])
    report, locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    finding = report["evidence_findings"][0]
    assert finding["severity"] == "WARNING"  # never silently downgraded
    assert finding["corroboration"] == "threshold_only_unverified"
    assert "ยังไม่มีข้อมูลอ้างอิงเฉพาะรุ่น" in finding["engineering_diagnosis"]


def test_peer_comparison_leaves_non_escalated_findings_untouched():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "Insulation resistance: 20.000 MOhm"),
        _finding("Inverter & Monitoring", "Inv_2.jpg", "Insulation resistance: 19.500 MOhm"),
        _finding("Inverter & Monitoring", "Inv_3.jpg", "Insulation resistance: 18.900 MOhm"),
        _finding("Inverter & Monitoring", "Inv_4.jpg", "Insulation resistance: 20.100 MOhm"),
    ])
    report, locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    for f in report["evidence_findings"]:
        assert f["severity"] == "NORMAL"
        assert f.get("corroboration") is None


# --- Narrative/data consistency guard ------------------------------------

def _full_report(findings, executive_summary="ระบบทำงานสมบูรณ์ ไม่พบความผิดปกติ", root_causes=None, corrective_actions=None):
    return {
        "plant_summary": {"overall_status": "WARNING"},
        "executive_summary": executive_summary,
        "evidence_findings": findings,
        "root_causes": root_causes or [],
        "corrective_actions": corrective_actions or [],
    }


def test_narrative_untouched_when_nothing_escalated():
    report = _full_report([_finding("Inverter & Monitoring", "Inv_1.jpg", "ปกติ")])
    result = reconcile_narrative_with_findings(report)
    assert result["executive_summary"] == "ระบบทำงานสมบูรณ์ ไม่พบความผิดปกติ"
    assert result["root_causes"] == []
    assert result["corrective_actions"] == []


def test_stale_all_clear_summary_gets_banner_when_findings_are_escalated():
    """The real bug: header said WARNING, but executive_summary still read
    'ระบบทำงานสมบูรณ์...ไม่พบความผิดปกติ' because the LLM wrote that BEFORE
    threshold rules escalated Inv_2. The original text must not be deleted
    (still useful context) but a reader must not be able to miss the
    contradiction."""
    report = _full_report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "ต่ำกว่าเกณฑ์", severity="WARNING"),
    ])
    result = reconcile_narrative_with_findings(report)
    assert result["executive_summary"].startswith("[หมายเหตุจากระบบตรวจสอบอัตโนมัติ")
    assert "ระบบทำงานสมบูรณ์ ไม่พบความผิดปกติ" in result["executive_summary"]  # original kept, not deleted
    assert "Inv_2.jpg" in result["executive_summary"]


def test_empty_root_causes_gets_populated_from_escalated_findings():
    report = _full_report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "ต่ำกว่าเกณฑ์", severity="WARNING", diagnosis="ค่าฉนวนต่ำกว่าเกณฑ์ปลอดภัย"),
    ], root_causes=[])
    result = reconcile_narrative_with_findings(report)
    assert len(result["root_causes"]) == 1
    assert result["root_causes"][0]["supporting_evidence"] == "Inv_2.jpg"
    assert "ค่าฉนวนต่ำกว่าเกณฑ์ปลอดภัย" in result["root_causes"][0]["description"]


def test_existing_root_cause_covering_the_file_is_not_duplicated():
    report = _full_report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "ต่ำกว่าเกณฑ์", severity="WARNING"),
    ], root_causes=[{"issue": "Riso ต่ำ", "description": "...", "supporting_evidence": "Inv_2.jpg"}])
    result = reconcile_narrative_with_findings(report)
    assert len(result["root_causes"]) == 1  # not duplicated


def test_corrective_actions_gets_a_followup_step_when_missing():
    report = _full_report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "ต่ำกว่าเกณฑ์", severity="WARNING"),
    ], corrective_actions=[{"step_number": 1, "title": "PM ปกติ", "actions": ["บันทึกข้อมูล"]}])
    result = reconcile_narrative_with_findings(report)
    assert len(result["corrective_actions"]) == 2
    assert result["corrective_actions"][1]["step_number"] == 2
    assert "Inv_2.jpg" in result["corrective_actions"][1]["actions"][0]


def test_root_causes_schema_stays_valid_after_reconciliation():
    """Every field the RootCause/CorrectiveAction pydantic models require
    must actually be present, or validate_report (which runs right after
    this in router.py) would reject the whole report."""
    report = _full_report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "ต่ำกว่าเกณฑ์", severity="CRITICAL"),
    ])
    result = reconcile_narrative_with_findings(report)
    for rc in result["root_causes"]:
        assert set(rc.keys()) >= {"issue", "description", "supporting_evidence"}
    for ca in result["corrective_actions"]:
        assert set(ca.keys()) >= {"step_number", "title", "actions"}
        assert isinstance(ca["step_number"], int) and ca["step_number"] >= 1


# --- Pipeline-stage helpers (extraction/analysis/narrative split) -------

def test_initialize_finding_defaults_fills_missing_fields():
    report = {"evidence_findings": [{"category": "Inverter & Monitoring", "source_file": "Inv_1.jpg", "observed_data": "20 MOhm"}]}
    result = initialize_finding_defaults(report)
    f = result["evidence_findings"][0]
    assert f["severity"] == "NORMAL"
    assert f["engineering_diagnosis"] == ""
    assert f["key_measurements"] == []


def test_initialize_finding_defaults_never_overwrites_existing_values():
    report = {"evidence_findings": [{"severity": "CRITICAL", "engineering_diagnosis": "already set"}]}
    result = initialize_finding_defaults(report)
    assert result["evidence_findings"][0]["severity"] == "CRITICAL"
    assert result["evidence_findings"][0]["engineering_diagnosis"] == "already set"


def test_fill_default_diagnosis_only_touches_empty_ones():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "20 MOhm", diagnosis=""),
        _finding("Inverter & Monitoring", "Inv_2.jpg", "0.8 MOhm", diagnosis="already explained"),
    ])
    result = fill_default_diagnosis(report)
    assert "ไม่มีกฎตรวจสอบอัตโนมัติ" in result["evidence_findings"][0]["engineering_diagnosis"]
    assert result["evidence_findings"][1]["engineering_diagnosis"] == "already explained"


def test_finalize_overall_status_computed_purely_from_findings():
    report = _report([
        _finding("Inverter & Monitoring", "Inv_1.jpg", "", severity="NORMAL"),
        _finding("Inverter & Monitoring", "Inv_2.jpg", "", severity="WARNING"),
    ], overall_status="NORMAL")
    result = finalize_overall_status(report)
    assert result["plant_summary"]["overall_status"] == "WARNING"


def test_finalize_overall_status_cannot_exceed_worst_finding_without_a_hard_lock():
    """The bug this closes: a report header said CRITICAL while every single
    finding topped out at WARNING — because overall_status used to be a
    free-floating field the LLM could set independently of its own
    per-finding severities. Now there's no such field for the LLM to set at
    all (run_extraction produces no overall_status), so an ungrounded
    CRITICAL claim like that is structurally impossible: this function is
    the ONLY thing that ever sets plant_summary.overall_status from
    scratch, and it can only derive CRITICAL from an actual CRITICAL
    finding or a prior hard lock."""
    report = _report([
        _finding("Inverter & Monitoring", "Inv_2.jpg", "", severity="WARNING"),
        _finding("Inverter & Monitoring", "Inv_3.jpg", "", severity="WARNING"),
    ])  # plant_summary starts with no overall_status key at all, like real extraction output
    del report["plant_summary"]
    report["plant_summary"] = {}
    result = finalize_overall_status(report)
    assert result["plant_summary"]["overall_status"] == "WARNING"  # never CRITICAL — nothing justifies it


def test_finalize_overall_status_preserves_a_genuine_hard_lock():
    # _enforce_engineering_rules sets this directly on plant_summary BEFORE
    # finalize_overall_status runs, for plant-level facts (e.g. confirmed
    # zero grid current) that aren't any single photo's severity.
    report = _report([_finding("Inverter & Monitoring", "Inv_1.jpg", "", severity="NORMAL")], overall_status="CRITICAL")
    result = finalize_overall_status(report)
    assert result["plant_summary"]["overall_status"] == "CRITICAL"


# --- Coverage for router's existing hard-coded rules (previously untested) --

def test_zero_grid_current_locks_critical():
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "0.1", "rated_capacity_kw": "500", "grid_current_a": "0"},
        "evidence_findings": [],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] == "CRITICAL"
    assert locked is True


def test_unconfirmed_active_power_and_grid_current_does_not_falsely_lock_critical():
    """Found during end-to-end verification: coerce_float('UNCONFIRMED') is
    None, and 'None or 0.0' silently became 0.0 — so a plant where the LLM
    simply couldn't extract active_power_kw/grid_current_a (not because
    output is actually zero) was being hard-locked CRITICAL as if it had
    confirmed zero output. Not knowing the value must never be treated as
    knowing it's zero."""
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "UNCONFIRMED", "grid_current_a": "UNCONFIRMED", "rated_capacity_kw": "20"},
        "evidence_findings": [{"observed_data": "ปกติทุกจุด", "engineering_diagnosis": ""}],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] != "CRITICAL"
    assert locked is False


def test_ground_fault_keyword_locks_critical():
    report = {
        "plant_summary": {"overall_status": "NORMAL"},
        "evidence_findings": [{"observed_data": "Alarm: Ground Fault detected", "engineering_diagnosis": ""}],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] == "CRITICAL"
    assert locked is True


def test_normal_with_zero_alarms_keeps_normal():
    report = {
        "plant_summary": {"overall_status": "NORMAL"},
        "evidence_findings": [{"observed_data": "0 alarm active", "engineering_diagnosis": ""}],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] == "NORMAL"
    assert locked is False


def test_negated_ground_fault_mention_does_not_lock_critical():
    """GBN - Phitsanulok report: every finding says NORMAL and the text reads
    'ไม่พบภาวะกราวด์ฟอลต์ (Ground Fault)' — Thai for 'no ground fault found' —
    but a naive substring search for 'ground fault' still matched and forced
    the whole report to CRITICAL despite every finding being NORMAL."""
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "18.201", "rated_capacity_kw": "680", "grid_current_a": "26.969"},
        "evidence_findings": [{
            "observed_data": "วงจร DC สตริงทั้งหมดเชื่อมต่อทางไฟฟ้าอย่างสมบูรณ์",
            "engineering_diagnosis": "ขั้วต่อและสายโซลาร์เคเบิลมีสภาพความเป็นฉนวนสมบูรณ์ ไม่พบภาวะกราวด์ฟอลต์ (Ground Fault) หรือสายขาดวงจร",
        }],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] != "CRITICAL"
    assert locked is False


def test_real_unnegated_ground_fault_still_locks_critical():
    """Make sure fixing the false positive above didn't break the real case —
    an actual, unnegated ground fault mention must still lock CRITICAL."""
    report = {
        "plant_summary": {"overall_status": "NORMAL"},
        "evidence_findings": [{"observed_data": "Alarm log shows an active ground fault on string 4", "engineering_diagnosis": ""}],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] == "CRITICAL"
    assert locked is True

PYEOF

cat > tests/test_peer_comparison.py << 'PYEOF'
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.peer_comparison import compare_to_peers


def test_returns_empty_below_min_peers():
    readings = [{"id": "A", "value": 1.0}, {"id": "B", "value": 2.0}]
    assert compare_to_peers(readings, bad_direction="low") == []


def test_global_house_case_flags_the_actually_degraded_units_not_the_healthy_ones():
    """The exact numbers from the real Global House Phitsanulok report. Four of
    six units read low (0.836-0.921) and two read healthy (13.541, 20.0). A
    median/MAD outlier test would flag the two healthy units as the anomaly,
    because they're the numeric minority. This must flag the four degraded
    ones instead, regardless of which side is the majority."""
    readings = [
        {"id": "Inv1", "value": 20.000},
        {"id": "Inv2", "value": 0.836},
        {"id": "Inv3", "value": 0.867},
        {"id": "Inv4", "value": 0.921},
        {"id": "Inv5", "value": 0.872},
        {"id": "Inv6", "value": 13.541},
    ]
    results = compare_to_peers(readings, bad_direction="low")
    flagged = {r["id"] for r in results if r["is_outlier"]}
    assert flagged == {"Inv2", "Inv3", "Inv4", "Inv5"}
    assert "Inv1" not in flagged and "Inv6" not in flagged


def test_uniformly_high_readings_are_not_flagged_when_all_peers_agree():
    """Global House Phitsanulok temperature scenario, generalized: if a
    quirk of this equipment model means every unit normally reads 70-90 degC,
    peer comparison must not manufacture an alarm just because the absolute
    numbers look high — nothing here falls short of what its peers show."""
    readings = [
        {"id": f"Inv{i}", "value": v}
        for i, v in enumerate([70, 75, 80, 85, 88, 90], start=1)
    ]
    results = compare_to_peers(readings, bad_direction="high")
    assert all(not r["is_outlier"] for r in results)


def test_single_genuine_outlier_among_healthy_peers_is_flagged():
    readings = [
        {"id": "Inv1", "value": 20.0},
        {"id": "Inv2", "value": 19.5},
        {"id": "Inv3", "value": 0.5},   # the one bad apple
        {"id": "Inv4", "value": 18.9},
    ]
    results = compare_to_peers(readings, bad_direction="low")
    flagged = {r["id"] for r in results if r["is_outlier"]}
    assert flagged == {"Inv3"}


def test_high_bad_direction_flags_the_hottest_unit():
    readings = [
        {"id": "Inv1", "value": 45.0},
        {"id": "Inv2", "value": 48.0},
        {"id": "Inv3", "value": 47.0},
        {"id": "Inv4", "value": 95.0},  # runs much hotter than its peers
    ]
    results = compare_to_peers(readings, bad_direction="high")
    flagged = {r["id"] for r in results if r["is_outlier"]}
    assert flagged == {"Inv4"}


def test_zero_baseline_does_not_crash():
    readings = [{"id": f"U{i}", "value": 0.0} for i in range(5)]
    results = compare_to_peers(readings, bad_direction="low")
    assert all(r["deviation_pct"] == 0.0 and not r["is_outlier"] for r in results)


def test_invalid_bad_direction_raises():
    import pytest
    with pytest.raises(ValueError):
        compare_to_peers([{"id": "A", "value": 1.0}] * 4, bad_direction="sideways")


def test_relative_threshold_is_tunable():
    readings = [
        {"id": "Inv1", "value": 20.0},
        {"id": "Inv2", "value": 15.0},  # 25% below baseline
        {"id": "Inv3", "value": 19.0},
        {"id": "Inv4", "value": 18.0},
    ]
    # default 40% threshold: 25% shortfall should NOT be flagged
    default_results = compare_to_peers(readings, bad_direction="low")
    assert not any(r["is_outlier"] for r in default_results if r["id"] == "Inv2")
    # a stricter 20% threshold: the same 25% shortfall SHOULD be flagged
    strict_results = compare_to_peers(readings, bad_direction="low", relative_threshold_pct=20.0)
    assert [r for r in strict_results if r["id"] == "Inv2"][0]["is_outlier"] is True

PYEOF

cat > tests/test_master_pipeline.py << 'PYEOF'
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


def test_csv_files_are_parsed_deterministically_and_never_sent_to_extraction(monkeypatch):
    """CSV time-series logs must never reach run_extraction (no Gemini call,
    no token cost, no LLM judgment) — they're parsed entirely in Python and
    merged into evidence_findings afterward."""
    image = io.BytesIO()
    Image.new("RGB", (20, 20), "white").save(image, format="PNG")
    csv_content = (
        "Time range:,2026-09-05 00:00:00 - 2026-09-05 23:59:59,\n"
        "Export time:,2026-09-05 17:29:12,\n"
        "Start Time,Active power(kW),Inverter status,Total yield(kWh)\n"
        "2026-09-05 09:00:00,5.0,Grid connected,50.0\n"
        "2026-09-05 09:05:00,5.2,Grid connected,50.5\n"
    ).encode("utf-8")
    files = [Upload("ABC_STATUS.png", image.getvalue()), Upload("Inverter_LOG_INVERTER-01.csv", csv_content)]
    extraction_files_seen = []

    def fake_extraction(uploaded_files, *args, **kwargs):
        extraction_files_seen.extend([f.name for f in uploaded_files])
        return valid_report()

    def fake_narrative(report, api_key, lang="th"):
        return {
            "executive_summary": "Summary.", "root_causes": [],
            "corrective_actions": [{"step_number": 1, "title": "Verify", "actions": ["Inspect"]}],
            "spare_parts_tools": [], "inaction_damage_matrix": [],
        }

    monkeypatch.setattr(router, "run_extraction", fake_extraction)
    monkeypatch.setattr(router, "run_narrative_writing", fake_narrative)
    monkeypatch.setattr(router, "get_plant_history_context", lambda *args: "")
    monkeypatch.setattr(router, "get_similar_cases_context", lambda *args: "")
    monkeypatch.setattr(router, "extract_reference_context", lambda files: ("", []))

    report, document, report_type, _ = router.process_field_report(files, "key")

    assert "Inverter_LOG_INVERTER-01.csv" not in extraction_files_seen  # never sent to Gemini
    assert extraction_files_seen == ["ABC_STATUS.png"]
    csv_finding = [f for f in report["evidence_findings"] if f["source_file"] == "Inverter_LOG_INVERTER-01.csv"]
    assert len(csv_finding) == 1
    assert csv_finding[0]["severity"] == "NORMAL"



    """Replaces the old 'exactly one master call' assertion: severity is now
    decided by deterministic code between two LLM calls (extraction, then
    narrative writing) instead of one call doing everything — so the correct
    invariant is exactly one call to EACH stage, not one call total."""
    image = io.BytesIO()
    Image.new("RGB", (20, 20), "white").save(image, format="PNG")
    files = [Upload("ABC_STATUS.png", image.getvalue())]
    extraction_calls = []
    narrative_calls = []

    def fake_extraction(*args, **kwargs):
        extraction_calls.append((args, kwargs))
        report = valid_report()
        # Stage 1 no longer produces severity/overall_status at all.
        del report["plant_summary"]["overall_status"]
        for f in report["evidence_findings"]:
            f.pop("severity", None)
            f.pop("engineering_diagnosis", None)
        for key in ("executive_summary", "root_causes", "corrective_actions", "spare_parts_tools"):
            report.pop(key, None)
        return report

    def fake_narrative(report, api_key, lang="th"):
        narrative_calls.append((report, api_key, lang))
        return {
            "executive_summary": "Current evidence summary.",
            "root_causes": [],
            "corrective_actions": [{"step_number": 1, "title": "Verify", "actions": ["Inspect current evidence"]}],
            "spare_parts_tools": [],
            "inaction_damage_matrix": [],
        }

    monkeypatch.setattr(router, "run_extraction", fake_extraction)
    monkeypatch.setattr(router, "run_narrative_writing", fake_narrative)
    monkeypatch.setattr(router, "get_plant_history_context", lambda *args: "")
    monkeypatch.setattr(router, "get_similar_cases_context", lambda *args: "")
    monkeypatch.setattr(router, "extract_reference_context", lambda files: ("", []))

    report, document, report_type, _ = router.process_field_report(files, "key")

    assert len(extraction_calls) == 1
    assert len(narrative_calls) == 1
    assert report_type == "MASTER_REPORT"
    assert report["evidence_manifest"][0]["evidence_type"] == "STATUS"
    assert report["plant_summary"]["overall_status"] in ("NORMAL", "WARNING", "CRITICAL")  # computed by code, not passed through
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

PYEOF

cat > tests/test_csv_reader.py << 'PYEOF'
import io
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.csv_reader import read_inverter_timeseries_csv

FIXTURE = ROOT / "tests" / "fixtures" / "inverter_log_sample.csv"


def _build_csv(header, rows):
    lines = [
        "Time range:,2026-09-05 00:00:00 - 2026-09-05 23:59:59,",
        "Export time:,2026-09-05 17:29:12,",
        ",".join(header),
    ]
    for r in rows:
        lines.append(",".join(str(v) for v in r))
    return ("\n".join(lines)).encode("utf-8")


# --- Golden test against the real, hand-verified file --------------------

def test_real_sample_file_finds_the_five_dead_strings():
    """Independently verified by hand: PV2, PV5, PV7, PV8, PV11 read exactly
    0.0 A across the entire day while PV1/3/4/6/9/10 reach ~22 A. This is a
    real production-impairing fault (5 of 11 strings dead), not a synthetic
    test case."""
    raw = FIXTURE.read_bytes()
    result = read_inverter_timeseries_csv(raw, FIXTURE.name)
    assert result["severity"] == "CRITICAL"  # 5/11 = 45% >= 30% threshold
    for label in ("PV2", "PV5", "PV7", "PV8", "PV11"):
        assert label in result["observed_data"]
    assert result["category"] == "Inverter & Monitoring"


def test_real_sample_file_flags_extended_commanded_shutdown():
    raw = FIXTURE.read_bytes()
    result = read_inverter_timeseries_csv(raw, FIXTURE.name)
    assert "instructed shutdown" in result["observed_data"]
    assert any(m["parameter"] == "off_commanded_minutes" and m["value"] >= 180 for m in result["key_measurements"])


def test_real_sample_file_computes_correct_yield_delta():
    # First row Total yield = 51.41, last row = 429.75 -> delta 378.34
    raw = FIXTURE.read_bytes()
    result = read_inverter_timeseries_csv(raw, FIXTURE.name)
    delta = [m["value"] for m in result["key_measurements"] if m["parameter"] == "daily_energy_kwh_delta"][0]
    assert delta == 378.34


# --- Synthetic tests for edge cases and format robustness -----------------

def test_all_strings_healthy_gives_normal_severity():
    header = ["Start Time", "Active power(kW)", "Inverter status", "Internal temperature(°C)",
              "PV1 input current(A)", "PV2 input current(A)", "Total yield(kWh)"]
    rows = [
        ["2026-09-05 08:00:00", "10.0", "Grid connected", "45.0", "10.0", "10.2", "100.0"],
        ["2026-09-05 08:05:00", "10.5", "Grid connected", "45.2", "10.1", "10.1", "100.9"],
        ["2026-09-05 08:10:00", "11.0", "Grid connected", "45.5", "10.2", "10.3", "101.8"],
        ["2026-09-05 08:15:00", "11.2", "Grid connected", "45.6", "10.3", "10.2", "102.7"],
    ]
    result = read_inverter_timeseries_csv(_build_csv(header, rows), "healthy.csv")
    assert result["severity"] == "NORMAL"
    assert "หมายเหตุ" not in result["observed_data"]


def test_different_column_order_and_wording_still_parses():
    """Different logger export: columns in a different order, different
    header capitalization — nothing here should assume a fixed layout."""
    header = ["Inverter Status", "PV1 Input Current(A)", "Start Time", "active power(kw)", "total yield(kwh)"]
    rows = [
        ["Grid connected", "15.0", "2026-09-05 09:00:00", "5.0", "50.0"],
        ["Grid connected", "15.2", "2026-09-05 09:05:00", "5.1", "50.5"],
        ["Grid connected", "15.1", "2026-09-05 09:10:00", "5.2", "51.0"],
        ["Grid connected", "15.3", "2026-09-05 09:15:00", "5.3", "51.5"],
    ]
    result = read_inverter_timeseries_csv(_build_csv(header, rows), "different_layout.csv")
    assert result["severity"] == "NORMAL"
    assert any(m["parameter"] == "daily_energy_kwh_delta" for m in result["key_measurements"])


def test_yield_counter_reset_does_not_report_fabricated_negative():
    header = ["Start Time", "Total yield(kWh)"]
    rows = [
        ["2026-09-05 08:00:00", "500.0"],
        ["2026-09-05 08:05:00", "0.5"],  # counter reset mid-window
    ]
    result = read_inverter_timeseries_csv(_build_csv(header, rows), "reset.csv")
    assert not any(m["parameter"] == "daily_energy_kwh_delta" for m in result["key_measurements"])


def test_unrecognizable_file_raises_value_error():
    garbage = b"this,is,not,an,inverter,log\n1,2,3,4,5,6"
    try:
        read_inverter_timeseries_csv(garbage, "garbage.csv")
        assert False, "should have raised"
    except ValueError:
        pass


def test_three_of_eleven_strings_weak_is_warning_not_critical():
    # 3/11 = 27% < 30% threshold -> WARNING, not CRITICAL
    header = ["Start Time"] + [f"PV{i} input current(A)" for i in range(1, 12)]
    healthy = ["20.0"] * 8
    weak = ["0.0"] * 3
    row = ["2026-09-05 09:00:00"] + healthy + weak
    row2 = ["2026-09-05 09:05:00"] + healthy + weak
    result = read_inverter_timeseries_csv(_build_csv(header, [row, row2]), "partial.csv")
    assert result["severity"] == "WARNING"

PYEOF

cat > tests/fixtures/inverter_log_sample.csv << 'PYEOF'
﻿Time range:,2026-09-05 00:00:00 - 2026-09-05 23:59:59,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
Export time:,2026-09-05 17:29:12,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
"""N/A"": Not available/Some counters are not recorded when the device is disconnected
""-"": This counter is not supported by the device.
Content in gray italics: This is the supplementary data and is for reference only.",,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,,
Site Name,Management Domain,ManageObject,Start Time,Active power(kW),Grid current/Grid phase A current(A),Internal temperature(℃),Inverter shutdown time,Inverter status,Phase A voltage(V),Phase B current(A),Phase B voltage(V),Phase C current(A),Phase C voltage(V),PV1 input current(A),PV1 input voltage(V),PV2 input current(A),PV2 input voltage(V),PV3 input current(A),PV3 input voltage(V),PV4 input current(A),PV4 input voltage(V),PV5 input current(A),PV5 input voltage(V),PV6 input current(A),PV6 input voltage(V),PV7 input current(A),PV7 input voltage(V),PV8 input current(A),PV8 input voltage(V),PV9 input current(A),PV9 input voltage(V),PV10 input current(A),PV10 input voltage(V),PV11 input current(A),PV11 input voltage(V),Total yield(kWh)
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:00:00,0.000,0.000,37.6,N/A,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:05:00,0.000,0.000,37.6,N/A,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:10:00,0.000,0.000,37.5,N/A,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:15:00,0.000,0.000,37.5,N/A,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:20:00,0.000,0.000,37.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:25:00,0.000,0.000,37.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:30:00,0.000,0.000,37.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:35:00,0.000,0.000,37.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:40:00,0.000,0.000,37.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:45:00,0.000,0.000,37.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:50:00,0.000,0.000,37.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 00:55:00,0.000,0.000,37.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:00:00,0.000,0.000,37.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:05:00,0.000,0.000,37.2,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:10:00,0.000,0.000,37.2,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:15:00,0.000,0.000,37.2,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:20:00,0.000,0.000,37.2,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:25:00,0.000,0.000,37.1,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:30:00,0.000,0.000,37.1,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:35:00,0.000,0.000,37.1,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:40:00,0.000,0.000,37.1,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:45:00,0.000,0.000,37.1,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:50:00,0.000,0.000,37.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 01:55:00,0.000,0.000,37.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:00:00,0.000,0.000,37.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:05:00,0.000,0.000,36.9,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:10:00,0.000,0.000,36.9,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:15:00,0.000,0.000,36.8,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:20:00,0.000,0.000,36.8,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:25:00,0.000,0.000,36.7,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:30:00,0.000,0.000,36.7,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:35:00,0.000,0.000,36.7,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:40:00,0.000,0.000,36.7,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:45:00,0.000,0.000,36.6,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:50:00,0.000,0.000,36.6,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 02:55:00,0.000,0.000,36.6,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:00:00,0.000,0.000,36.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:05:00,0.000,0.000,36.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:10:00,0.000,0.000,36.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:15:00,0.000,0.000,36.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:20:00,0.000,0.000,36.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:25:00,0.000,0.000,36.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:30:00,0.000,0.000,36.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:35:00,0.000,0.000,36.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:40:00,0.000,0.000,36.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:45:00,0.000,0.000,36.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:50:00,0.000,0.000,36.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 03:55:00,0.000,0.000,36.2,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:00:00,0.000,0.000,36.2,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:05:00,0.000,0.000,36.2,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:10:00,0.000,0.000,36.2,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:15:00,0.000,0.000,36.1,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:20:00,0.000,0.000,36.1,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:25:00,0.000,0.000,36.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:30:00,0.000,0.000,36.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:35:00,0.000,0.000,36.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:40:00,0.000,0.000,36.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:45:00,0.000,0.000,36.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:50:00,0.000,0.000,36.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 04:55:00,0.000,0.000,35.9,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:00:00,0.000,0.000,35.9,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:05:00,0.000,0.000,35.9,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:10:00,0.000,0.000,35.9,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:15:00,0.000,0.000,35.9,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:20:00,0.000,0.000,35.8,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:25:00,0.000,0.000,35.8,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:30:00,0.000,0.000,35.8,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:35:00,0.000,0.000,35.8,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:40:00,0.000,0.000,35.8,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:45:00,0.000,0.000,35.7,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:50:00,0.000,0.000,35.7,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 05:55:00,0.000,0.000,35.7,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:00:00,0.000,0.000,35.6,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:05:00,0.000,0.000,35.6,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:10:00,0.000,0.000,35.6,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:15:00,0.000,0.000,35.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:20:00,0.000,0.000,35.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:25:00,0.000,0.000,35.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:30:00,0.000,0.000,35.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:35:00,0.000,0.000,35.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:40:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:45:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:50:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 06:55:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:00:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:05:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:10:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:15:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:20:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:25:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:30:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:35:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:40:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:45:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:50:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 07:55:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:00:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:05:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:10:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:15:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:20:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:25:00,0.000,0.000,35.3,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:30:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:35:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:40:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:45:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:50:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 08:55:00,0.000,0.000,35.4,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:00:00,0.000,0.000,35.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:05:00,0.000,0.000,35.5,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:10:00,0.000,0.000,35.6,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:15:00,0.000,0.000,35.6,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:20:00,0.000,0.000,35.6,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:25:00,0.000,0.000,35.7,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:30:00,0.000,0.000,35.7,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:35:00,0.000,0.000,35.8,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:40:00,0.000,0.000,35.8,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:45:00,0.000,0.000,35.9,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:50:00,0.000,0.000,35.9,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 09:55:00,0.000,0.000,36.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:00:00,0.000,0.000,36.0,2026/09/02 15:36:36,OFF : instructed shutdown,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,51.41
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:05:00,110.201,157.252,35.3,2026/09/02 15:36:36,Grid connected,232.1,156.803,236.0,156.616,234.4,14.76,698.9,0.00,698.9,14.83,698.9,14.65,694.9,0.00,694.9,14.85,694.9,0.00,726.9,0.00,726.9,14.03,726.9,14.47,701.3,0.00,701.3,51.95
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:10:00,165.000,234.712,41.5,2026/09/02 15:36:36,Grid connected,232.1,233.894,237.0,233.698,235.4,19.96,757.1,0.00,757.1,20.51,757.1,20.23,755.6,0.00,755.6,20.08,755.6,0.00,730.7,0.00,730.7,21.57,730.7,21.74,726.7,0.00,726.7,64.50
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:15:00,130.615,186.813,48.9,2026/09/02 15:36:36,Grid connected,231.1,186.188,236.0,186.135,234.4,16.57,731.9,0.00,731.9,16.76,731.9,16.48,733.6,0.00,733.6,16.69,733.6,0.00,726.4,0.00,726.4,16.69,726.4,16.61,730.7,0.00,730.7,76.97
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:20:00,113.829,163.077,50.4,2026/09/02 15:36:36,Grid connected,231.0,162.552,235.9,162.521,233.9,14.79,726.6,0.00,726.6,14.85,726.6,14.61,725.2,0.00,725.2,14.76,725.2,0.00,734.8,0.00,734.8,14.36,734.8,14.32,734.5,0.00,734.5,84.15
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:25:00,89.575,128.577,52.0,2026/09/02 15:36:36,Grid connected,231.0,128.131,234.8,128.170,233.9,11.27,736.6,0.00,736.6,11.37,736.6,11.19,738.8,0.00,738.8,11.34,738.8,0.00,742.8,0.00,742.8,11.15,742.8,11.25,736.0,0.00,736.0,92.59
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:30:00,93.361,134.122,52.8,2026/09/02 15:36:36,Grid connected,231.0,133.695,234.8,133.679,233.9,11.62,744.5,0.00,744.5,11.75,744.5,11.61,743.6,0.00,743.6,11.78,743.6,0.00,746.8,0.00,746.8,11.58,746.8,11.60,745.0,0.00,745.0,100.33
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:35:00,112.757,162.226,54.0,2026/09/02 15:36:36,Grid connected,231.0,161.700,234.8,161.688,233.9,14.11,733.2,0.00,733.2,14.29,733.2,14.07,738.4,0.00,738.4,14.31,738.4,0.00,741.2,0.00,741.2,14.13,741.2,14.21,740.3,0.00,740.3,109.16
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:40:00,93.879,135.217,54.8,2026/09/02 15:36:36,Grid connected,230.0,134.734,233.8,134.776,232.9,11.74,736.7,0.00,736.7,11.88,736.7,11.67,741.3,0.00,741.3,11.83,741.3,0.00,741.3,0.00,741.3,11.70,741.3,11.77,737.9,0.00,737.9,117.27
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:45:00,110.054,158.303,55.8,2026/09/02 15:36:36,Grid connected,231.0,157.757,234.9,157.780,233.9,13.77,741.2,0.00,741.2,13.96,741.2,14.09,723.5,0.00,723.5,14.29,723.5,0.00,736.0,0.00,736.0,13.88,736.0,13.90,736.3,0.00,736.3,125.69
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:50:00,164.996,236.198,60.0,2026/09/02 15:36:36,Grid connected,231.0,235.323,236.0,235.150,233.9,20.35,741.4,0.00,741.4,20.73,741.4,20.36,745.8,0.00,745.8,20.52,745.8,0.00,730.6,0.00,730.6,21.59,730.6,21.84,715.1,0.00,715.1,137.92
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 10:55:00,125.522,180.487,63.2,2026/09/02 15:36:36,Grid connected,231.0,179.824,234.9,179.788,233.8,16.39,719.9,0.00,719.9,16.50,719.9,16.39,714.0,0.00,714.0,16.52,714.0,0.00,716.9,0.00,716.9,16.22,716.9,16.14,717.5,0.00,717.5,150.12
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:00:00,103.712,150.058,62.7,2026/09/02 15:36:36,Grid connected,228.7,149.779,233.3,149.572,231.6,13.71,720.8,0.00,720.8,13.85,720.8,13.80,711.1,0.00,711.1,13.79,711.1,0.00,708.9,0.00,708.9,13.47,708.9,13.03,724.2,0.00,724.2,159.64
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:05:00,147.967,213.616,63.0,2026/09/02 15:36:36,Grid connected,228.7,212.941,234.3,212.728,232.6,19.11,722.3,0.00,722.3,19.35,722.3,19.17,723.8,0.00,723.8,19.32,723.8,0.00,716.2,0.00,716.2,19.35,716.2,18.90,728.7,0.00,728.7,169.36
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:10:00,164.299,236.858,66.5,2026/09/02 15:36:36,Grid connected,228.7,236.073,234.3,235.578,232.6,20.02,764.2,0.00,764.2,20.77,764.2,20.38,763.4,0.00,763.4,19.65,763.4,0.00,699.5,0.00,699.5,21.73,699.5,21.80,705.2,0.00,705.2,182.46
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:15:00,159.156,229.658,71.8,2026/09/02 15:36:36,Grid connected,228.7,229.010,234.3,228.604,232.6,19.35,759.2,0.00,759.2,20.33,759.2,19.73,759.5,0.00,759.5,18.92,759.5,0.00,697.9,0.00,697.9,21.84,697.9,21.88,705.2,0.00,705.2,196.05
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:20:00,143.410,207.349,73.6,2026/09/02 15:36:36,Grid connected,228.7,206.784,234.3,206.474,232.6,15.46,781.9,0.00,781.9,16.80,781.9,16.58,779.5,0.00,779.5,15.37,779.5,0.00,737.2,0.00,737.2,21.80,737.2,21.84,733.0,0.00,733.0,208.50
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:25:00,107.596,155.820,73.3,2026/09/02 15:36:36,Grid connected,228.7,155.431,233.2,155.297,231.6,18.32,703.6,0.00,703.6,16.63,703.6,15.08,707.9,0.00,707.9,14.00,707.9,0.00,705.2,0.00,705.2,13.19,705.2,12.82,713.0,0.00,713.0,219.05
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:30:00,112.745,163.110,74.0,2026/09/02 15:36:36,Grid connected,228.7,162.563,234.2,162.469,232.6,14.78,706.3,0.00,706.3,15.05,706.3,14.97,701.2,0.00,701.2,15.09,701.2,0.00,705.2,0.00,705.2,14.93,705.2,15.06,700.1,0.00,700.1,230.73
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:35:00,144.657,208.749,73.4,2026/09/02 15:36:36,Grid connected,228.7,208.047,234.2,207.849,232.6,16.62,782.5,0.00,782.5,17.38,782.5,17.36,778.6,0.00,778.6,16.35,778.6,0.00,758.0,0.00,758.0,19.77,758.0,19.28,760.7,0.00,760.7,241.91
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:40:00,136.587,196.098,73.6,2026/09/02 15:36:36,Grid connected : self derating,229.8,195.356,235.2,195.229,233.7,15.07,774.1,0.00,774.1,16.27,774.1,15.87,774.7,0.00,774.7,15.17,774.7,0.00,741.9,0.00,741.9,19.88,741.9,19.72,744.7,0.00,744.7,253.45
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:45:00,138.073,198.074,73.0,2026/09/02 15:36:36,Grid connected,230.8,197.290,235.2,197.248,233.7,17.75,714.4,0.00,714.4,17.99,714.4,17.82,716.7,0.00,716.7,17.98,716.7,0.00,714.2,0.00,714.2,18.06,714.2,18.02,720.7,0.00,720.7,264.09
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:50:00,129.835,186.708,73.4,2026/09/02 15:36:36,Grid connected,230.8,186.032,235.2,185.996,233.7,16.55,736.5,0.00,736.5,16.77,736.5,16.67,734.6,0.00,734.6,16.72,734.6,0.00,737.6,0.00,737.6,16.50,737.6,16.67,729.2,0.00,729.2,274.87
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 11:55:00,132.979,190.705,73.2,2026/09/02 15:36:36,Grid connected,230.8,189.938,235.2,189.924,234.7,17.97,720.9,0.00,720.9,17.83,720.9,17.54,718.4,0.00,718.4,17.50,718.4,0.00,727.4,0.00,727.4,17.08,727.4,17.03,721.2,0.00,721.2,286.11
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:00:00,145.574,208.354,74.4,2026/09/02 15:36:36,Grid connected,230.8,207.622,236.1,207.478,234.7,16.02,780.6,0.00,780.6,17.48,780.6,17.03,783.2,0.00,783.2,16.18,783.2,0.00,702.8,0.00,702.8,21.75,702.8,21.81,716.9,0.00,716.9,298.06
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:05:00,106.595,152.844,74.3,2026/09/02 15:36:36,Grid connected,230.8,152.410,235.1,152.342,234.7,12.62,723.6,0.00,723.6,13.44,723.6,13.94,719.2,0.00,719.2,14.04,719.2,0.00,726.7,0.00,726.7,13.74,726.7,13.60,729.2,0.00,729.2,308.79
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:10:00,165.000,235.457,72.7,2026/09/02 15:36:36,Grid connected,231.8,234.698,237.3,234.509,235.7,20.61,748.5,0.00,748.5,20.86,748.5,20.70,747.6,0.00,747.6,20.44,747.6,0.00,723.9,0.00,723.9,21.78,723.9,21.75,721.1,0.00,721.1,318.96
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:15:00,134.950,192.973,73.0,2026/09/02 15:36:36,Grid connected,231.8,192.243,236.4,192.219,234.7,17.47,671.4,0.00,671.4,17.73,671.4,16.75,719.2,0.00,719.2,17.19,719.2,0.00,727.8,0.00,727.8,17.35,727.8,18.28,709.8,0.00,709.8,330.24
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:20:00,122.925,176.162,71.7,2026/09/02 15:36:36,Grid connected,230.8,175.593,235.4,175.561,233.7,16.28,723.1,0.00,723.1,16.34,723.1,15.99,729.0,0.00,729.0,15.95,729.0,0.00,647.8,0.00,647.8,17.57,647.8,15.64,730.1,0.00,730.1,339.51
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:25:00,100.389,144.234,71.6,2026/09/02 15:36:36,Grid connected,230.8,143.618,234.4,143.569,233.7,13.03,719.1,0.00,719.1,13.16,719.1,12.70,737.5,0.00,737.5,12.71,737.5,0.00,734.6,0.00,734.6,12.67,734.6,12.68,734.1,0.00,734.1,349.53
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:30:00,124.144,178.010,70.0,2026/09/02 15:36:36,Grid connected,230.8,177.362,235.4,177.301,233.7,16.09,731.1,0.00,731.1,16.14,731.1,15.99,729.1,0.00,729.1,15.99,729.1,0.00,733.6,0.00,733.6,15.72,733.6,15.68,734.1,0.00,734.1,358.70
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:35:00,163.009,232.810,71.4,2026/09/02 15:36:36,Grid connected,231.8,231.914,236.4,231.744,234.7,22.01,716.6,0.00,716.6,21.96,716.6,21.91,720.8,0.00,720.8,21.63,720.8,0.00,721.8,0.00,721.8,21.11,721.8,20.89,719.7,0.00,719.7,370.38
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:40:00,147.698,211.314,72.9,2026/09/02 15:36:36,Grid connected,230.8,210.710,235.4,210.547,234.7,16.41,778.2,0.00,778.2,17.45,778.2,17.11,779.3,0.00,779.3,16.46,779.3,0.00,721.7,0.00,721.7,21.82,721.7,21.86,723.5,0.00,723.5,382.31
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:45:00,147.789,211.884,73.8,2026/09/02 15:36:36,Grid connected,230.8,211.195,235.4,210.997,234.7,16.60,775.9,0.00,775.9,17.60,775.9,17.34,775.8,0.00,775.8,16.57,775.8,0.00,721.7,0.00,721.7,21.78,721.7,21.81,703.5,0.00,703.5,394.29
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:50:00,163.044,233.586,72.7,2026/09/02 15:36:36,Grid connected,231.1,232.841,236.2,232.423,234.9,21.78,703.7,0.00,703.7,21.79,703.7,21.60,717.8,0.00,717.8,21.51,717.8,0.00,728.0,0.00,728.0,20.92,728.0,19.48,747.9,0.00,747.9,403.82
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 12:55:00,68.134,98.254,75.6,2026/09/02 15:36:36,Grid connected,230.1,98.078,233.8,97.934,232.4,8.98,691.6,0.00,691.6,9.14,691.6,8.90,707.4,0.00,707.4,8.97,707.4,0.00,714.2,0.00,714.2,8.85,714.2,8.94,713.1,0.00,713.1,416.33
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:00:00,165.000,234.324,71.9,2026/09/02 15:36:36,Grid connected,232.7,233.558,238.0,233.362,236.3,19.74,771.1,0.00,771.1,20.13,771.1,20.09,769.7,0.00,769.7,19.46,769.7,0.00,742.3,0.00,742.3,21.81,742.3,21.84,716.7,0.00,716.7,424.25
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:05:00,0.000,0.000,74.4,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:10:00,0.000,0.000,73.2,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:15:00,0.000,0.000,71.0,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:20:00,0.000,0.000,68.9,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:25:00,0.000,0.000,67.0,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:30:00,0.000,0.000,65.3,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:35:00,0.000,0.000,63.8,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:40:00,0.000,0.000,62.4,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:45:00,0.000,0.000,61.1,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:50:00,0.000,0.000,60.0,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 13:55:00,0.000,0.000,59.1,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:00:00,0.000,0.000,58.2,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:05:00,0.000,0.000,57.3,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:10:00,0.000,0.000,56.5,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:15:00,0.000,0.000,55.7,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:20:00,0.000,0.000,55.0,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:25:00,0.000,0.000,54.4,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:30:00,0.000,0.000,53.8,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:35:00,0.000,0.000,53.1,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:40:00,0.000,0.000,52.6,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:45:00,0.000,0.000,52.0,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:50:00,0.000,0.000,51.5,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 14:55:00,0.000,0.000,51.1,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:00:00,0.000,0.000,50.7,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:05:00,0.000,0.000,50.3,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:10:00,0.000,0.000,49.9,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:15:00,0.000,0.000,49.6,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:20:00,0.000,0.000,49.2,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:25:00,0.000,0.000,48.9,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:30:00,0.000,0.000,48.6,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:35:00,0.000,0.000,48.3,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:40:00,0.000,0.000,48.0,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:45:00,0.000,0.000,47.8,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:50:00,0.000,0.000,47.5,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 15:55:00,0.000,0.000,47.3,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:00:00,0.000,0.000,47.1,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:05:00,0.000,0.000,46.8,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:10:00,0.000,0.000,46.6,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:20:00,0.000,0.000,46.2,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:25:00,0.000,0.000,46.0,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:30:00,0.000,0.000,45.9,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:35:00,0.000,0.000,45.7,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:40:00,0.000,0.000,45.5,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:45:00,0.000,0.000,45.4,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:50:00,0.000,0.000,45.2,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 16:55:00,0.000,0.000,45.1,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 17:00:00,0.000,0.000,44.9,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 17:05:00,0.000,0.000,44.8,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 17:10:00,0.000,0.000,44.7,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 17:15:00,0.000,0.000,44.5,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 17:20:00,0.000,0.000,44.4,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75
MEIYUME MANUFACTURING,/J.T.N.ENERGY COMPANY LIMITED/SOLARVEST ASSET,Logger-10264G815922/INVERTER-01,2026-09-05 17:25:00,0.000,0.000,44.2,2026/09/05 13:02:49,Standby :  no sunlight,0.0,0.000,0.0,0.000,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,0.00,0.0,429.75

PYEOF

git add .
git commit -m "feat: parse inverter time-series CSV logs deterministically (no LLM call) — detects dead PV strings and extended commanded shutdowns"
git push
