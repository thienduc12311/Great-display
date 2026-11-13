#!/bin/bash
# CI helper: switch to the newest released Xcode installed on the runner
# (betas and release candidates are skipped).
# Set XCODE_PATH to pin a specific one.
set -euo pipefail

# "|| true": with pipefail a listing that matches nothing would end the script
# here, before the fallback below.
XCODE="${XCODE_PATH:-$(ls -d /Applications/Xcode_*.app 2>/dev/null | grep -viE 'beta|candidate' | sort -V | tail -1 || true)}"
if [[ -z "${XCODE}" ]]; then
    XCODE=/Applications/Xcode.app
fi
echo "Using ${XCODE}"
sudo xcode-select -s "${XCODE}/Contents/Developer"
echo "DEVELOPER_DIR=${XCODE}/Contents/Developer" >> "${GITHUB_ENV:-/dev/null}"
xcodebuild -version
swift --version
