#!/bin/bash
set -euo pipefail
# Supply the team's Developer ID Application identity as the first argument.
identity="${1:?Usage: scripts/sign-iscsictl.sh 'Developer ID Application: ... (4A27X5PJP3)'}"
cd "$(dirname "$0")/.."
swift build -c release --product iscsictl --disable-automatic-resolution
codesign --force --options runtime --timestamp --identifier me.herko.iSCSIInitiator.iscsictl --sign "$identity" .build/release/iscsictl
codesign --verify --strict --test-requirement '=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "4A27X5PJP3" and identifier "me.herko.iSCSIInitiator.iscsictl"' .build/release/iscsictl
