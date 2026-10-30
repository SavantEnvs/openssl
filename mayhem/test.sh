#!/usr/bin/env bash
#
# mayhem/test.sh — RUN the functional oracle (already built by mayhem/build.sh with NORMAL flags):
# (1) known-answer checks through the freshly built `openssl` CLI (asserted digests/MACs/ciphertext/ASN.1
#     output, so a neutered/no-op library or CLI fails them), then
# (2) a fixed subset of upstream's own perl test recipes via test/run_tests.pl (no compiling here).

set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}


TB="$SRC/mayhem/build-tests"
O="$TB/apps/openssl"
[ -x "$O" ] || { echo "test.sh: $O missing — mayhem/build.sh should have built it" >&2; emit_ctrf openssl-kat 0 1 0; exit 1; }
export OPENSSL_CONF=/dev/null
P=0; F=0

check() {  # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then P=$((P+1)); else F=$((F+1)); echo "FAIL $1: expected [$2] got [$3]" >&2; fi
}
hex() { od -An -tx1 | tr -d ' \n'; }

check sha256-abc  "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad" "$(printf abc | "$O" dgst -sha256 -r 2>/dev/null | cut -d' ' -f1)"
check sha1-abc    "a9993e364706816aba3e25717850c26c9cd0d89d" "$(printf abc | "$O" dgst -sha1 -r 2>/dev/null | cut -d' ' -f1)"
check md5-abc     "900150983cd24fb0d6963f7d28e17f72" "$(printf abc | "$O" dgst -md5 -r 2>/dev/null | cut -d' ' -f1)"
check sha512-abc  "ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f" "$(printf abc | "$O" dgst -sha512 -r 2>/dev/null | cut -d' ' -f1)"
check sha3-256-abc "3a985da74fe225b2045c172d6bd390bd855f086e3e9d525b46bfe24511431532" "$(printf abc | "$O" dgst -sha3-256 -r 2>/dev/null | cut -d' ' -f1)"
check hmac-sha256-rfc4231 "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843" "$(printf 'what do ya want for nothing?' | "$O" dgst -sha256 -hmac Jefe -r 2>/dev/null | cut -d' ' -f1)"
check aes128-ecb-fips197 "69c4e0d86a7b0430d8cdb78070b4c55a" "$(printf '\x00\x11\x22\x33\x44\x55\x66\x77\x88\x99\xaa\xbb\xcc\xdd\xee\xff' | "$O" enc -aes-128-ecb -K 000102030405060708090a0b0c0d0e0f -nopad 2>/dev/null | hex)"
check base64-encode "TWFu" "$(printf Man | "$O" base64 2>/dev/null)"
check base64-decode "Man" "$(printf 'TWFu\n' | "$O" base64 -d 2>/dev/null)"
check prime-97 "61 (97) is prime" "$("$O" prime 97 2>/dev/null)"
check prime-91 "5B (91) is not prime" "$("$O" prime 91 2>/dev/null)"
check asn1parse-int "INTEGER           :07" "$(printf '\x30\x06\x02\x01\x05\x02\x01\x07' | "$O" asn1parse -inform DER 2>/dev/null | tail -1 | sed 's/.*prim: //')"
check x509-subject "subject=CN=Root CA" "$("$O" x509 -in "$SRC/test/certs/root-cert.pem" -noout -subject 2>/dev/null)"
check x509-sha256-fingerprint "sha256 Fingerprint=BB:84:C7:81:92:4C:01:36:5E:65:AE:27:CE:26:DF:D5:D4:B8:F2:FD:57:60:CD:27:D3:0F:E7:8E:5A:B7:3F:1A" "$("$O" x509 -in "$SRC/test/certs/root-cert.pem" -noout -fingerprint -sha256 2>/dev/null)"

W="$(mktemp -d)"; trap 'rm -rf "$W"' EXIT
printf 'known message' > "$W/msg"; printf 'tampered message' > "$W/bad"
"$O" pkey -in "$SRC/test/certs/ee-key.pem" -pubout -out "$W/pub.pem" 2>/dev/null
"$O" dgst -sha256 -sign "$SRC/test/certs/ee-key.pem" -out "$W/sig" "$W/msg" 2>/dev/null
check rsa-verify-good "Verified OK" "$("$O" dgst -sha256 -verify "$W/pub.pem" -signature "$W/sig" "$W/msg" 2>/dev/null)"
check rsa-verify-bad  "Verification failure" "$("$O" dgst -sha256 -verify "$W/pub.pem" -signature "$W/sig" "$W/bad" 2>/dev/null | head -1)"
check verify-chain "$SRC/test/certs/ee-cert.pem: OK" "$("$O" verify -CAfile "$SRC/test/certs/root-cert.pem" -untrusted "$SRC/test/certs/ca-cert.pem" "$SRC/test/certs/ee-cert.pem" 2>/dev/null)"

# Upstream's own recipes (known-answer/data-driven: evp_test vectors, bn, ec, rsa, x509, ml-dsa, ...).
TESTS="test_sha test_hmac test_evp_kdf test_dgst test_bn test_rsa test_x509_check_cert_pkey test_ml_dsa test_ec test_enc test_x509 test_evp"
cd "$TB"
OUT="$(SRCTOP="$SRC" BLDTOP="$TB" PERL=/usr/bin/perl EXE_EXT= HARNESS_JOBS="$MAYHEM_JOBS" \
        /usr/bin/perl "$SRC/test/run_tests.pl" $TESTS 2>&1)"
echo "$OUT" | tail -25
N="$(echo "$OUT" | sed -n 's/^Files=[0-9]*, Tests=\([0-9]*\),.*/\1/p' | tail -1)"
if [ -n "$N" ] && [ "$N" -gt 400 ] && echo "$OUT" | grep -q '^Result: PASS'; then
  P=$((P+N))
else
  F=$((F+1)); echo "FAIL upstream recipes (tests=${N:-none})" >&2
fi

emit_ctrf openssl-kat-and-recipes "$P" "$F" 0
