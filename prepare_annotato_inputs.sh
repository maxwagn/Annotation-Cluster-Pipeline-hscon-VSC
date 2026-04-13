#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: bash prepare_annotato_inputs.sh <config.yaml> <output_dir>"
  exit 1
fi

CONFIG_FILE="$1"
OUTDIR="$2"

CONFIG_FILE="$(realpath "$CONFIG_FILE")"
OUTDIR="$(realpath -m "$OUTDIR")"

mkdir -p "$OUTDIR"

echo "[INFO] Config file: $CONFIG_FILE"
echo "[INFO] Output dir:  $OUTDIR"

python - "$CONFIG_FILE" "$OUTDIR" <<'PY'
import csv
import json
import os
import sys
from pathlib import Path

try:
    import yaml
except ImportError:
    sys.stderr.write("ERROR: PyYAML is required. Install it first.\n")
    sys.exit(1)

config_file = Path(sys.argv[1]).resolve()
outdir = Path(sys.argv[2]).resolve()

with open(config_file, "r") as fh:
    cfg = yaml.safe_load(fh)

# ---------------- VALIDATION ----------------
if not isinstance(cfg, dict):
    sys.stderr.write("ERROR: config.yaml must contain a mapping\n")
    sys.exit(1)

required = ["species", "buscodb", "genome", "outdir", "tracedir", "tmpdir", "rnaseq"]
missing = [k for k in required if k not in cfg]
if missing:
    sys.stderr.write(f"ERROR: Missing keys: {', '.join(missing)}\n")
    sys.exit(1)

if not isinstance(cfg["rnaseq"], list):
    sys.stderr.write("ERROR: 'rnaseq' must be a list of sample entries\n")
    sys.exit(1)

# ---------------- PATH HELPER ----------------
def abspath(p):
    if not p:
        return ""
    return str(Path(os.path.expanduser(p)).resolve())

# ---------------- RESOLVE PATHS ----------------
genome = abspath(cfg["genome"])
protein = abspath(cfg.get("protein", ""))
augustus_species = str(cfg.get("augustus_species", "")).strip()

# ---------------- WRITE RNA-SEQ CSV ----------------
csv_path = outdir / "rnaseq_input.csv"

with open(csv_path, "w", newline="") as fh:
    writer = csv.writer(fh)
    writer.writerow(["sample_id", "R1_path", "R2_path", "read_type"])

    for i, sample in enumerate(cfg["rnaseq"], start=1):
        if not isinstance(sample, dict):
            sys.stderr.write(f"ERROR: rnaseq entry #{i} is not a dict\n")
            sys.exit(1)

        for key in ["sample_id", "R1", "read_type"]:
            if key not in sample:
                sys.stderr.write(f"ERROR: rnaseq entry #{i} missing '{key}'\n")
                sys.exit(1)

        writer.writerow([
            sample["sample_id"],
            abspath(sample["R1"]),
            abspath(sample.get("R2", "")),
            sample["read_type"]
        ])

# ---------------- PARAMS.JSON ----------------
params = {
    "species": str(cfg["species"]),
    "buscodb": str(cfg["buscodb"]),
    "genome": genome,
    "rnaseq": str(csv_path),
    "protein": protein,
    "outdir": abspath(cfg["outdir"]),
    "tracedir": abspath(cfg["tracedir"]),
    "tmpdir": abspath(cfg["tmpdir"]),
    "organism": str(cfg.get("organism", "other")),
    "ploidy": int(cfg.get("ploidy", 2)),
    "run_braker": bool(cfg.get("run_braker", False)),
    "skip_rename": bool(cfg.get("skip_rename", False)),
    "skip_all_masking": bool(cfg.get("skip_all_masking", False)),
    "skip_denovo_masking": bool(cfg.get("skip_denovo_masking", False)),
    "skip_functional_annotation": bool(cfg.get("skip_functional_annotation", False)),
    "skip_read_preprocessing": bool(cfg.get("skip_read_preprocessing", False)),
    "augustus_species": augustus_species,
}

# optional fields
if "knownrepeat" in cfg and str(cfg["knownrepeat"]).strip():
    params["knownrepeat"] = abspath(cfg["knownrepeat"])

if "buscoseed" in cfg and str(cfg["buscoseed"]).strip():
    params["buscoseed"] = str(cfg["buscoseed"])

# IMPORTANT: DO NOT include "profile" here

params_file = outdir / "params.json"
with open(params_file, "w") as fh:
    json.dump(params, fh, indent=2)

# ---------------- RUN METADATA ----------------
runmeta = {
    "config_file": str(config_file),
    "output_dir": str(outdir),
    "params_file": str(params_file),
    "rnaseq_csv": str(csv_path),
}

with open(outdir / "runmeta.json", "w") as fh:
    json.dump(runmeta, fh, indent=2)

print(f"[INFO] Created: {params_file}")
print(f"[INFO] Created: {csv_path}")
print(f"[INFO] Created: {outdir / 'runmeta.json'}")
PY
