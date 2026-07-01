# PostFall Engine — Technical Architecture

## 1. Language and Platform Decision

### Language: C++20 with Swift/ObjC++ shells

**Chosen: C++20 engine core, Swift 5.9+ app shells, Objective-C++ bridging.**

Rust was considered and rejected for this project. The decisive factors:

| Concern | C++20 | Rust |
|---|---|---|
| Metal integration | Objective-C++ .mm files, zero friction | FFI-only, requires bindgen or cxx crate; CAMetalLayer/MTKView integration non-trivial |
| Xcode debugger | First-class LLDB integration, Metal Frame Capture just works | LLDB support decent, but no Xcode-native Metal Frame Capture integration |
| Swift interop | Direct C++ interop (Swift 5.9+) or ObjC++ bridge | No direct Swift↔Rust; requires C FFI layer |
| iOS deployment | Fully supported, no extra steps | Supported via cross-compilation, but App Store requires static linking and specific toolchain |
| Compile times | Moderate; precompiled headers available | Fast incremental, slower cold builds for large projects |
| ECS/data-oriented | Well-established patterns, Cache-friendly with arrays | Borrow checker complicates self-referential ECS; workarounds (arenas, generational indices) add friction |
| Memory safety | RAII, smart pointers, sanitizers (-fsanitize=address,undefined) | Language-enforced |
| Tooling | Xcode instruments, Metal Frame Capture, Address Sanitizer, Undefined Behavior Sanitizer | Good standalone tools but less integrated with Apple toolchain |

**Safety mitigations for C++:**
- RAII ownership everywhere; raw pointers only at narrow Metal API boundaries
- AddressSanitizer enabled in Debug builds
- UndefinedBehaviorSanitizer enabled in Debug builds
- All platform/unsafe boundaries clearly marked with comments
- `clang-tidy` and `-Wall -Wextra -Wpedantic` in CI

---

## 2. Repository Structure

```
/Engine/Core             — Types, math (SIMD), logging, handles, arena allocator
/Engine/Platform         — OS abstraction (future: window, display link)
/Engine/Renderer         — IRenderer interface; RenderScene snapshot type
/Engine/Renderer/Metal   — Metal-first renderer (Objective-C++)
/Engine/Assets           — AssetID, manifest, cooked mesh/texture/material types
/Engine/Simulation       — ECS World, ComponentStorage, all Components, GameSim
/Engine/Physics          — PhysicsSystem: projectile gravity/bounce/sleep
/Engine/Input            — InputSystem: keyboard, mouse, touch, controller
/Engine/UI               — DebugOverlay (Metal-rendered HUD)
/Engine/Audio            — AudioSystem stub (future AVAudioEngine or FMOD)
/Engine/Network          — Transport/Protocol/Replication/Lobby
/Engine/Server           — ServerInstance: headless authoritative simulation
/Engine/AI               — AISystem: FSM + utility scorer + perception
/Engine/AI/Pathfinding   — Grid-based A* pathfinding
/Apps/MacGame            — Swift/SwiftUI + ObjC++ macOS application
/Apps/iOSGame            — Swift/SwiftUI + ObjC++ iOS application (same engine)
/Apps/DedicatedServer    — Headless C++ server binary
/Samples/StrategyPrototype — Example top-down scene
/AssetsRaw               — Source assets (glTF 2.0, PNG, etc.) — NOT loaded at runtime
/AssetsCooked            — Offline-cooked binary assets
/Docs                    — Architecture, pipeline, deployment
/Tests                   — Headless unit tests (no renderer required)
/Tools/AssetCooker       — Offline asset compiler: glTF → cooked mesh, KTX2 → ASTC/BC7
```

---

## 3. Hardware / Fidelity Target Table

Data from Apple developer statistics, TelemetryDeck iOS surveys, and Steam Hardware Survey Mac (2025–2026).

### Active iPhone install base (2026 inference)
- A15 (iPhone 13/14, SE3): ~35% of active iPhones
- A16 (iPhone 14 Pro, 15): ~25%
- A17 Pro (iPhone 15 Pro): ~15%
- A18/A18 Pro (iPhone 16): ~20%
- Older than A15: ~5% (excluded from support)

