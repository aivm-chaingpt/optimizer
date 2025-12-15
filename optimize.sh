#!/bin/ash
# shellcheck shell=dash
# See https://www.shellcheck.net/wiki/SC2187
set -o errexit -o nounset -o pipefail
command -v shellcheck >/dev/null && shellcheck "$0"

export PATH="$PATH:/root/.cargo/bin"

# Record start time
START_TIME=$(date +%s)

# Debug toolchain and default Rust version
rustup toolchain list
cargo --version

# Prepare artifacts directory for later use
mkdir -p artifacts

# Delete previously built artifacts. Those can exist if the image is called
# with a cache mounted to /target. In cases where contracts are removed over time,
# old builds in cache should not be contained in the result of the next build.
rm -f /target/wasm32-unknown-unknown/release/*.wasm

# There are two cases here
# 1. The contract is included in the root workspace (eg. `cosmwasm-template`)
#    In this case, we pass no argument, just mount the proper directory.
# 2. Contracts are excluded from the root workspace, but import relative paths from other packages (only `cosmwasm`).
#    In this case, we mount root workspace and pass in a path `docker run <repo> ./contracts/hackatom`

# This parameter allows us to mount a folder into docker container's "/code"
# and build "/code/contracts/mycontract".
# The default value for $1 is "." (see CMD in the Dockerfile).

# Ensure we get exactly one argument and this is a directory (the path to the Cargo project to be built)
if [ "$#" -ne 1 ] || ! [ -d "$1" ]; then
  echo "Usage: $0 DIRECTORY" >&2
  exit 1
fi
PROJECTDIR="$1"
echo "Building project $(realpath "$PROJECTDIR") ..."
BUILD_START=$(date +%s)
(
  cd "$PROJECTDIR"
  /usr/local/bin/bob
)
BUILD_END=$(date +%s)
BUILD_TIME=$((BUILD_END - BUILD_START))
echo "Build completed in ${BUILD_TIME}s"

echo "Optimizing artifacts in parallel ..."
OPT_START=$(date +%s)

# Collect all wasm files
WASM_FILES=""
WASM_COUNT=0
for WASM in /target/wasm32-unknown-unknown/release/*.wasm; do
  [ -e "$WASM" ] || continue
  WASM_FILES="$WASM_FILES $WASM"
  WASM_COUNT=$((WASM_COUNT + 1))
done

if [ "$WASM_COUNT" -gt 0 ]; then
  echo "Found $WASM_COUNT wasm file(s), optimizing with $(nproc) parallel jobs ..."
  # --signext-lowering is needed to support blockchains running CosmWasm < 1.3. It can be removed eventually
  echo "$WASM_FILES" | tr ' ' '\n' | xargs -P "$(nproc)" -I {} sh -c '
    WASM="{}"
    OUT_FILENAME=$(basename "$WASM")
    echo "Optimizing $OUT_FILENAME ..."
    wasm-opt -Oz --signext-lowering "$WASM" -o "artifacts/$OUT_FILENAME"
  '
fi
OPT_END=$(date +%s)
OPT_TIME=$((OPT_END - OPT_START))
echo "Optimization completed in ${OPT_TIME}s"

echo "Post-processing artifacts..."
(
  cd artifacts

  if test -n "$(find . -maxdepth 1 -name '*.wasm' -print -quit)"; then
    sha256sum -- *.wasm | tee checksums.txt
  else
    echo "Warn: No .wasm file built. Check your build configuration in Cargo.toml."
  fi
)

END_TIME=$(date +%s)
TOTAL_TIME=$((END_TIME - START_TIME))
echo "Done. Total time: ${TOTAL_TIME}s (build: ${BUILD_TIME}s, optimization: ${OPT_TIME}s)"
