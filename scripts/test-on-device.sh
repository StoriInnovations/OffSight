#!/bin/bash
# Build and run the on-device test tool (Tools/OffSightTest). Arguments go to offsight-test;
# with none, it runs every automated check. See Tools/OffSightTest/README.md.
set -euo pipefail
cd "$(dirname "$0")/.."
swift build -c release --package-path Tools/OffSightTest
TOOL=Tools/OffSightTest/.build/release/offsight-test
if [[ $# -eq 0 ]]; then
  exec "$TOOL" run
fi
exec "$TOOL" "$@"
