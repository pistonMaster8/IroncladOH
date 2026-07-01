#pragma once
#include "../Core/Math.hpp"
#include "../Core/Types.hpp"
#include <cstdint>

// ─── Render scene snapshot (decoupled from ECS) ──────────────────────────────
// The simulation writes this each frame; the renderer reads it.
// Interpolation happens here, not in the sim.

struct RenderUnit {
    Vec3   position;
    f32    scale        { 1.0f };
    Vec3   tint;
    bool   selected     { false };
    u8     playerSlot   { 0 };
    f32    shadowRadius { 0.5f };  // ground shadow disc radius — must match SelectionComponent::radius
};

struct RenderShadowDisc {
    Vec3 position;
    Vec3 velocity   {};        // current kinematic velocity (XZ plane)
    f32  facingYaw  { 0.0f }; // commanded facing angle (atan2 X,Z toward destination)
    bool hasFacing        { false }; // true when a move command is active
    bool onThrowCooldown  { false }; // true while throw ability is on cooldown
    f32  radius     { 0.5f };
    u8   playerSlot { 0 };
    bool selected   { false };
    bool hasColorOverride { false }; // when true, use colorOverride instead of slot-based tint
    Vec3 colorOverride    {};
    float visibility      { 1.0f }; // 0=fully hidden, 1=fully visible (for enemy fade)
};

struct RenderExplosion {
    Vec3 position;
    f32  radius { 0.0f };
    f32  alpha  { 1.0f };
};

struct RenderProjectile {
    Vec3 position;
    f32  radius  { 0.15f };
    Vec3 tint;
};

// ─── Skinned unit for GPU skeletal mesh rendering ────────────────────────────
// Bone matrices are stored flat in skinnedBoneData at [boneOffset .. boneOffset+boneCount).
// The MetalRenderer's skinnedVS shader indexes them as bones[iid * 64 + jointIndex].

struct RenderSkinnedUnit {
    Vec3  position   {};
    Quat  rotation   {};
    f32   scale      { 1.f };
    Vec3  tint       { Vec3Make(1,1,1) };
    bool  selected   { false };
    u8    playerSlot { 0 };
    u16   boneOffset { 0 };
    u16   boneCount  { 0 };
};

static constexpr u32 kMaxSkinnedUnits  = 64;   // must not exceed kMaxShadowDiscs
static constexpr u32 kHumanoidBoneSlots = 24;  // >= kHumanoidBoneCount (22); per-unit stride

struct RenderScene {
    static constexpr u32 kMaxUnits       = 256;
    static constexpr u32 kMaxProjectiles = 192;
    static constexpr u32 kMaxProps       = 128;
    static constexpr u32 kMaxShadowDiscs = 64;

    RenderUnit       units[kMaxUnits];
    u32              unitCount       { 0 };

    RenderProjectile projectiles[kMaxProjectiles];
    u32              projectileCount { 0 };

    RenderUnit       props[kMaxProps];
    u32              propCount       { 0 };

    RenderShadowDisc shadowDiscs[kMaxShadowDiscs];
    u32              shadowDiscCount { 0 };

    static constexpr u32 kMaxExplosions = 64;
    RenderExplosion  explosions[kMaxExplosions];
    u32              explosionCount { 0 };

    struct RenderSelectionRingData {
        struct Harmonic { f32 amp, freq, phase; };
        Vec3    center;
        Harmonic waves[3][4]; // [ring_index][harmonic_index]
        f32     rotAngle[3];
        Vec3    color { Vec3Make(0.3f, 0.55f, 1.0f) }; // blue for friendlies, red for enemies
    };
    static constexpr u32 kMaxSelectionRings = 32;
    RenderSelectionRingData selectionRings[kMaxSelectionRings];
    u32 selectionRingCount { 0 };

    // Debug radius overlay (toggled with D key) — yellow dotted outlines
    struct RenderDebugRing {
        Vec3 center;    // world-space center of the circle
        f32  radius;    // circle radius
        Vec3 offset {};  // optional XZ offset from center (for forward-biased circles)
    };
    static constexpr u32 kMaxDebugRings = 512;
    RenderDebugRing debugRings[kMaxDebugRings];
    u32 debugRingCount { 0 };

    struct FollowRing {
        Vec3 center  {};
        f32  radius  { 1.0f };
    };
    static constexpr int kMaxFollowRings = 8;
    FollowRing followRings[kMaxFollowRings];
    int        followRingCount { 0 };

    // Light auras — friendly unit halos; enemies outside all auras are culled
    struct RenderAura {
        Vec3  center;   // XZ position (Y ignored — renderer samples terrain)
        float radius;   // world-space aura radius
    };
    static constexpr u32 kMaxAuras = 32;
    RenderAura auras[kMaxAuras];
    u32        auraCount { 0 };

    // Cursor ground-plane indicator (set by app, rendered by renderer)
    struct CursorMarker {
        Vec3  worldPos      { Vec3Make(0, 0.01f, 0) };
        Vec3  color         { Vec3Make(0, 0.4f, 1.0f) };  // blue default
        bool  visible       { false };
        float selectorRadius{ 0.0f }; // extra radius added while holding left click
    } cursor;

    // Terrace face roughness (G panel)
    float terraceNoiseStrength { 0.0f };  // 0 = smooth, 1 = fully rough
    float terraceNoiseScale    { 1.0f };  // noise frequency in world units

