#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: bash setup.sh <project_annotation_dir> <config_yaml>"
  exit 1
fi

PROJECT_DIR="$(realpath -m "$1")"
CONFIG_YAML="$(realpath "$2")"

SOFTWARE_DIR="$PROJECT_DIR/software"
PIPELINES_DIR="$SOFTWARE_DIR/pipelines"
REPO_DIR="$PIPELINES_DIR/erga-pipelines"
PIPELINE_DIR="$REPO_DIR/annotation/nextflow"
CONTAINER_CONFIG="$PIPELINE_DIR/conf/container.config"

INPUTS_DIR="$PROJECT_DIR/annotato_inputs"
RESULTS_DIR="$PROJECT_DIR/annotato_results"
TRACE_DIR="$PROJECT_DIR/annotato_trace"
TMP_DIR="$PROJECT_DIR/annotato_tmp"

CLUSTER_OVERRIDE="$PROJECT_DIR/cluster_override.config"

FUNANNOTATE_OVERRIDE_IMAGE="docker://nextgenusfs/funannotate:v1.8.17"
FUNANN_FILE="$PIPELINE_DIR/modules/local/funannotate/FunannotatePredict.nf"
BRAKER_FILE="$PIPELINE_DIR/modules/local/braker/Braker.nf"

echo "[INFO] Project dir:   $PROJECT_DIR"
echo "[INFO] Config file:   $CONFIG_YAML"

module load Nextflow

# ---------------------------
# Read settings from config.yaml
# ---------------------------
eval "$(
python - "$CONFIG_YAML" <<'PY'
import os
import sys
import yaml

with open(sys.argv[1]) as fh:
    cfg = yaml.safe_load(fh)

runtime = cfg.get("runtime", {})
nextflow = cfg.get("nextflow", {})

def val(x, default):
    return str(x if x is not None else default)

user = os.environ.get("USER", "user")

print(f'MAX_CPUS="{val(runtime.get("max_cpus"), 24)}"')
print(f'MAX_TIME="{val(runtime.get("max_time"), "7d")}"')
print(f'CONTAINER_CACHE_DIR="{val(runtime.get("container_cache_dir"), f"/scratch/{user}/apptainer_cache")}"')
print(f'CONTAINER_TMP_DIR="{val(runtime.get("container_tmp_dir"), "/tmp")}"')
print(f'NXF_WORK_DIR="{val(nextflow.get("work_dir"), f"/tmp/{user}_annotato_work")}"')

print(f'BUSCO_DB="{val(cfg.get("buscodb"), "")}"')
print(f'AUGUSTUS_SPECIES="{val(cfg.get("augustus_species"), "")}"')
print(f'FUNANNOTATE_DB_DIR="{val(cfg.get("funannotate_db_dir"), "")}"')
PY
)"

if [[ -z "${BUSCO_DB:-}" ]]; then
  echo "[ERROR] buscodb is missing in config.yaml"
  exit 1
fi

if [[ -z "${AUGUSTUS_SPECIES:-}" ]]; then
  echo "[ERROR] augustus_species is missing in config.yaml"
  exit 1
fi

if [[ -z "${FUNANNOTATE_DB_DIR:-}" ]]; then
  echo "[ERROR] funannotate_db_dir is missing in config.yaml"
  exit 1
fi

FUNANNOTATE_DB_DIR="$(realpath -m "$FUNANNOTATE_DB_DIR")"
FUNANNOTATE_DB_MOUNT="/opt/databases"

# ---------------------------
# Export environment
# ---------------------------
export APPTAINER_TMPDIR="$CONTAINER_TMP_DIR"
export SINGULARITY_TMPDIR="$CONTAINER_TMP_DIR"

export APPTAINER_CACHEDIR="$CONTAINER_CACHE_DIR"
export SINGULARITY_CACHEDIR="$CONTAINER_CACHE_DIR"
export NXF_SINGULARITY_CACHEDIR="$CONTAINER_CACHE_DIR"
export NXF_APPTAINER_CACHEDIR="$CONTAINER_CACHE_DIR"

