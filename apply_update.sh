#!/bin/bash
set -e
cd /workspaces/-STUDIO-OM-FRG

mkdir -p core tests

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

    conn.close()PYEOF

cat > router.py << 'PYEOF'
import hashlib
import uuid
from datetime import datetime, timezone

from core.docx_generator import build_docx
from core.evidence_validator import coerce_float, validate_report
from core.job_manifest import build_manifest, manifest_summary
from core.reference_reader import extract_reference_context
from core.threshold_rules import apply_measurement_thresholds, derive_plant_totals, detect_cross_source_conflicts
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
    p_act = coerce_float(summary.get("active_power_kw")) or 0.0
    p_rated = coerce_float(summary.get("rated_capacity_kw")) or 0.0
    i_grid = coerce_float(summary.get("grid_current_a")) or 0.0

    findings_text = " ".join([
        f"{f.get('observed_data', '')} {f.get('engineering_diagnosis', '')}"
        for f in report.get("evidence_findings", []) if isinstance(f, dict)
    ]).lower()

    hard_locked = False
    # Rule 1: Zero Grid Current or severe power drop (<5%) -> Lock to CRITICAL
    if (p_rated > 0 and (p_act / p_rated) < 0.05 and i_grid == 0) or "grid a/b/c phase current: 0" in findings_text or "grid current: 0" in findings_text or "grid current เป็น 0" in findings_text:
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
    report = detect_cross_source_conflicts(report)
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
    return report, document, report_type, site_contextPYEOF

cat > core/threshold_rules.py << 'PYEOF'
"""
Deterministic measurement-threshold rules.

Why this file exists: severity used to be decided entirely by the LLM inside
one JSON call (engines/master_engine.py). Two runs on the exact same
Insulation Resistance reading (0.836 MOhm) came back NORMAL once and WARNING
once, because nothing in code ever checked the number itself. This module
fixes that class of bug for measured, numeric values.

Design goal (token/maintenance cost): a NEW failure mode that is expressed as
"a named quantity crossed a known numeric line" should only require adding one
entry to MEASUREMENT_RULES below — no prompt edits, no router changes, no new
functions. Only genuinely new *kinds* of check (e.g. cross-source conflicts,
which aren't a single threshold) need new code, and that already lives here
too (see `detect_cross_source_conflicts`).

Severity is only ever UPGRADED by these rules, never downgraded — an LLM call
that already flagged something worse is left alone; a rule only steps in when
the LLM under-called a measured value that crosses a known safety line.
"""

import re

SEVERITY_RANK = {"NORMAL": 0, "INFORMATIONAL": 0, "WARNING": 1, "CRITICAL": 2}


def _higher(a: str, b: str) -> str:
    return a if SEVERITY_RANK.get(a, 0) >= SEVERITY_RANK.get(b, 0) else b


# --- Table of deterministic rules --------------------------------------
# Each rule finds `label_pattern` in a finding's observed_data/engineering_
# diagnosis text, reads the following number (handling a leading > or <),
# and maps it to a severity via `thresholds` (checked in order, first
# match wins). `applies_to_category` restricts which evidence_findings rows
# the rule scans, so a rule for a monitoring reading doesn't misfire on a
# paper Megger row using the same word.
MEASUREMENT_RULES = [
    {
        "name": "insulation_resistance_live",
        "applies_to_category": "Inverter & Monitoring",
        "label_pattern": re.compile(
            r"insulation\s*resistance|ค่าฉนวน|ความต้านทานฉนวน|\briso\b",
            re.IGNORECASE,
        ),
        "value_pattern": re.compile(r"(>|<)?\s*([\d.]+)\s*(?:m\W?ohm|m\W?\u03a9|megaohm)", re.IGNORECASE),
        # (comparator, limit, severity) — value compared against limit.
        "thresholds": [("<", 0.5, "CRITICAL"), ("<", 1.0, "WARNING")],
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


def _rule_severity(value: float, sign, thresholds):
    if sign == ">":
        # A ">1000" reading is a lower bound: the true value is at least this
        # high, so it can only be unsafe if the bound itself is already
        # below the tightest limit (rare, but don't silently ignore it).
        pass
    elif sign == "<":
        # A "<X" reading is an upper bound: the true value could be far
        # below X, so evaluate against X directly (conservative).
        pass
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
        text = f"{finding.get('observed_data', '')} {finding.get('engineering_diagnosis', '')}"
        for rule in MEASUREMENT_RULES:
            if finding.get("category") != rule["applies_to_category"]:
                continue
            if not rule["label_pattern"].search(text):
                continue
            value, sign = _extract_value(text, rule["value_pattern"])
            if value is None:
                continue
            rule_severity = _rule_severity(value, sign, rule["thresholds"])
            if not rule_severity:
                continue
            current = finding.get("severity", "NORMAL")
            new_severity = _higher(current, rule_severity)
            if new_severity != current:
                finding["severity"] = new_severity
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


# --- Cross-source conflict detection ------------------------------------
# Not a single-number threshold, so it earns its own function rather than a
# MEASUREMENT_RULES entry — but it's still fully deterministic (no LLM call).

_INVERTER_RANGE = re.compile(r"inv[_-]?(\d+)\s*-\s*(\d+)", re.IGNORECASE)
_INVERTER_SINGLE = re.compile(r"inv[_-]?(\d+)(?!\s*-)", re.IGNORECASE)
_RISO_VALUE = re.compile(r"(>|<)?\s*([\d.]+)\s*(?:m\W?ohm|m\W?\u03a9)", re.IGNORECASE)


def _inverter_ids(source_file: str):
    range_match = _INVERTER_RANGE.search(source_file)
    if range_match:
        start, end = int(range_match.group(1)), int(range_match.group(2))
        return list(range(start, end + 1))
    single_match = _INVERTER_SINGLE.search(source_file)
    if single_match:
        return [int(single_match.group(1))]
    return []


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
        text = f"{finding.get('observed_data', '')} {finding.get('engineering_diagnosis', '')}"
        value, sign = _extract_value(text, _RISO_VALUE)
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
            })

    if conflicts:
        report["evidence_findings"] = findings + conflicts
        summary = report.get("plant_summary", {})
        summary["overall_status"] = _higher(summary.get("overall_status", "NORMAL"), "WARNING")
        report["plant_summary"] = summary

    return report