**Safe minimum baseline: iPhone 13 / A15 Bionic (GPU family Apple8)**

### Active Mac install base
- M1 (MacBook Air/Pro 2020-2021): ~30% of Apple Silicon Macs
- M2 (MacBook Air/Pro 2022-2023): ~35%
- M3: ~20%
- M4: ~15% and growing rapidly

**Safe minimum baseline: M1 (GPU family Apple7)**

### Metal GPU family feature mapping
| Hardware | GPU Family | Mesh Shaders | Tile Shaders | Full BC | Raytracing |
|---|---|---|---|---|---|
| M1 / M1 Pro/Max | Apple7 | No | Yes | Runtime check | No |
| A15, A16, M2 | Apple8 | No | Yes | Runtime check | No |
| A17 Pro, A18, M3, M4 | Apple9 | Yes | Yes | Yes | Yes |

### Performance budgets

| Metric | iPhone 13 (A15) 60 FPS | iPhone 15 Pro (A17) 60 FPS | M1 Mac 60 FPS | M4 Mac 120 FPS |
|---|---|---|---|---|
| Frame budget | 16.7 ms | 16.7 ms | 16.7 ms | 8.3 ms |
| Max units on screen | 50 | 80 | 100 | 150 |
| Triangles/basic unit | 2,500 | 4,000 | 5,000 | 10,000 |
| Triangles/hero unit | 5,000 | 8,000 | 12,000 | 20,000 |
| Triangles/building | 1,500 | 3,000 | 5,000 | 8,000 |
| Max projectiles | 20 | 40 | 64 | 100 |
| Draw calls/frame | ≤250 | ≤400 | ≤500 | ≤800 |
| Shadow map resolution | 512×512 | 1024×1024 | 1024×1024 | 2048×2048 |
| Texture tier (units) | 512×512 ASTC | 1024×1024 ASTC | 1024×1024 BC7 | 2048×2048 BC7 |
| GPU memory budget | 512 MB | 1 GB | 1.5 GB | 3 GB |
| System memory budget | 256 MB | 512 MB | 512 MB | 1 GB |

### Texture format recommendations
- **iOS all tiers**: ASTC 6×6 (medium) or 8×8 (low bandwidth). Delivered via KTX2 + Basis Universal.
- **macOS Apple9+**: BC7 native, checked at runtime via `supportsBCTextureCompression`
- **macOS Apple7/8**: ASTC via software path if BC not supported; query at startup
- **Interchange format**: KTX2 with Basis supercompression — one source file, transcode at load time

---

## 4. Rendering Architecture

### Design
Forward renderer, no deferred pass (keeps complexity low for top-down strategy with few lights).

### Pipeline
1. **Depth pre-pass** (optional for alpha; skip for MVP)
2. **Shadow depth pass** — single directional light, 1K–2K shadow map
3. **Main color pass**:
   - Ground plane (stylized grid material)
   - Instanced units (all 50-150 units in 1–2 draw calls via MTLDrawIndexedPrimitivesIndirectArguments)
   - Instanced props/buildings
   - Selection indicators (projected decals)
   - Projectiles (instanced spheres)
4. **Particle pass** (additive blend, depth read only)
5. **UI/debug overlay** (no depth test)

### Instancing strategy
- All units share one mesh per type → single instanced draw call
- Instance buffer: `GpuInstanceData { float4x4 model; float3 tint; float selected; }`
- Updated CPU-side each frame from ECS snapshot; uploaded via shared `MTLBuffer`
- No indirect command buffers for MVP (acceptable for 100–500 instances)

### Shader families
| Family | Purpose |
|---|---|
| `unitVS/unitFS` | Instanced units, props — stylized-PBR with toon diffuse |
| `groundVS/groundFS` | Terrain plane — checkerboard grid pattern |
| `debugLineVS/debugLineFS` | Path visualization, AI debug |
| (future) `particleVS/particleFS` | Particle effects |
| (future) `shadowVS` | Depth-only shadow pass |
| (future) `decalVS/decalFS` | Selection rings, projected UI |

