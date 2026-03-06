#!/bin/zsh
# jb_patch_autotest.sh — run full setup_machine flow for each JB kernel patch method.
# Strategy: apply each single JB kernel method on top of the dev baseline, one case at a time.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
cd "$PROJECT_ROOT"

LOG_ROOT="${PROJECT_ROOT}/setup_logs/jb_patch_tests_$(date +%Y%m%d_%H%M%S)"
SUMMARY_CSV="${LOG_ROOT}/summary.csv"
MASTER_LOG="${LOG_ROOT}/run.log"
INCLUDE_WORKING="${JB_AUTOTEST_INCLUDE_WORKING:-0}"

mkdir -p "$LOG_ROOT"
touch "$MASTER_LOG"

if [[ -x "${PROJECT_ROOT}/.venv/bin/python3" ]]; then
  PYTHON_BIN="${PROJECT_ROOT}/.venv/bin/python3"
else
  PYTHON_BIN="$(command -v python3)"
fi

PATCH_METHODS=("${(@f)$(
  cd "${PROJECT_ROOT}/scripts" && "$PYTHON_BIN" - <<'PY'
import os
from patchers.kernel_jb import KernelJBPatcher

def _env_enabled(name, default=False):
    raw = os.environ.get(name)
    if raw is None:
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}

include_working = _env_enabled("JB_AUTOTEST_INCLUDE_WORKING", default=False)
all_methods = list(getattr(KernelJBPatcher, "_PATCH_METHODS", ()))
if include_working:
    selected_methods = all_methods
else:
    working = set(getattr(KernelJBPatcher, "_DEV_SINGLE_WORKING_METHODS", ()))
    selected_methods = [m for m in all_methods if m not in working]

for method in selected_methods:
    print(method)
PY
)}")

if (( ${#PATCH_METHODS[@]} == 0 )); then
  echo "[*] No JB patch methods selected (all already marked working or list empty)" | tee -a "$MASTER_LOG"
  echo "[*] Set JB_AUTOTEST_INCLUDE_WORKING=1 to run the full list." | tee -a "$MASTER_LOG"
  exit 0
fi

echo "index,patch,status,exit_code,log_file" >"$SUMMARY_CSV"
echo "[*] JB patch single-method automation started" | tee -a "$MASTER_LOG"
echo "[*] Logs: $LOG_ROOT" | tee -a "$MASTER_LOG"
echo "[*] Include already-working methods: ${INCLUDE_WORKING}" | tee -a "$MASTER_LOG"
echo "[*] Total methods: ${#PATCH_METHODS[@]}" | tee -a "$MASTER_LOG"

idx=0
for patch_method in "${PATCH_METHODS[@]}"; do
  (( ++idx ))
  case_log="${LOG_ROOT}/$(printf '%02d' "$idx")_${patch_method}.log"

  {
    echo ""
    echo "============================================================"
    echo "[*] [$idx/${#PATCH_METHODS[@]}] Testing PATCH=${patch_method}"
    echo "============================================================"
  } | tee -a "$MASTER_LOG"

  set +e
  # Test matrix assumption: each JB kernel method is validated on top of dev patch baseline.
  case_skip_project_setup="${SKIP_PROJECT_SETUP:-1}"
  echo "[*] Env: NONE_INTERACTIVE=1 DEV=1 SKIP_PROJECT_SETUP=${case_skip_project_setup} PATCH=${patch_method}" | tee -a "$MASTER_LOG"
  SUDO_PASSWORD="${SUDO_PASSWORD:-}" \
  NONE_INTERACTIVE=1 \
  DEV=1 \
  SKIP_PROJECT_SETUP="${case_skip_project_setup}" \
  PATCH="$patch_method" \
  make setup_machine >"$case_log" 2>&1
  rc=$?
  set -e

  if (( rc == 0 )); then
    case_status="PASS"
  else
    case_status="FAIL"
  fi

  echo "${idx},${patch_method},${case_status},${rc},${case_log}" >>"$SUMMARY_CSV"
  echo "[*] Result: ${case_status} (rc=${rc}) log=${case_log}" | tee -a "$MASTER_LOG"
done

echo ""
echo "[*] Completed JB patch automation. Summary: $SUMMARY_CSV" | tee -a "$MASTER_LOG"
