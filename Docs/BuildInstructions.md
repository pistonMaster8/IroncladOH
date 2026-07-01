# PostFall — Build Instructions

## Prerequisites

| Tool | Minimum Version | Install |
|---|---|---|
| Xcode | 15.2 | Mac App Store |
| CMake | 3.26 | `brew install cmake` |
| Swift | 5.9 (bundled with Xcode) | — |
| Apple Clang | 15+ (bundled with Xcode) | — |

---

## macOS Game App (Xcode-native)

### Option A: CMake → Xcode project (recommended)

```bash
git clone <repo>
cd post-fall-project

# Generate Xcode project
cmake -B build_xcode -G Xcode -DCMAKE_SYSTEM_NAME=Darwin

# Open in Xcode
open build_xcode/PostFall.xcodeproj
```

In Xcode:
1. Select the `PostFallMac` scheme
2. Set signing team: Targets → PostFallMac → Signing & Capabilities → Team
3. Press ▶ to build and run

### Option B: Command-line build (no UI, for CI)

```bash
xcodebuild -project build_xcode/PostFall.xcodeproj \
           -scheme PostFallMac \
           -configuration Debug \
           build
```

---

## iOS Game App

```bash
cmake -B build_ios -G Xcode \
  -DCMAKE_SYSTEM_NAME=iOS \
  -DCMAKE_OSX_SYSROOT=iphoneos

open build_ios/PostFall.xcodeproj
```

In Xcode:
1. Select the `PostFalliOS` scheme (once created)
2. Select a connected iOS device or simulator
3. Set signing team
4. Press ▶

---

## Dedicated Server (macOS headless)

```bash
# Build
cmake -B build -DCMAKE_BUILD_TYPE=RelWithDebInfo
cd build && make -j$(sysctl -n hw.ncpu) PostFallServer

# Run on local machine
./bin/PostFallServer --port 7777 --dev --verbose

# Run on M4 Mac mini (production)
./bin/PostFallServer --port 7777 --tickrate 60 --log /var/log/postfall/

# Run as background service (macOS launchd)
# See Docs/ServerDeployment.md
```

---

## Tests (headless, no Metal required)

```bash
cmake -B build -DCMAKE_BUILD_TYPE=Debug -DPFGE_BUILD_TESTS=ON
cd build && make -j$(sysctl -n hw.ncpu)
ctest --output-on-failure
```

Individual tests:
```bash
./bin/PhysicsTests
./bin/SimulationTests
./bin/NetworkTests
```

---

## Asset Pipeline

### Cook assets (macOS)

```bash
# Build asset cooker
cd build && make AssetCooker

# Cook all raw assets
./bin/AssetCooker --input ../AssetsRaw --output ../AssetsCooked --platform macos

# For iOS
./bin/AssetCooker --input ../AssetsRaw --output ../AssetsCooked --platform ios
```

### Texture compression dependencies

```bash
brew install ktx-tools    # KTX2 / Basis Universal
# or use the bundled toktx binary from KTX-Software releases
```

---

## Profiling

### Metal Frame Capture
1. Build with Debug or Profile configuration
2. Xcode → Product → Profile → GPU Frame Capture
3. Click the camera icon to capture a frame

### Instruments (CPU/Memory)
```
Xcode → Product → Profile → Instruments
Select: Time Profiler, Allocations, or Energy Log
```

### Address Sanitizer
In Xcode: Scheme → Diagnostics → Address Sanitizer ✓

### Command-line with ASan:
```bash
cmake -B build_asan -DCMAKE_BUILD_TYPE=Debug \
  -DCMAKE_CXX_FLAGS="-fsanitize=address,undefined"
cd build_asan && make PostFallServer
./bin/PostFallServer --dev
```

---

## Hot Reload (macOS development)

The asset system watches `AssetsCooked/` for changes. To trigger a hot reload:
```bash
# Re-cook a single asset
./bin/AssetCooker --single AssetsRaw/Meshes/unit_basic.glb --output AssetsCooked/

# The running game will automatically reload the changed asset
```

---

## Connecting to Local Server for Testing

Three-window loopback test (all on one Mac):

```bash
# Terminal 1: Start server
./bin/PostFallServer --port 7777 --dev

# Terminal 2-4: One per player (dev client connecting to loopback)
# (Client CLI launcher: future tool)
```

Use simulated latency for network testing:
```cpp
// In client code:
transport.SetSimulatedLatencyMs(80.0f);  // simulate 80ms RTT
transport.SetSimulatedLossRate(0.02f);    // 2% packet loss
```