### Shader compilation workflow
1. Shaders are embedded as inline MSL strings in MetalRenderer.mm for MVP (fast iteration)
2. Production: shaders compiled to `.metallib` offline with `xcrun -sdk macosx metal`
3. PSO states cached in `MTLBinaryArchive` (first-launch warmup, subsequent frames near-instant)

---

## 5. ECS / Simulation Architecture

### Entity identity
`EntityID` = 32-bit slot index + 16-bit generation. Stable across frames; generation increments on destroy to detect stale references.

### Component storage
`ComponentStorage<T>`: sparse-set (hash map index→slot + packed data array). Cache-friendly iteration, O(1) add/remove, O(1) lookup.

### Component list (MVP)
- `TransformComponent` — position, rotation, scale
- `RenderableComponent` — mesh handle, material handle, tint, castShadow
- `OwnershipComponent` — PlayerSlot (None/P1/P2/P3)
- `SelectionComponent` — selected bool, hover bool, selection sphere radius
- `CommandQueueComponent` — circular queue of 8 Commands (Move/Attack/Throw/Build)
- `MoveComponent` — destination, speed, arrivalRadius
- `HealthComponent` — current, max
- `ProjectileComponent` — velocity, mass, restitution, drag, bounceCount
- `AIControllerComponent` — autonomy mode, behavior state, sight radius, utility timer
- `PathFollowerComponent` — waypoint array, current waypoint index
- `PerceptionComponent` — last known enemy positions per player
- `UnitTypeComponent` — Basic/Hero/Vehicle/Building/Projectile

### Fixed-timestep simulation
- Server tick: 60 Hz (configurable)
- Accumulator: `accumulator += realDt; while (accumulator >= kSimTickSeconds) { Tick(); accumulator -= kSimTickSeconds; }`
- Render interpolation alpha: `alpha = accumulator / kSimTickSeconds`
- Renderer samples `(prevPos * (1 - alpha) + currPos * alpha)` for smooth motion

---

## 6. Physics / Projectile Architecture

Minimal, correctness-first. No full rigid-body solver.

### Projectile integration
1. Apply gravity: `velocity.y += kGravity * dt`
2. Apply drag: `velocity *= (1 - drag * dt)`
3. Integrate position: `position += velocity * dt`
4. Ground query: `QueryGround(x, z)` returns height + normal
5. If `position.y < groundHeight + radius`: resolve bounce
6. Sleep: after N bounces, if `|velocity| < sleepThreshold`, deactivate

### Bounce resolution
Reflect velocity about surface normal with restitution:
```cpp
v -= (1 + restitution) * dot(v, n) * n;
v -= friction * tangentialComponent;
```

### Query API
- `Raycast(origin, dir, maxDist)` → hit point + normal (ground plane; later heightmap)
- `SweepSphere(start, end, radius)` → hit point + normal
- `OverlapAABB(center, halfExtents, aabbMin, aabbMax)` → bool

---

## 7. AI Architecture

### Layers (from lowest to highest level)
1. **Pathfinding service** — A* on navigation grid (16×16 for MVP, expandable)
2. **Path follower** — Steps along waypoints toward destination
3. **Steering** — Simple seek/arrive behavior (no local avoidance for MVP)
4. **FSM** — BehaviorState per unit: Idle/Moving/Attacking/Retreating/Stunned/Dead
5. **Utility scorer** — AttackScore, RetreatScore, ChaseScore for Autonomous units
6. **Condition/event system** — OnDamaged, OnEnemyEntersRange, etc. broadcast to all AI
7. **Autonomy mode** — Manual / Assisted / Autonomous / Uncontrolled / Scripted

### Server authority
AI decisions run on the authoritative server. Clients receive resulting unit states in snapshots. Client-side prediction of AI behavior is not attempted for MVP.

---

## 8. Multiplayer / Network Architecture

