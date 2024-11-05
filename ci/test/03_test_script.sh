#!/usr/bin/env bash
#
# Copyright (c) 2018-present The Bitcoin Core developers
# Distributed under the MIT software license, see the accompanying
# file COPYING or http://www.opensource.org/licenses/mit-license.php.

export LC_ALL=C.UTF-8

set -ex

export ASAN_OPTIONS="detect_leaks=1:detect_stack_use_after_return=1:check_initialization_order=1:strict_init_order=1"
export LSAN_OPTIONS="suppressions=${BASE_ROOT_DIR}/test/sanitizer_suppressions/lsan"
export TSAN_OPTIONS="suppressions=${BASE_ROOT_DIR}/test/sanitizer_suppressions/tsan:halt_on_error=1"
export UBSAN_OPTIONS="suppressions=${BASE_ROOT_DIR}/test/sanitizer_suppressions/ubsan:print_stacktrace=1:halt_on_error=1:report_error_type=1"

if [ "$CI_OS_NAME" == "macos" ]; then
  top -l 1 -s 0 | awk ' /PhysMem/ {print}'
  echo "Number of CPUs: $(sysctl -n hw.logicalcpu)"
else
  free -m -h
  echo "Number of CPUs (nproc): $(nproc)"
  echo "System info: $(uname --kernel-name --kernel-release)"
  lscpu
fi
echo "Free disk space:"
df -h

# What host to compile for. See also ./depends/README.md
# Tests that need cross-compilation export the appropriate HOST.
# Tests that run natively guess the host
export HOST=${HOST:-$("$BASE_ROOT_DIR/depends/config.guess")}

(
  # compact->outputs[i].file_size is uninitialized memory, so reading it is UB.
  # The statistic bytes_written is only used for logging, which is disabled in
  # CI, so as a temporary minimal fix to work around UB and CI failures, leave
  # bytes_written unmodified.
  # See https://github.com/bitcoin/bitcoin/pull/28359#issuecomment-1698694748
  # Tee patch to stdout to make it clear CI is testing modified code.
  tee >(patch -p1) <<'EOF'
--- a/src/leveldb/db/db_impl.cc
+++ b/src/leveldb/db/db_impl.cc
@@ -1028,9 +1028,6 @@ Status DBImpl::DoCompactionWork(CompactionState* compact) {
       stats.bytes_read += compact->compaction->input(which, i)->file_size;
     }
   }
-  for (size_t i = 0; i < compact->outputs.size(); i++) {
-    stats.bytes_written += compact->outputs[i].file_size;
-  }

   mutex_.Lock();
   stats_[compact->compaction->level() + 1].Add(stats);
EOF
)



if [ "$USE_BUSY_BOX" = "true" ]; then
  echo "Setup to use BusyBox utils"
  # tar excluded for now because it requires passing in the exact archive type in ./depends (fixed in later BusyBox version)
  # ar excluded for now because it does not recognize the -q option in ./depends (unknown if fixed)
  for util in $(busybox --list | grep -v "^ar$" | grep -v "^tar$" ); do ln -s "$(command -v busybox)" "${BINS_SCRATCH_DIR}/$util"; done
  # Print BusyBox version
  patch --help
fi

# Make sure default datadir does not exist and is never read by creating a dummy file
if [ "$CI_OS_NAME" == "macos" ]; then
  echo > "${HOME}/Library/Application Support/Groestlcoin"
else
  echo > "${HOME}/.groestlcoin"
fi

if [ -z "$NO_DEPENDS" ]; then
  if [[ $CI_IMAGE_NAME_TAG == *centos* ]]; then
    # Use bash for GRS
    SHELL_OPTS="CONFIG_SHELL=/bin/bash"
  else
    SHELL_OPTS="CONFIG_SHELL="
  fi
  bash -c "$SHELL_OPTS make $MAKEJOBS -C depends HOST=$HOST $DEP_OPTS LOG=1"
fi
if [ "$DOWNLOAD_PREVIOUS_RELEASES" = "true" ]; then
  test/get_previous_releases.py -b -t "$PREVIOUS_RELEASES_DIR"
fi

GROESTLCOIN_CONFIG_ALL="--disable-dependency-tracking"
if [ -z "$NO_DEPENDS" ]; then
  GROESTLCOIN_CONFIG_ALL="${GROESTLCOIN_CONFIG_ALL} CONFIG_SITE=$DEPENDS_DIR/$HOST/share/config.site"
fi
if [ -z "$NO_WERROR" ]; then
  GROESTLCOIN_CONFIG_ALL="${GROESTLCOIN_CONFIG_ALL} --enable-werror"
fi

ccache --zero-stats
PRINT_CCACHE_STATISTICS="ccache --version | head -n 1 && ccache --show-stats"

GROESTLCOIN_CONFIG_ALL="${GROESTLCOIN_CONFIG_ALL} --enable-external-signer --prefix=$BASE_OUTDIR"

if [ -n "$CONFIG_SHELL" ]; then
  "$CONFIG_SHELL" -c "./autogen.sh"
else
  ./autogen.sh
fi

mkdir -p "${BASE_BUILD_DIR}"
cd "${BASE_BUILD_DIR}"

bash -c "${BASE_ROOT_DIR}/configure --cache-file=config.cache $GROESTLCOIN_CONFIG_ALL $GROESTLCOIN_CONFIG" || ( (cat config.log) && false)

make distdir VERSION="$HOST"

cd "${BASE_BUILD_DIR}/groestlcoin-$HOST"

bash -c "./configure --cache-file=../config.cache $GROESTLCOIN_CONFIG_ALL $GROESTLCOIN_CONFIG" || ( (cat config.log) && false)

if [[ "${RUN_TIDY}" == "true" ]]; then
  MAYBE_BEAR="bear --config src/.bear-tidy-config"
  MAYBE_TOKEN="--"
fi

bash -c "${MAYBE_BEAR} ${MAYBE_TOKEN} make $MAKEJOBS $GOAL" || ( echo "Build failure. Verbose build follows." && make "$GOAL" V=1 ; false )

bash -c "${PRINT_CCACHE_STATISTICS}"
du -sh "${DEPENDS_DIR}"/*/
du -sh "${PREVIOUS_RELEASES_DIR}"

if [[ $HOST = *-mingw32 ]]; then
  # Generate all binaries, so that they can be wrapped
  make "$MAKEJOBS" -C src/secp256k1 VERBOSE=1
  #make "$MAKEJOBS" -C src minisketch/test.exe VERBOSE=1
  "${BASE_ROOT_DIR}/ci/test/wrap-wine.sh"
fi
