#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
sed '/@main struct LidscapeApp/,$d' Sources/Lidscape.swift > build/TestSupport.swift
swiftc -O -parse-as-library -module-cache-path build/module-cache build/TestSupport.swift Tests/PerformanceCheck.swift -o build/presented-check
./build/presented-check