### Model
- **Authoritative dedicated server**. Clients send player commands; server validates, advances simulation, sends snapshots.
- No peer-to-peer.
- 3 player slots, exactly.

### Transport
UDP sockets (POSIX, portable macOS → Linux). Simple reliability layer: sequence numbers + ACK bitfield in every message header. No retry protocol for gameplay; snapshot redundancy handles loss.

### Protocol versioning
Every message starts with `MsgHeader` (8 bytes):
- `MsgType type` — message category
- `u8 flags` — reliability/ordering hints
- `u16 seq` — sender sequence
- `u16 ack` — last received sequence
- `u16 length` — payload length

Version check at handshake: `protoVersion + assetVersion + tickRate`.

### Tick rates
- Server: 60 Hz simulation
- Snapshot send: ~20 Hz (every 3 ticks)
- Client rendering: display refresh rate (60/120 Hz)
- Interpolation: client renders state between two snapshots at the display rate

### Security
- Server validates all commands (ownership, range, cooldowns, resource costs)
- Clients cannot spawn entities or set positions directly
- Basic rate limiting per client (max N packets/second)

---

## 9. Asset Pipeline

### Principles
- Runtime code never reads raw source files (no loose glTF/PNG at runtime)
- All assets are cooked offline by `AssetCooker`
- Stable `AssetID` (128-bit GUID) assigned at import time
- `AssetManifest` maps names to IDs and cooked paths
- Hot reload on macOS: watcher detects cooked output changes, reloads without restart

### Source formats (AssetsRaw/)
- Meshes: glTF 2.0 / .glb — imported via **fastgltf** (C++17, fastest parser)
- Textures: PNG/EXR → KTX2 with Basis Universal supercompression
- Materials: JSON sidecar referencing texture IDs and parameters

### Cooked formats (AssetsCooked/)
- Meshes: engine-native binary (interleaved vertex buffer + index buffer + LOD headers)
- Textures: KTX2 container; transcoded to ASTC on iOS, BC7 on macOS at load time
- Materials: compact binary with texture ID references

### Texture compression path
```
EXR/PNG → toktx (create KTX2 + Basis) → AssetsCooked/<name>.ktx2
          ↓ at runtime ↓
iOS:   transcode to ASTC 6×6
macOS: transcode to BC7 (if Apple9) or ASTC via software (Apple7/8)
```

---

## 10. Build System

### Primary: Xcode (Apple-native)
Generate Xcode workspace from CMake:
```bash
cmake -B build_xcode -G Xcode -DCMAKE_SYSTEM_NAME=Darwin
open build_xcode/PostFall.xcodeproj
```

### Headless (CI / server build):
```bash
cmake -B build -DCMAKE_BUILD_TYPE=Debug
cd build && make -j$(nproc) PostFallServer PhysicsTests SimulationTests NetworkTests
ctest
```

### Minimum requirements
- macOS 14+ (Sonoma) for development
- Xcode 15.2+
- CMake 3.26+
- C++20 compiler (Apple Clang 15+)
- Swift 5.9+

---

## 11. Audio (Placeholder)

`AudioSystem.hpp` defines the interface. MVP stub only. Production implementation will use:
- macOS/iOS: AVAudioEngine (native, free, good for positional audio)
- Cross-platform fallback: OpenAL Soft or miniaudio

---

## 12. Profiling and Debugging

### Instruments integration
- Add Metal Frame Capture from Xcode: Product → Profile → GPU Frame Capture
- CPU profiling: Instruments → Time Profiler
- Memory: Instruments → Allocations + Leaks
- Thermal: Instruments → Energy Diagnostics (iOS)

### In-engine debug overlay
Always visible in Debug builds:
- FPS, frame time, GPU time
- Draw call count
- Visible entities, projectile count
- Simulation tick, interpolation alpha
- Per-player unit counts

### AI debug
In Debug builds, entities expose:
- Current behavior state
- Autonomy mode
- Current target
- Utility scores
- Path waypoints (rendered as debug lines)
