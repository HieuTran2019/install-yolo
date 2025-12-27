#!/usr/bin/env bash
# env_setup_isolated.sh — YOLO installer with an isolated virtual environment
# - Create venv WITHOUT --system-site-packages
# - Install all Python packages into the venv
# - CUDA toolkit remains at system level (required for Jetson)

set -Eeuo pipefail

# --------------------------- CONFIG ----------------------------------
PYTHON_VERSION="${PYTHON_VERSION:-3.10}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VENV_DIR="${VENV_DIR:-$SCRIPT_DIR/.venv}"
WHEELS_DIR="${WHEELS_DIR:-$SCRIPT_DIR/whls}"
KNOWN_FILE="${KNOWN_FILE:-$SCRIPT_DIR/known_wheels.sh}"

EXTRA_INDEX_URL="${EXTRA_INDEX_URL:-}"
REQ_FILE="${REQ_FILE:-}"

NVCC="/usr/local/cuda/bin/nvcc"

INSTALL_PACKAGES=(
  "ultralytics[export]"
  "onnx"
  "onnxruntime"
  "onnxslim"
  "numpy<2"
)

# ------------------------- UTILITIES ---------------------------------
log()  { printf "\n==> %s\n" "$*"; }
warn() { printf "!! %s\n" "$*" >&2; }
die()  { warn "$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "Missing required command: '$1'"; }

need sudo; need wget; need dpkg; need apt-get; need curl

ARCH="$(uname -m)"
[[ "$ARCH" == "aarch64" ]] || warn "Non-aarch64 host detected ($ARCH). Jetson wheels may not match."

if [[ -f /etc/os-release ]]; then
  . /etc/os-release
  [[ "${VERSION_CODENAME:-}" == "jammy" ]] || warn "Expected Ubuntu 22.04 (jammy); detected ${VERSION_CODENAME:-unknown}"
fi

# ----------------- Detect JetPack (L4T) / CUDA -----------------------
get_jetpack_version() {
  if dpkg -s nvidia-l4t-core >/dev/null 2>&1; then
    dpkg -s nvidia-l4t-core | awk -F': ' '/^Version:/{print $2}'
  elif [[ -r /etc/nv_tegra_release ]]; then
    sed -nE 's/^# R([0-9]+).*/\1/p' /etc/nv_tegra_release
  fi
}

get_cuda_version() {
  if command -v $NVCC >/dev/null 2>&1; then
    $NVCC --version | awk -F'release ' '/release/{print $2}' | awk -F',' '{print $1}'
    return
  fi
  if [[ -f /usr/local/cuda/version.json ]]; then
    grep -oE '"cuda":\s*"[^"]+"' /usr/local/cuda/version.json | sed -E 's/.*"cuda":\s*"([^"]+)".*/\1/'
    return
  fi
  if [[ -f /usr/local/cuda/version.txt ]]; then
    awk '{print $NF}' /usr/local/cuda/version.txt
    return
  fi
}

L4T_VER="$(get_jetpack_version || true)"
CUDA_VER="$(get_cuda_version || true)"
CUDA_MM="$(printf "%s" "${CUDA_VER:-}" | awk -F. '{print $1"."$2}')"

log "Detected L4T / JetPack package version: ${L4T_VER:-unknown}"
log "Detected CUDA version: ${CUDA_VER:-unknown}"

# Ensure CUDA is available
if [[ -z "$CUDA_VER" ]]; then
  die "CUDA not found! Please install JetPack / CUDA at system level first."
fi

# ------------------ Load known wheel mappings ------------------------
declare -a WHEELS_KNOWN=()

if [[ -f "$KNOWN_FILE" ]]; then
  log "Loading wheel mappings from $KNOWN_FILE"
  # shellcheck disable=SC1090
  source "$KNOWN_FILE"

  var_name="KNOWN_WHEELS_${CUDA_MM//./_}"
  if [[ -n "${!var_name:-}" ]]; then
    mapfile -t WHEELS_KNOWN < <(printf "%s\n" "${!var_name}" | sed '/^\s*$/d')
    log "Found ${#WHEELS_KNOWN[@]} predefined wheels for CUDA ${CUDA_MM}."
  else
    warn "No predefined wheels found for CUDA ${CUDA_MM}."
  fi
else
  warn "known_wheels.sh not found; predefined wheel mappings disabled."
fi

# ---------------- CUDA keyring + libcusparselt -----------------------
# Install only required system-level CUDA libraries
log "Installing NVIDIA CUDA keyring and libcusparselt (system level)…"

CUDA_KEYRING_URL="https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2204/arm64/cuda-keyring_1.1-1_all.deb"
CUDA_KEYRING_DEB="cuda-keyring_1.1-1_all.deb"

sudo apt-get update -y
[[ -f "$CUDA_KEYRING_DEB" ]] || wget -q "$CUDA_KEYRING_URL" -O "$CUDA_KEYRING_DEB"

if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
  sudo dpkg -i "$CUDA_KEYRING_DEB"
  sudo apt-get update -y
else
  log "cuda-keyring already installed; skipping"
fi

sudo apt-get install -y --no-install-recommends libcusparselt0 libcusparselt-dev

# ---------------------- uv + Python + venv ---------------------------
if ! command -v uv >/dev/null 2>&1; then
  log "Installing uv…"
  curl -fsSL https://astral.sh/uv/install.sh | sh
  export PATH="$HOME/.local/bin:$PATH"
fi

log "Ensuring Python ${PYTHON_VERSION} is available via uv…"
uv python install "${PYTHON_VERSION}"

if [[ ! -d "${VENV_DIR}" ]]; then
  log "Creating ISOLATED virtual environment at ${VENV_DIR} (no system-site-packages)…"
  uv venv --python "${PYTHON_VERSION}" "${VENV_DIR}"
else
  log "Existing venv found at ${VENV_DIR}; reusing."
fi

PY_BIN="${VENV_DIR}/bin/python"

# Set CUDA paths for building Python packages
export CUDA_HOME="/usr/local/cuda"
export PATH="$CUDA_HOME/bin:$PATH"
export LD_LIBRARY_PATH="$CUDA_HOME/lib64:${LD_LIBRARY_PATH:-}"

log "CUDA_HOME set to: $CUDA_HOME"

# ------------------ Download + verify known wheels -------------------
mkdir -p "${WHEELS_DIR}"
declare -a LOCAL_WHEELS=()

if (( ${#WHEELS_KNOWN[@]} )); then
  log "Fetching and verifying JetPack / CUDA-matched wheels for CUDA ${CUDA_MM}…"

  for url in "${WHEELS_KNOWN[@]}"; do
    file_url="${url%%#*}"
    file_name=$(basename "${file_url}")
    hash_part="${url#*#sha256=}"

    if [[ -z "$hash_part" || "$hash_part" == "$url" ]]; then
      warn "Skipping ${file_name}: missing SHA256 checksum."
      continue
    fi

    file_path="${WHEELS_DIR}/${file_name}"

    if [[ -f "$file_path" ]]; then
      log "Found existing ${file_name}, verifying checksum…"
      if ! printf "%s  %s\n" "${hash_part}" "${file_path}" | sha256sum --check --status; then
        warn "Checksum mismatch. Re-downloading ${file_name}…"
        rm -f "${file_path}"
      else
        log "Checksum OK for ${file_name}."
        LOCAL_WHEELS+=( "$file_path" )
        continue
      fi
    fi

    log "Downloading ${file_name}…"
    if ! wget -q --show-progress "${file_url}" -O "${file_path}"; then
      warn "Download failed for ${file_name}, skipping."
      continue
    fi

    log "Verifying SHA256 for ${file_name}…"
    if ! printf "%s  %s\n" "${hash_part}" "${file_path}" | sha256sum --check --status; then
      warn "Invalid checksum for ${file_name}, skipping."
      rm -f "${file_path}"
      continue
    fi

    log "✓ Verification successful for ${file_name}."
    LOCAL_WHEELS+=( "$file_path" )
  done
fi

# Include any user-provided wheels already present
shopt -s nullglob
for w in "${WHEELS_DIR}"/*.whl; do
  [[ " ${LOCAL_WHEELS[*]} " == *" ${w} "* ]] || LOCAL_WHEELS+=( "$w" )
done
shopt -u nullglob

# ------------------- Install wheels via uv pip -----------------------
if (( ${#LOCAL_WHEELS[@]} )); then
  log "Installing ${#LOCAL_WHEELS[@]} local wheels via uv pip (no dependencies)…"
  uv pip install --python "${PY_BIN}" --no-deps "${LOCAL_WHEELS[@]}"
else
  warn "No valid local wheels found. Falling back to PyPI."
  warn "PyPI PyTorch wheels may NOT include CUDA support for Jetson."
fi

# --------------- Install remaining dependencies ---------------------
log "Installing remaining Python packages into isolated venv…"

PIP_ARGS=( --python "${PY_BIN}" )
[[ -n "${EXTRA_INDEX_URL}" ]] && PIP_ARGS+=( --extra-index-url "${EXTRA_INDEX_URL}" )

if [[ -n "${REQ_FILE}" && -f "${REQ_FILE}" ]]; then
  uv pip install "${PIP_ARGS[@]}" -r "${REQ_FILE}"
fi

if (( ${#INSTALL_PACKAGES[@]} )); then
  uv pip install "${PIP_ARGS[@]}" "${INSTALL_PACKAGES[@]}"
fi

# ------------------- Verify installation -----------------------------
log "Verifying Python environment and packages…"

"${PY_BIN}" -V
"${PY_BIN}" -c "import sys; print(f'Python executable: {sys.executable}')"

log "Installed packages (first 80 entries):"
uv pip list --python "${PY_BIN}" | sed -n '1,80p'

log "Testing CUDA access from Python…"
"${PY_BIN}" -c "
try:
    import torch
    print(f'✓ PyTorch version: {torch.__version__}')
    print(f'✓ CUDA available: {torch.cuda.is_available()}')
    if torch.cuda.is_available():
        print(f'✓ CUDA version: {torch.version.cuda}')
        print(f'✓ Device count: {torch.cuda.device_count()}')
        print(f'✓ Device name: {torch.cuda.get_device_name(0)}')
    else:
        print('✗ CUDA not available in PyTorch!')
        print('  This usually means the PyTorch wheel lacks CUDA support.')
except Exception as e:
    print(f'✗ Error testing PyTorch: {e}')
"

log "Environment ready at ${VENV_DIR}"
echo
echo "==================== IMPORTANT ===================="
echo "✓ Fully ISOLATED virtual environment created"
echo "✓ All Python packages installed INTO the venv"
echo "✓ CUDA toolkit remains at SYSTEM level (required)"
echo
echo "To activate:"
echo "  source '${VENV_DIR}/bin/activate'"
echo
echo "Verify YOLO:"
echo "  yolo version"
echo
echo "If CUDA is not available, you may:"
echo "1. Copy PyTorch wheels from an existing venv (e.g. ~/yolo-venv):"
echo "   cp ~/yolo-venv/lib/python3.10/site-packages/torch* ${WHEELS_DIR}/"
echo "2. Or re-download the correct CUDA-matched wheels"
echo "3. Then re-run this script"
echo "==================================================="
