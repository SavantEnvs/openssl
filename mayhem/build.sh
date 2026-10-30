#!/usr/bin/env bash
#
# mayhem/build.sh — build OpenSSL's libFuzzer harnesses (fuzz/*.c, the same set OSS-Fuzz builds) against a
# sanitized, coverage-instrumented static libcrypto/libssl, plus the NORMAL-flags build that test.sh runs.
# Runs inside the commit image as `mayhem` in /mayhem. Re-runnable and network-free (OpenSSL needs only perl).
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — it must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
M="$SRC/mayhem"
FB="$M/build-fuzz"
BIN="$M/bin"
mkdir -p "$FB" "$BIN"

# Coverage instrumentation goes into the LIBRARY (not only the harness TU), unconditionally.
# Two UBSan checks are relaxed, everything else (and ASan) stays on and halting:
#  - alignment: as OSS-Fuzz does for OpenSSL; hash/cipher cores deliberately do unaligned loads.
#  - function: OpenSSL routinely calls through casted function pointers (e.g. bio_prov.c -> ossl_core_bio_ctrl),
#    which clang-19's -fsanitize=function aborts on the very first input of most harnesses.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -fno-sanitize=alignment,function -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION"

# 1) Sanitized static libs (out of tree, so the NORMAL build below can share the source tree).
cd "$FB"
if [ ! -f configdata.pm ]; then
  "$SRC/config" --banner=Configured no-shared enable-fuzz-libfuzzer \
    enable-tls1_3 enable-rc5 enable-md2 enable-ec_nistp_64_gcc_128 \
    enable-nextprotoneg enable-weak-ssl-ciphers $FUZZ_CFLAGS
fi
make -j"$MAYHEM_JOBS" build_libs

# 2) Harnesses: compile each TU once, link once with libFuzzer and once with the run-once standalone driver.
# The sanitizer-coverage callbacks come from the ASan runtime or libFuzzer; the weak stub keeps the
# standalone reproducer linkable when SANITIZER_FLAGS is empty.
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$M/lsan_off.c" -o "$FB/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$M/sancov_stub.c" -o "$FB/sancov_stub.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$FB/standalone_main.o"
INC="-I$SRC -I$SRC/include -I$FB -I$FB/include -I$SRC/fuzz"
LIBS="$FB/libssl.a $FB/libcrypto.a -ldl -pthread"
objc() { $CC $FUZZ_CFLAGS $INC -c "$1" -o "$2"; }
objc "$SRC/fuzz/driver.c" "$FB/driver.o"
objc "$SRC/fuzz/fuzz_rand.c" "$FB/fuzz_rand.o"

build_one() {
  local name="$1" rand="$2" extra=""
  [ "$rand" = 1 ] && extra="$FB/fuzz_rand.o"
  objc "$SRC/fuzz/$name.c" "$FB/h_$name.o"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "$FB/h_$name.o" "$FB/driver.o" $extra "$FB/lsan_off.o" \
      $LIBS $LIB_FUZZING_ENGINE -o "$BIN/$name"
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS "$FB/h_$name.o" "$FB/driver.o" $extra "$FB/lsan_off.o" \
      "$FB/standalone_main.o" "$FB/sancov_stub.o" $LIBS -o "$BIN/$name-standalone"
}
while read -r name rand; do
  build_one "$name" "$rand" &
  while [ "$(jobs -rp | wc -l)" -ge "$MAYHEM_JOBS" ]; do wait -n || true; done
done < "$M/harnesses.txt"
wait
while read -r name rand; do
  for b in "$BIN/$name" "$BIN/$name-standalone"; do
    [ -x "$b" ] || { echo "build.sh: missing $b" >&2; exit 1; }
  done
done < "$M/harnesses.txt"

# 3) The NORMAL-flags build the functional oracle runs (no sanitizers, no -gdwarf-3, no coverage build flags
# beyond the optional COVERAGE_FLAGS).
TB="$M/build-tests"
mkdir -p "$TB"
cd "$TB"
if [ ! -f configdata.pm ]; then
  env -u CFLAGS -u LDFLAGS "$SRC/config" --banner=Configured no-shared $COVERAGE_FLAGS
fi
# Separate invocations: naming both targets at once lets make compile libcrypto objects twice in parallel.
make -j"$MAYHEM_JOBS" build_programs
make -j"$MAYHEM_JOBS" build_modules link-utils
