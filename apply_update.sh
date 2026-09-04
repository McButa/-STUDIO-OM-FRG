#!/bin/bash
set -e
cd /workspaces/-STUDIO-OM-FRG

mkdir -p core tests engines

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

from core.docx_generator import build_docx
from core.evidence_validator import coerce_float, validate_report
from core.job_manifest import build_manifest, manifest_summary
from core.reference_reader import extract_reference_context
from core.threshold_rules import apply_measurement_thresholds, apply_peer_comparison, derive_plant_totals, detect_cross_source_conflicts, reconcile_narrative_with_findings
from database.db_manager import get_plant_history_context, get_previous_audit_kpis, get_similar_cases_context
from engines.master_engine import run_master_analysis
from engines.verification_engine import run_critical_verification

PROMPT_VERSION = "2026-09-03-master-v4-threshold-rules"
REPORT_SCHEMA_VERSION = "2.1"


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
    report = run_master_analysis(uploaded_files, api_key, site_context, knowledge_context + reference_context, lang=lang, plant_name=context_plant or None)
    report = derive_plant_totals(report)
    report, status_hard_locked = _enforce_engineering_rules(report)
    report, measurement_locked = apply_measurement_thresholds(report)
    report = apply_peer_comparison(report)
    report = detect_cross_source_conflicts(report)
    report = reconcile_narrative_with_findings(report)
    status_hard_locked = status_hard_locked or measurement_locked
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

cat > engines/master_engine.py << 'PYEOF'
import json
from datetime import date

from core.vision_client import execute_gemini_vision, optimize_image

MASTER_ENGINE_PROMPT = """
You are the STUDIO OM Solar O&M Engineering Synthesis Engine.
Analyze only the current uploaded evidence and field notes. Historical/reference material is context, never current evidence.
DO NOT invent numbers or default to template examples. Extract only visible numbers, labels, and text.
If a value, diagnosis, cause, or action is not visible or proven, use null or "UNCONFIRMED".
A root cause is proven only by explicit alarm text, measurement evidence, EL evidence, or insulation test evidence.
Keep observed_data separate from engineering_diagnosis. Cross-correlate independent evidence sources.

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

CRITICAL INACTION DAMAGE ANALYSIS:
For each major or critical issue found, analyze the consequential equipment damage that WILL OCCUR if neglected (e.g. Ground fault -> Inverter MPPT power board fire/short-circuit costing 80,000-150,000 THB vs 500-1,500 THB MC4 repair; Hotspot -> Cell delamination/shattered glass costing 4,500-9,000 THB module replacement vs 0-500 THB cleaning).
Output damage and prevention costs as RAW NUMBERS ONLY (no commas, no currency symbols, no text) in min_damage_cost_thb, max_damage_cost_thb, min_prevention_cost_thb, max_prevention_cost_thb.

If current evidence shows normal operation, 0 alarms, no hotspots, and normal measured currents, set overall_status strictly to NORMAL.
For a normal operation result, set corrective_actions, spare_parts_tools, and inaction_damage_matrix to one entry stating: "ระบบทำงานสมบูรณ์ตามเกณฑ์มาตรฐาน ไม่พบความผิดปกติที่ต้องซ่อมแซมเร่งด่วน".
If any LCD, meter screen, or thermal scale is blurry, dark, or cropped, state: "ภาพไม่ชัดเจน/ไม่สามารถอ่านค่าเชิงตัวเลขได้ แนะนำให้บันทึกภาพซ้ำหน้างาน".
FIELD_NOTES.txt is optional; analyze visual and meter evidence when notes are absent.

Return JSON only using exactly this schema:
{
  "plant_summary": {
    "plant_name": "string",
    "rated_capacity_kw": "string",
    "audit_date": "string",
    "overall_status": "CRITICAL|WARNING|NORMAL",
    "active_power_kw": "string",
    "grid_current_a": "string"
  },
  "executive_summary": "string",
  "evidence_findings": [
    {
      "category": "Inverter & Monitoring|Field Alarms|String Electrical|Thermography|Visual Survey",
      "source_file": "string",
      "observed_data": "string",
      "engineering_diagnosis": "string",
      "severity": "CRITICAL|WARNING|NORMAL|INFORMATIONAL",
      "key_measurements": [
        {"parameter": "string (see fixed vocabulary above)", "value": 0, "unit": "string", "comparator": "=|>|<"}
      ]
    }
  ],
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
    {
      "issue": "string",
      "description": "string",
      "supporting_evidence": "string"
    }
  ],
  "corrective_actions": [
    {
      "step_number": 1,
      "title": "string",
      "actions": ["string"]
    }
  ],
  "spare_parts_tools": [
    {
      "item_name": "string",
      "recommended_qty": "string",
      "purpose": "string"
    }
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


def run_master_analysis(uploaded_files, api_key: str, site_context: str = "", knowledge_context: str = "", lang: str = "th", plant_name: str | None = None) -> dict:
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
        [{"text": f"{MASTER_ENGINE_PROMPT}\n{context}"}, *_file_parts(uploaded_files)],
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

from core.threshold_rules import apply_measurement_thresholds, apply_peer_comparison, derive_plant_totals, detect_cross_source_conflicts, reconcile_narrative_with_findings
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

git add .
git commit -m "fix: peer/total calculations no longer polluted by multi-inverter batch test files; reconcile narrative text with escalated findings"
git push
