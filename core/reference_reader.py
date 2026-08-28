import io
from typing import Any


def extract_reference_context(uploaded_files) -> tuple[str, list[dict[str, Any]]]:
    """อ่านข้อความจาก PDF Reference แบบ optional; ไม่ถือ Reference เป็นหลักฐานหน้างาน"""
    references = []
    context_parts = []
    for file in uploaded_files:
        filename = str(getattr(file, "name", ""))
        if not filename.lower().endswith(".pdf"):
            continue
        item = {"filename": filename, "source": "REFERENCE", "status": "UNREAD"}
        try:
            from pypdf import PdfReader
            file.seek(0)
            reader = PdfReader(io.BytesIO(file.read()))
            file.seek(0)
            text = "\n".join((page.extract_text() or "") for page in reader.pages).strip()
            if text:
                item["status"] = "READ"
                item["pages"] = len(reader.pages)
                context_parts.append(f"REFERENCE DOCUMENT: {filename}\n{text[:12000]}")
            else:
                item["status"] = "NO_TEXT"
        except Exception as error:
            file.seek(0)
            item["status"] = "UNAVAILABLE"
            item["reason"] = type(error).__name__
        references.append(item)
    if not context_parts:
        return "", references
    return "\n\n[REFERENCE ONLY - ไม่ใช่หลักฐานหน้างาน]\n" + "\n\n".join(context_parts), references
