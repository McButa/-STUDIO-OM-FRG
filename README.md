# STUDIO OM Solar O&M Engineering Report Generator

A lean Streamlit application for evidence-grounded solar O&M reports. Each job sends its current images, field notes, and reference context through one multimodal master analysis call, validates the structured result, and generates a deterministic DOCX report.

## Architecture

- `router.py`: workflow orchestration, manifest creation, context loading, validation, and DOCX generation.
- `engines/master_engine.py`: single Gemini multimodal synthesis engine.
- `core/vision_client.py`: Gemini client and lossless image preprocessing.
- `core/evidence_validator.py`: Pydantic schema validation and unsupported-root-cause checks.
- `core/docx_generator.py`: deterministic Word report rendering.
- `core/reference_reader.py`: reference document loading.
- `database/db_manager.py`: SQLite audit and approved-report storage.

## Run

```bash
python -m venv .venv
source .venv/bin/activate
python -m pip install -r requirements.txt
streamlit run app.py
```

The engine extracts only visible or explicitly documented evidence. Unreadable or unproven values remain null or `UNCONFIRMED`; historical references cannot become current measurements.
