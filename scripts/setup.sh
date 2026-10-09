#!/usr/bin/env bash
# Debian/Ubuntu, including WSL. Always use project-owned tools and fresh installs.
set -euo pipefail

root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$root"
proofs=1
system=1
for option in "$@"; do
  case "$option" in
    --native-only) proofs=0 ;;
    --skip-system) system=0 ;;
    *) echo "Usage: bash scripts/setup.sh [--native-only] [--skip-system]" >&2; exit 2 ;;
  esac
done
[[ $(uname -s) == Linux ]] || { echo 'Run setup on Linux (WSL on Windows).' >&2; exit 2; }
case $(uname -m) in
  x86_64) bend_arch=x64; lean_arch=linux ;;
  aarch64|arm64) bend_arch=arm64; lean_arch=linux_aarch64 ;;
  *) echo 'Supported architectures: x86_64 and aarch64.' >&2; exit 2 ;;
esac

if (( system )); then
  command -v apt-get >/dev/null || { echo 'Setup requires Debian/Ubuntu apt-get.' >&2; exit 2; }
  elevate=()
  if (( EUID != 0 )); then elevate=(sudo); fi
  "${elevate[@]}" apt-get update
  "${elevate[@]}" apt-get install -y --no-install-recommends \
    ca-certificates curl git clang g++ libc6-dev python3 python3-venv zstd
fi

# The gitlink, rather than the submodule's latest branch, determines Edlib.
git_command=(git)
# Windows Git stores an absolute Windows path in a linked worktree's .git file.
# Translate it for WSL without modifying the checkout or its Git metadata.
if [[ -f .git ]] && grep -Eq '^gitdir: [A-Za-z]:[/\\]' .git; then
  git_dir=$(wslpath -u "$(sed -n 's/^gitdir: //p' .git | tr -d '\r')")
  git_command+=(--git-dir="$git_dir" --work-tree="$root")
fi
"${git_command[@]}" submodule sync --recursive
"${git_command[@]}" submodule update --init --recursive

bend_version=$(tr -d '\r\n' < .bend-version)
lean_version=$(tr -d '\r\n' < .lean-version)
tools="$root/build/tools"
mkdir -p "$tools" "$root/build/downloads"
export BEND_NO_TELEMETRY=1

install_archive() {
  local project=$1 version=$2 asset=$3 destination=$4 expected staging
  expected=$(awk -v asset="$asset" '$2 == asset {print $1}' scripts/tools.sha256)
  [[ $expected =~ ^[0-9a-f]{64}$ ]] || { echo "Missing checksum for $asset" >&2; exit 2; }
  # Download even when build/ already exists; a partial or stale install cannot win.
  curl --fail --location --retry 3 --connect-timeout 30 \
    "https://github.com/$project/releases/download/v$version/$asset" \
    -o "build/downloads/$asset"
  printf '%s  %s\n' "$expected" "build/downloads/$asset" | sha256sum --check --strict
  staging=$(mktemp -d "$tools/.install.XXXXXX")
  tar -xf "build/downloads/$asset" --strip-components=1 -C "$staging"
  # The only replaceable destinations are these project-owned tool directories.
  [[ $destination == "$tools/bend" || $destination == "$tools/lean" ]]
  rm -rf -- "$destination"
  mv -- "$staging" "$destination"
}

install_archive bendlang/bend "$bend_version" \
  "bend-$bend_version-linux-$bend_arch.tar.gz" "$tools/bend"
export PATH="$tools/bend/bin:$PATH"
native_path=$PATH
[[ $(bend version) == "bend $bend_version" ]]
bend guide > build/bend-guide.txt

if (( proofs )); then
  install_archive leanprover/lean4 "$lean_version" \
    "lean-$lean_version-$lean_arch.tar.zst" "$tools/lean"
  export PATH="$tools/lean/bin:$PATH"
  lean --version | grep -F "Lean (version $lean_version,"
  # Build explicitly: no ~/.elan toolchain or ~/.bend kernel cache is consulted.
  mkdir -p "$tools/kernel"
  cp "$tools/bend/bend2/bendtt.lean" "$tools/kernel/bendtt.lean"
  (
    cd "$tools/kernel"
    lean -c bendtt.c bendtt.lean
    leanc -O3 -DNDEBUG bendtt.c -o bendtt
  )
  # Lean bundles a Clang intended for leanc; it lacks the system C headers
  # Bend needs. Expose it only while building the proof kernel.
  export PATH="$native_path"
fi

python3 -c 'import sys; assert sys.version_info >= (3, 10), "Python 3.10+ required"'
# --clear also prevents packages left over from an older lock file being used.
python3 -m venv --clear build/test-venv
build/test-venv/bin/python -m pip install --disable-pip-version-check -r requirements-test.txt
build/test-venv/bin/python -m pip check

{
  bend version
  clang --version
  g++ --version
  build/test-venv/bin/python --version
  build/test-venv/bin/python -m pip freeze
  "${git_command[@]}" submodule status --recursive
  if (( proofs )); then "$tools/lean/bin/lean" --version; fi
} > build/environment.txt
if (( proofs )); then
  echo 'Setup complete. Run: python3 run_tests.py --alignment --verdict'
else
  echo 'Native setup complete. Run: python3 run_tests.py -v'
fi