export NXF_OPTS="-Xms=512m -Xmx=3g"

mkdir -p "$CONTAINER_CACHE_DIR"
mkdir -p "$NXF_WORK_DIR"
mkdir -p "$PIPELINES_DIR"
mkdir -p "$INPUTS_DIR" "$RESULTS_DIR" "$TRACE_DIR" "$TMP_DIR"

echo "[INFO] MAX_CPUS=$MAX_CPUS"
echo "[INFO] MAX_TIME=$MAX_TIME"
echo "[INFO] CACHE=$CONTAINER_CACHE_DIR"
echo "[INFO] TMP=$CONTAINER_TMP_DIR"
echo "[INFO] NXF_WORK=$NXF_WORK_DIR"
echo "[INFO] BUSCO DB=$BUSCO_DB"
echo "[INFO] AUGUSTUS species=$AUGUSTUS_SPECIES"
echo "[INFO] Funannotate DB dir=$FUNANNOTATE_DB_DIR"
echo "[INFO] Funannotate override image=$FUNANNOTATE_OVERRIDE_IMAGE"

# ---------------------------
# Clone repo if needed
# ---------------------------
if [[ ! -d "$REPO_DIR/.git" ]]; then
  echo "[INFO] Cloning ERGA pipelines repository"
  git clone https://github.com/ERGA-consortium/pipelines.git "$REPO_DIR"
else
  echo "[INFO] Repository already exists"
fi

# ---------------------------
# Validate pipeline
# ---------------------------
if [[ ! -f "$PIPELINE_DIR/main.nf" ]]; then
  echo "[ERROR] main.nf not found"
  exit 1
fi

if [[ ! -f "$CONTAINER_CONFIG" ]]; then
  echo "[ERROR] container.config not found"
  exit 1
fi

if [[ ! -f "$FUNANN_FILE" ]]; then
  echo "[ERROR] FunannotatePredict.nf not found: $FUNANN_FILE"
  exit 1
fi

if [[ ! -f "$BRAKER_FILE" ]]; then
  echo "[ERROR] Braker.nf not found: $BRAKER_FILE"
  exit 1
fi

# ---------------------------
# Validate shared/local Funannotate DB
# ---------------------------
echo "[INFO] Checking Funannotate database"

if [[ ! -d "$FUNANNOTATE_DB_DIR" ]]; then
  echo "[ERROR] funannotate_db_dir does not exist:"
  echo "  $FUNANNOTATE_DB_DIR"
  echo "[ERROR] Please create it first and install the required BUSCO dataset."
  exit 1
fi

if [[ ! -d "$FUNANNOTATE_DB_DIR/$BUSCO_DB" ]]; then
  echo "[ERROR] Requested BUSCO dataset not found:"
  echo "  $FUNANNOTATE_DB_DIR/$BUSCO_DB"
  echo "[ERROR] The value of buscodb in config.yaml must exactly match the folder name in funannotate_db_dir."
  exit 1
fi

if [[ ! -f "$FUNANNOTATE_DB_DIR/$BUSCO_DB/lengths_cutoff" ]]; then
  echo "[ERROR] BUSCO dataset is incomplete:"
  echo "  missing $FUNANNOTATE_DB_DIR/$BUSCO_DB/lengths_cutoff"
  exit 1
fi

if [[ ! -f "$FUNANNOTATE_DB_DIR/$BUSCO_DB/scores_cutoff" ]]; then
  echo "[ERROR] BUSCO dataset is incomplete:"
  echo "  missing $FUNANNOTATE_DB_DIR/$BUSCO_DB/scores_cutoff"
  exit 1
fi

if [[ ! -f "$FUNANNOTATE_DB_DIR/$BUSCO_DB/dataset.cfg" ]]; then
  echo "[ERROR] BUSCO dataset is incomplete:"
  echo "  missing $FUNANNOTATE_DB_DIR/$BUSCO_DB/dataset.cfg"
  exit 1
fi

