#!/bin/bash
# Points the Homebrew cask at a release: scripts/update-cask.sh <version> <disk image sha256>
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="$1"
SHA="$2"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$SHA" =~ ^[0-9a-f]{64}$ ]] || { echo "usage: $0 <x.y.z> <sha256>" >&2; exit 1; }
CASK=packaging/homebrew/torie-chan.rb
sed -i '' -E "s/^  version \"[^\"]+\"/  version \"$VERSION\"/; s/^  sha256 \"[0-9a-f]+\"/  sha256 \"$SHA\"/" "$CASK"
grep -E '^  (version|sha256) ' "$CASK"
