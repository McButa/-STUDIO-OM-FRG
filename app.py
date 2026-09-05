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
        "ลากไฟล์หลักฐานหน้างาน, notes.txt, ไฟล์ CSV ข้อมูลอินเวอร์เตอร์ และเอกสารอ้างอิง PDF มาวางที่นี่",
        accept_multiple_files=True,
        type=["jpg", "jpeg", "png", "webp", "txt", "pdf", "csv"],
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