if [[ ! -d "$FUNANNOTATE_DB_DIR/trained_species/$AUGUSTUS_SPECIES" ]]; then
  echo "[ERROR] AUGUSTUS trained species not found:"
  echo "  $FUNANNOTATE_DB_DIR/trained_species/$AUGUSTUS_SPECIES"
  echo "[ERROR] Make sure the base Funannotate database was copied correctly."
  exit 1
fi

echo "[INFO] Funannotate DB looks valid"
echo "[INFO] ✔ BUSCO dataset found: $BUSCO_DB"
echo "[INFO] ✔ AUGUSTUS species found: $AUGUSTUS_SPECIES"

# ---------------------------
# Patch FunannotatePredict.nf
# ---------------------------
echo "[INFO] Applying Funannotate compatibility fixes"

FUNANN_PATCHED=false

if grep -Fq 'containerOptions = "--bind ${params.tmpdir}:/opt/databases"' "$FUNANN_FILE"; then
  cp "$FUNANN_FILE" "${FUNANN_FILE}.bak" 2>/dev/null || true
  sed -i 's|containerOptions = "--bind ${params.tmpdir}:/opt/databases"|containerOptions = ""|' "$FUNANN_FILE"
  echo "[PATCH] ✔ Disabled tmpdir -> /opt/databases bind in Funannotate"
  FUNANN_PATCHED=true
fi

python - "$FUNANN_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()

old = r"""augustus_species=\$(echo ${species} | sed 's/ /_/g')"""
new = r'''augustus_species="${params.augustus_species}"'''

if old in text:
    text = text.replace(old, new)
    path.write_text(text)
    print("[PATCH] ✔ Using config-defined augustus_species in Funannotate")
else:
    print("[INFO] Funannotate augustus_species already patched or pattern not found")
PY

if grep -Eq '^[[:space:]]*funannotate setup -l -w -b ' "$FUNANN_FILE"; then
  python - "$FUNANN_FILE" <<'PY'
from pathlib import Path
import re
import sys

path = Path(sys.argv[1])
text = path.read_text()
text = re.sub(
    r'^(?P<indent>[ \t]*)funannotate setup -l -w -b (?P<rest>[^\n]+)$',
    r'\g<indent># patched by setup.sh: DB handled from funannotate_db_dir\n\g<indent># funannotate setup -l -w -b \g<rest>',
    text,
    flags=re.MULTILINE
)
path.write_text(text)
PY
  echo "[PATCH] ✔ Disabled funannotate setup (DB handled externally)"
  FUNANN_PATCHED=true
fi

echo "[INFO] Patched Funannotate lines:"
grep -n 'containerOptions\|augustus_species\|opt/databases' "$FUNANN_FILE" || true

# ---------------------------
# Patch Braker.nf
# ---------------------------
echo "[INFO] Applying BRAKER compatibility fixes"

BRAKER_PATCHED=false

python - "$BRAKER_FILE" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text()
orig = text

text = text.replace(
    'containerOptions = "--bind /env:/env --bind ${params.tmpdir}:/opt/databases"',
    'containerOptions = ""'
)

text = text.replace(
    'containerOptions = "--bind ${params.tmpdir}:/opt/databases"',
    'containerOptions = ""'
)

text = text.replace(
    r"""augustus_species=\$(echo ${species} | sed 's/ /_/g')""",
    r'''augustus_species="${params.augustus_species}"'''
)

if text != orig:
    path.write_text(text)
    print("[PATCH] ✔ BRAKER module updated")
else:
    print("[INFO] BRAKER module already patched or patterns not found")
PY

echo "[INFO] Patched BRAKER lines:"
grep -n 'containerOptions\|augustus_species\|opt/databases\|/env' "$BRAKER_FILE" || true

# ---------------------------
# Write cluster override config
# ---------------------------
echo "[INFO] Writing cluster_override.config"

cat > "$CLUSTER_OVERRIDE" <<EOF
params {
  max_time = '${MAX_TIME}'
}

