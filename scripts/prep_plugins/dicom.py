"""
DICOM plugin — .dcm medical imaging files.

DICOM stores image pixel data + a rich tag dictionary (patient info,
study description, modality, acquisition parameters, free-text
StudyDescription / SeriesDescription / ImageComments / institution /
referring physician etc.). We extract the tag-text content and emit
one chunk per file. Pixel data is ignored (it's image bytes; OCR plugin
handles those if exported separately).

PHI-sensitive fields (patient name, DOB, ID) are scrubbed by default
since most training corpora must stay HIPAA-clean. Set
FORGE_DICOM_KEEP_PHI=1 to preserve them.

Common in dental corpora: anonymized CBCT scan series, panoramic
X-ray exports.
"""
from __future__ import annotations

import os
from pathlib import Path
from typing import Iterator

from .orchestration_helpers import MIN_LEN


# Tags that contain identifiable patient info — scrubbed by default
_PHI_TAGS = frozenset({
    "PatientName", "PatientID", "PatientBirthDate", "PatientAddress",
    "PatientTelephoneNumbers", "OtherPatientIDs", "OtherPatientNames",
    "ReferringPhysicianName", "PhysiciansOfRecord", "PerformingPhysicianName",
    "InstitutionAddress",
})

# Tags that carry the free-text content training cares about
_TEXT_TAGS = (
    "StudyDescription", "SeriesDescription", "Modality", "BodyPartExamined",
    "ProtocolName", "ImageComments", "InstitutionName",
    "ManufacturerModelName", "Manufacturer", "AcquisitionDeviceProcessingDescription",
    "PerformedProcedureStepDescription", "ReasonForTheRequestedProcedure",
    "RequestedProcedureDescription", "AdmittingDiagnosesDescription",
    "PatientHistory", "PatientComments", "AdditionalPatientHistory",
    "ImpressionDescription", "FindingsDescription",
    # Structured-report content (DICOM SR)
    "ContentSequence", "ConceptNameCodeSequence",
)


class _DicomPlugin:
    extensions = (".dcm", ".dicom")
    source_format = "dicom"
    requires = ("pydicom",)
    system_deps = ()
    default_on = True
    disable_env = "FORGE_DISABLE_DICOM"

    def iter_chunks(self, path: Path, section: str, base_id: str, options: dict) -> Iterator[dict]:
        try:
            import pydicom
        except ImportError:
            return  # plugin disabled by missing dep — orchestrator counts this
        try:
            ds = pydicom.dcmread(str(path), stop_before_pixels=True, force=True)
        except Exception:
            return

        keep_phi = os.environ.get("FORGE_DICOM_KEEP_PHI") == "1"
        lines = []
        for tag in _TEXT_TAGS:
            v = getattr(ds, tag, None)
            if v is None:
                continue
            sv = str(v).strip()
            if sv and sv.upper() not in ("UNKNOWN", "NONE", ""):
                lines.append(f"{tag}: {sv}")

        if keep_phi:
            for tag in _PHI_TAGS:
                v = getattr(ds, tag, None)
                if v:
                    lines.append(f"{tag}: {v}")

        text = "\n".join(lines)
        if len(text) < MIN_LEN:
            # Most dental DICOM is sparse-text; emit a metadata-only chunk
            # so the file is still tracked.
            text = (
                f"DICOM file: {path.name} "
                f"(modality={getattr(ds, 'Modality', '?')}, "
                f"series={getattr(ds, 'SeriesDescription', '?')}). "
                f"No substantive free-text fields present."
            )
            chunk_type = "metadata_only"
        else:
            chunk_type = "report"

        yield {
            "id": f"{base_id}-dicom",
            "text": text,
            "format": "pretrain",
            "metadata": {
                "source_file": str(path),
                "source_format": "dicom",
                "section": section,
                "doc_title": path.stem,
                "chunk_type": chunk_type,
                "chunk_idx": 0,
                "char_count": len(text),
                "modality": str(getattr(ds, "Modality", "")),
                "phi_scrubbed": not keep_phi,
            },
        }


PLUGIN = _DicomPlugin()
