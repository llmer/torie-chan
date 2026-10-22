#!/bin/bash
# Builds build/make-icon: the app icon and disk image background renderer, which reuses the app's own
# eye drawing code. The one place that lists the app sources it needs.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build
swiftc -O -swift-version 5 \
    Sources/TorieChan/UI/EyesView.swift \
    Sources/TorieChan/UI/EyesModel.swift \
    Sources/TorieChan/Sensors/PersonTracker.swift \
    Sources/TorieChan/Sensors/PeopleTracker.swift \
    scripts/icon/main.swift -o build/make-icon