singularity {
  enabled = true
  cacheDir = '${CONTAINER_CACHE_DIR}'
  pullTimeout = '60m'
  runOptions = '--bind ${FUNANNOTATE_DB_DIR}:${FUNANNOTATE_DB_MOUNT}'
}

workDir = '${NXF_WORK_DIR}'

executor {
  name = 'local'
  cpus = ${MAX_CPUS}
}

process {
  withName: REPEATMODELER {
    cpus = 12
    time = '${MAX_TIME}'
  }

  withLabel: process_high {
    cpus = 12
  }

  withLabel: process_medium_high {
    cpus = 8
  }

  withLabel: process_medium {
    cpus = 6
  }

  withLabel: process_low {
    cpus = 2
  }

  withLabel: process_single {
    cpus = 1
  }

  withName: 'ANNOTATO:GENE_PREDICTION_FUNANNOTATE' {
    container = '${FUNANNOTATE_OVERRIDE_IMAGE}'
    cpus = 12
    time = '${MAX_TIME}'
    env.FUNANNOTATE_DB = '${FUNANNOTATE_DB_MOUNT}'
  }
}
EOF

# ---------------------------
# Clean stale caches
# ---------------------------
echo "[INFO] Cleaning stale caches"
rm -rf ~/.apptainer/cache ~/.singularity/cache || true
find "$CONTAINER_CACHE_DIR" -name "*.pulling*" -delete || true
rm -rf "$CONTAINER_CACHE_DIR/cache/oci-tmp/"* 2>/dev/null || true

# ---------------------------
# Extract container list
# ---------------------------
mapfile -t CONTAINERS < <(
  grep -oP 'container\s*=\s*"\K[^"]+' "$CONTAINER_CONFIG" | sort -u
)

if [[ ${#CONTAINERS[@]} -eq 0 ]]; then
  echo "[ERROR] No containers found"
  exit 1
fi

if ! printf '%s\n' "${CONTAINERS[@]}" | grep -Fxq "$FUNANNOTATE_OVERRIDE_IMAGE"; then
  CONTAINERS+=("$FUNANNOTATE_OVERRIDE_IMAGE")
fi

echo "[INFO] Found ${#CONTAINERS[@]} containers"

# ---------------------------
# Helper: image name -> filename
# ---------------------------
container_to_filename() {
  local image="$1"
  image="${image#docker://}"
  image="${image//\//-}"
  image="${image//:/-}"
  printf '%s.img' "$image"
}

# ---------------------------
# Pre-pull containers
# ---------------------------
echo "[INFO] Pre-pulling containers"

for image in "${CONTAINERS[@]}"; do
  image="${image#docker://}"
  target="$CONTAINER_CACHE_DIR/$(container_to_filename "$image")"

  if [[ -f "$target" ]]; then
    if apptainer inspect "$target" >/dev/null 2>&1; then
      echo "[INFO] OK: $(basename "$target")"
      continue
    else
      echo "[WARN] Removing corrupt image"
      rm -f "$target"
    fi
  fi

  echo "[INFO] Pulling docker://$image"
  apptainer pull \
    --dir "$CONTAINER_CACHE_DIR" \
    --name "$(basename "$target")" \
    "docker://$image"
done

# ---------------------------
# Done
# ---------------------------
cat <<EOF

[INFO] Setup complete

Pipeline:
  $PIPELINE_DIR

Patched files:
  $FUNANN_FILE
  $BRAKER_FILE

Nextflow work directory:
  $NXF_WORK_DIR

Funannotate DB:
  $FUNANNOTATE_DB_DIR

Requested BUSCO lineage:
  $BUSCO_DB

Requested AUGUSTUS species:
  $AUGUSTUS_SPECIES

Run:
  nextflow run $PIPELINE_DIR/main.nf \
    -params-file $INPUTS_DIR/params.json \
    -profile local,singularity \
    -c $CLUSTER_OVERRIDE

Resume if failed:
  nextflow run $PIPELINE_DIR/main.nf \
    -params-file $INPUTS_DIR/params.json \
    -profile local,singularity \
    -c $CLUSTER_OVERRIDE \
    -resume

EOF