    // Tree trunk controls (T panel). Changing a scatter field regenerates the forest.
    struct TreeParams {
        bool  visible    { true };
        float density    { 0.55f };                        // grid keep-rate 0..1
        Vec3  color      { Vec3Make(0.26f, 0.17f, 0.10f) };// wood base color
        float leanMin    { 0.0f };                         // min per-trunk tilt (degrees)
        float leanMax    { 6.0f };                         // max per-trunk tilt (degrees)
        float heightMin  { 9.0f };
        float heightMax  { 17.0f };
        float thickness  { 1.0f };                         // radial scale multiplier
        // Dead trees: a fraction of the scattered trunks marked dead (no new trees).
        // They get their own lean bounds and are skipped by branch/leaf generators.
        float deadDensity { 0.0f };                        // 0..1 fraction marked dead
        float deadLeanMin { 0.0f };
        float deadLeanMax { 6.0f };
        // Pull node: trees lean toward this world point. Likelihood is the magnitude;
        // sign sets direction — positive leans toward the node, negative leans away.
        // `pull` applies to living trees, `deadPull` to dead ones.
        bool  pullActive { false };
        float pullX      { 0.0f };
        float pullZ      { 0.0f };
        float pull       { 0.0f };                          // -1..1 (sign = toward/away)
        float deadPull   { 0.0f };                          // -1..1 (sign = toward/away)
    } tree;

    // Grass controls (G panel)
    bool  shellGrassVisible   { true };
    float shellGrassDensity   { 1.0f };
    Vec3  shellGrassColorBase { Vec3Make(0.002f, 0.008f, 0.001f) };
    Vec3  shellGrassColorTip  { Vec3Make(0.020f, 0.063f, 0.007f) };
    bool  longGrassVisible      { true };
    float longGrassDensity      { 1.0f };
    float longStepEdgeDensity   { 1.0f };
    Vec3  longGrassColorBase    { Vec3Make(0.055f, 0.075f, 0.022f) };
    Vec3  longGrassColorTip     { Vec3Make(0.200f, 0.260f, 0.070f) };
    int   grassGenerationMode   { 0 };
    int   grassOptimizationMode { 0 };

    // Terrain construction editor
    bool  dModeActive          = false;
    bool  terrainNodePlaceMode = false;
    bool  requestNodePlace     = false;
    float terrainNodeX         = 0.0f;
    float terrainNodeZ         = 0.0f;
    bool  autoNode             = false;  // auto-fill the plane with a grid of nodes
    float autoNodeDensity      = 6.0f;   // interior grid nodes per axis
    float cursorWorldX         = 0.0f;
    float cursorWorldZ         = 0.0f;
    bool  leftMouseDown        = false;
    bool  leftMouseJustDown    = false;
    float mouseDeltaY          = 0.0f;
    float cursorRayDirX        = 0.0f;
    float cursorRayDirY        = -1.0f;
    float cursorRayDirZ        = 0.0f;
    bool  requestGenerate      = false;
    bool  requestMeshRebuild   = false;  // reload mesh from existing heightfield (no regen)
    int   requestPreset        = -1;     // apply terrain preset index (-1 = none); see presets
    float groundScale          = 1.0f;   // procedural preset: ground-plane size multiplier
    float erosionStep          = 1.0f;
    float erosionHeight        = 0.0f;   // 0 → rise per band equals erosionStep
    float erosionAngle         = 90.0f;  // riser angle from horizontal; 90 → vertical
    bool  constructionPlaneVisible = true;

    RenderSkinnedUnit skinnedUnits[kMaxSkinnedUnits];
    u32               skinnedUnitCount { 0 };
    // Caller-owned animation retarget input: humanoid bone model-space rotations,
    // kHumanoidBoneSlots per unit, indexed by HumanoidBone ordinal. The renderer
    // retargets these onto the glTF mesh's own skeleton (see ComputeRetargetedBoneMatrices).
    const Quat*       skinnedBoneRot { nullptr };

    Vec3  cameraPos    { Vec3Make(0, 20, 10) };
    Vec3  cameraTarget { Vec3Make(0, 0, 0) };
    f32   cameraNear   { 0.1f };
    f32   cameraFar    { 200.0f };
    f32   cameraFovY   { Deg2Rad(45.0f) };

    // Debug overlay data
    struct DebugStats {
        u32  fps               { 0 };
        f32  frameTimeMs       { 0 };
        u32  drawCalls         { 0 };
        u32  visibleEntities   { 0 };
        u32  physicsObjects    { 0 };
        u64  simTick           { 0 };
        f32  simAlpha          { 0 };
        f32  gpuTimeMs         { 0 };
    } debug;
};

// ─── Renderer interface ───────────────────────────────────────────────────────
class IRenderer {
public:
    virtual ~IRenderer() = default;

    virtual bool Init(void* nativeWindowHandle, u32 widthPx, u32 heightPx) = 0;
    virtual void Shutdown() = 0;

    virtual void BeginFrame(f32 dt) = 0;
    virtual void RenderScene(const RenderScene& scene) = 0;
    virtual void EndFrame() = 0;

    virtual void Resize(u32 widthPx, u32 heightPx) = 0;

    virtual void SetDisplayScale(f32 scale) = 0;

    // Returns GPU frame time in ms, 0 if not supported
    virtual f32 LastGPUTimeMs() const { return 0.0f; }

    virtual u32 DrawCallCount() const { return 0; }
};