# --- Deterministic recovery for plant-level totals -----------------------
# The LLM sometimes writes real per-inverter numbers in evidence_findings but
# answers "UNCONFIRMED" for the plant-level total anyway (it has to sum 6+
# separate readings correctly in the same pass as everything else). Summing
# is a Python problem, not an LLM judgment call — do it deterministically
# whenever the per-item numbers are actually present.

_ACTIVE_POWER = re.compile(r"active\s*power[:\s]*([\d.]+)\s*kw", re.IGNORECASE)
_UNRESOLVED_VALUES = {None, "", "unconfirmed", "n/a", "null"}


def derive_plant_totals(report: dict) -> dict:
    summary = report.get("plant_summary", {})
    current = summary.get("active_power_kw")
    current_str = str(current).strip().lower() if current is not None else ""
    if current_str not in _UNRESOLVED_VALUES:
        return report  # Gemini already gave a usable number — don't second-guess it

    findings = report.get("evidence_findings", [])
    if not isinstance(findings, list):
        return report

    per_inverter_kw = []
    for finding in findings:
        if not isinstance(finding, dict) or finding.get("category") != "Inverter & Monitoring":
            continue
        text = f"{finding.get('observed_data', '')} {finding.get('engineering_diagnosis', '')}"
        match = _ACTIVE_POWER.search(text)
        if match:
            per_inverter_kw.append(float(match.group(1)))

    # Only fill in the total when every inverter reading is present — a
    # partial sum (e.g. 4 of 6 units) would silently understate output,
    # which is worse than honestly leaving it UNCONFIRMED.
    inverter_findings = [f for f in findings if isinstance(f, dict) and f.get("category") == "Inverter & Monitoring"]
    if per_inverter_kw and len(per_inverter_kw) == len(inverter_findings):
        summary["active_power_kw"] = str(round(sum(per_inverter_kw), 3))
        report["plant_summary"] = summary

    return report
PYEOF

cat > tests/test_threshold_rules.py << 'PYEOF'
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
if str(ROOT) not in sys.path:
    sys.path.insert(0, str(ROOT))

from core.threshold_rules import apply_measurement_thresholds, derive_plant_totals, detect_cross_source_conflicts
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


# --- Coverage for router's existing hard-coded rules (previously untested) --

def test_zero_grid_current_locks_critical():
    report = {
        "plant_summary": {"overall_status": "NORMAL", "active_power_kw": "0.1", "rated_capacity_kw": "500", "grid_current_a": "0"},
        "evidence_findings": [],
    }
    report, locked = _enforce_engineering_rules(report)
    assert report["plant_summary"]["overall_status"] == "CRITICAL"
    assert locked is True


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

git add .
git commit -m "fix: sum active_power_kw from per-inverter readings when Gemini leaves plant total UNCONFIRMED"
git push
