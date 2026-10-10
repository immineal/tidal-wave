#!/bin/sh
# Prints the test cases the last ctest run in a build directory skipped. A
# skipped case passes, so nothing else shows it.
#   tests/list-skipped.sh build
log="$1/Testing/Temporary/LastTest.log"
[ -f "$log" ] || { echo "no ctest log under $1"; exit 0; }
echo "$(grep -cE '^SKIP ' "$log" || true) test cases were skipped"
grep -E '^SKIP ' "$log" | sort | uniq -c
