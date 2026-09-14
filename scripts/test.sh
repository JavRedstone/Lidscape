#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p build/module-cache
sed '/@main struct LidscapeApp/,$d' Sources/Lidscape.swift > build/TestSupport.swift
swiftc -parse-as-library -module-cache-path build/module-cache build/TestSupport.swift Tests/ProjectionTests.swift -o build/projection-tests
./build/projection-tests

swiftc -parse-as-library -module-cache-path build/module-cache build/TestSupport.swift Tests/BehaviorTests.swift -o build/behavior-tests
./build/behavior-tests

swiftc -parse-as-library -module-cache-path build/module-cache build/TestSupport.swift Tests/BlurTests.swift -o build/blur-tests
./build/blur-tests

swiftc -parse-as-library -module-cache-path build/module-cache build/TestSupport.swift Tests/TimingTests.swift -o build/timing-tests
./build/timing-tests

swiftc -parse-as-library -module-cache-path build/module-cache build/TestSupport.swift Tests/JitterTests.swift -o build/jitter-tests
./build/jitter-tests

swiftc -parse-as-library -module-cache-path build/module-cache build/TestSupport.swift Tests/LifetimeTests.swift -o build/lifetime-tests
./build/lifetime-tests
