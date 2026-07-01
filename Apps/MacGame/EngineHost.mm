// EngineHost.mm — Objective-C++ implementation bridging Swift ↔ C++ engine.

#import "EngineHost.h"
#include "../../Engine/Renderer/Metal/MetalRenderer.hpp"
#include "../../Engine/Simulation/GameSim.hpp"
#include "../../Engine/Simulation/Terrain.hpp"
#include "../../Engine/Input/InputSystem.hpp"
#include "../../Engine/Core/Log.hpp"
#include "../../Engine/Animation/Animation.hpp"
#include <limits>
#include <memory>
#include <chrono>
#include <cmath>
#include <cstdlib>

// ─── Movement curve helpers ───────────────────────────────────────────────────

static constexpr f32 kVMaxBase  = 5.0f;
static constexpr f32 kAccelBase = 8.0f;

// ETA for a trapezoidal/triangular velocity profile from speed v0 to 0.
static f32 ComputeETA(f32 dist, f32 v0, f32 vMax, f32 accel, f32 decel) {
    if (dist <= 0.0f) return 0.0f;
    v0 = fmaxf(0.0f, fminf(v0, vMax));
    f32 dAccel = (vMax * vMax - v0 * v0) / (2.0f * accel);
    f32 dDecel =  vMax * vMax             / (2.0f * decel);
    if (dAccel + dDecel >= dist) {
        // Triangular: solve for peak speed given v0
        f32 k     = 0.5f / accel + 0.5f / decel;
        f32 vpeak = sqrtf(fmaxf(0.0f, (dist + v0 * v0 / (2.0f * accel)) / k));
        vpeak     = fminf(vpeak, vMax);
        return (vpeak - v0) / accel + vpeak / decel;
    }
    return (vMax - v0) / accel + (dist - dAccel - dDecel) / vMax + vMax / decel;
}

// Given a target ETA, solve for the vMax that achieves it (starting from rest).
static f32 SolveVMax(f32 T, f32 dist, f32 accel, f32 decel) {
    f32 k    = 0.5f / accel + 0.5f / decel;
    f32 disc = T * T - 4.0f * k * dist;
    if (disc <= 0.0f) return sqrtf(dist / k);          // triangular limit
    return (T - sqrtf(disc)) / (2.0f * k);
}

static f32 RandF(f32 lo, f32 hi) {
    return lo + (float)rand() / (float)RAND_MAX * (hi - lo);
}

// Extract a normalized rotation quaternion from a model matrix (scale removed).
// Used to hand the procedural pose's model-space bone rotations to the renderer's
// animation retargeting layer. [Shelved with the procedural feed — see renderFrame.]
#if 0
static Quat QuatFromModelMat(const Mat4& m) {
    simd_float3 c0 = simd_normalize(m.columns[0].xyz);
    simd_float3 c1 = simd_normalize(m.columns[1].xyz);
    simd_float3 c2 = simd_normalize(m.columns[2].xyz);
    return simd_quaternion(simd_matrix(c0, c1, c2));
}
#endif

// ─── Internal state ────────────────────────────────────────────────────────────
struct EngineState {
    std::unique_ptr<MetalRenderer> renderer;
    std::unique_ptr<GameSim>       sim;
    std::unique_ptr<InputSystem>   input;

    u32  viewWidth  { 0 };
    u32  viewHeight { 0 };

    // Selection state
    bool selectionPending { false };
    Vec2 selectionNormPos {};

    // Move-command pending (right click)
    bool movePending     { false };
    Vec2 movePendingPos  {};

    // Debug stats
    f32 frameTimeMs  { 0 };
    i32 fps          { 0 };
    i32 fpsCounter   { 0 };
    f64 fpsTimer     { 0 };

    // Input debug (for overlay)
    f64 cursorNormX    { 0.5 };
    f64 cursorNormY    { 0.5 };
    f32 cursorFloorX   { 0 };
    f32 cursorFloorZ   { 0 };
    int  lastClickBtn        { -1 };  // -1=none, 0=left, 1=right
    int  mouseMoveCount      { 0 };
    int  cursorClickState    { 0 };  // 0=none, 1=left_down, 2=right_down
    bool  deselectAllPending  { false };
    bool  leftDragging        { false };
    bool  rightDragging       { false };

    // Left-click selector grow-on-hold
    double mouseDownNormX    { 0.0 };
    double mouseDownNormY    { 0.0 };
    bool   selectorFrozen    { false }; // true once drag detected — locks radius
    float  selectorHoldTime  { 0.0f };
    float  selectorRadius    { 0.0f }; // current grown radius (additive to base ring size)

    // Right-click selector (shares selectorRadius / selectorHoldTime with left)
    float    rightHoldTime        { 0.0f };  // time right held before selector mode activates
    bool     rightSelectorMode    { false }; // true once hold threshold crossed
    bool     rightSelectorFrozen  { false }; // true once pan/orbit fires in selector mode
    bool     rightDragStarted     { false }; // pan/orbit fired before threshold — block selector
    bool     rightTargetPending   { false }; // commit target assignment on frame update
    EntityID targetCandidates[16] {};
    int      targetCandidateCount { 0 };

    // Follow-ring interaction
    EntityID ringTargetEnt {};   // enemy entity currently showing the follow ring
    bool     ringDragging  { false };

    // Debug overlay
    bool debugRadiiVisible { false };

    // Terrain editor input state
    bool  leftJustDown     = false;
    float accMouseDeltaY   = 0.0f;
    bool  nodePlacePending = false;
    bool  generatePending      = false;
    bool  meshRebuildPending   = false;
    int   presetPending        = -1;     // terrain preset to apply (-1 = none)
    float groundScale          = 1.0f;
    float erosionStep          = 1.0f;
    float erosionHeight        = 0.0f;
    float erosionAngle         = 90.0f;

    // Camera (spherical coords around camTarget)
    // Defaults reproduce the original hardcoded pos (0,18,12), target (0,0,0):
    //   dist = sqrt(18²+12²) ≈ 21.633, pitch = asin(18/21.633) ≈ 0.9828 rad, yaw = 0
    f32  camYaw    { 0.0f };
    f32  camPitch  { 0.9828f };
    f32  camDist   { 21.633f };
    Vec3 camTarget { Vec3Make(0.0f, 0.0f, 0.0f) };

    // Procedural animation — one controller per shadow disc slot (heap-allocated struct)
    Skeleton            soldierSkeleton;
    AnimationLibrary    soldierAnimLib;
    AnimationController animCtrl[RenderScene::kMaxShadowDiscs];
    bool                animInited { false };
    bool                animParamsDirty { false };  // A panel edited → rebuild clips
    // Per-unit humanoid model-space bone rotations, fed to the renderer's retarget layer.
    Quat animBoneRot[RenderScene::kMaxShadowDiscs * kHumanoidBoneSlots];
};

@implementation EngineHost {
    std::unique_ptr<EngineState> _state;
    BOOL      _dModeActive;
    BOOL      _terrainNodePlaceMode;
    BOOL      _constructionPlaneVisible;
    BOOL      _autoNode;
    float     _autoNodeDensity;
    BOOL      _gModeActive;
    BOOL      _shellGrassVisible;
    float     _shellGrassDensity;
    float     _shellColorBaseR, _shellColorBaseG, _shellColorBaseB;
    float     _shellColorTipR,  _shellColorTipG,  _shellColorTipB;
    BOOL      _longGrassVisible;
    float     _longGrassDensity;
    float     _longStepEdgeDensity;
    float     _longColorBaseR,  _longColorBaseG,  _longColorBaseB;
    float     _longColorTipR,   _longColorTipG,   _longColorTipB;
    float     _terraceNoiseStrength;
    float     _terraceNoiseScale;
    BOOL      _tModeActive;
    BOOL      _treesVisible;
    float     _treeDensity, _treeColorR, _treeColorG, _treeColorB;
    float     _treeLeanMin, _treeLeanMax, _treeHeightMin, _treeHeightMax, _treeThickness;
    float     _treeDeadDensity, _treeDeadLeanMin, _treeDeadLeanMax;
    BOOL      _treePullPlaceMode, _treePullActive;
    float     _treePullX, _treePullZ, _treePull, _treeDeadPull;
    BOOL      _stateJustLoaded;
    NSInteger _fps;
    double    _frameTimeMs;
    NSInteger _drawCalls;
    NSInteger _visibleEntities;
    NSInteger _projectileCount;
    double    _gpuTimeMs;
    double    _cursorNormX;
    double    _cursorNormY;
    double    _cursorFloorX;
    double    _cursorFloorZ;
    NSInteger _lastClickBtn;
    NSInteger _mouseMoveCount;
    BOOL      _aModeActive;
    BOOL      _animPreviewWalk;
}

@synthesize dModeActive              = _dModeActive;
@synthesize terrainNodePlaceMode     = _terrainNodePlaceMode;
@synthesize constructionPlaneVisible = _constructionPlaneVisible;
@synthesize autoNode                 = _autoNode;
@synthesize autoNodeDensity          = _autoNodeDensity;
@synthesize gModeActive              = _gModeActive;
@synthesize shellGrassVisible        = _shellGrassVisible;
@synthesize shellGrassDensity        = _shellGrassDensity;
@synthesize shellColorBaseR          = _shellColorBaseR;
@synthesize shellColorBaseG          = _shellColorBaseG;
@synthesize shellColorBaseB          = _shellColorBaseB;
@synthesize shellColorTipR           = _shellColorTipR;
@synthesize shellColorTipG           = _shellColorTipG;
@synthesize shellColorTipB           = _shellColorTipB;
@synthesize longGrassVisible         = _longGrassVisible;
@synthesize longGrassDensity         = _longGrassDensity;
@synthesize longStepEdgeDensity      = _longStepEdgeDensity;
@synthesize longColorBaseR           = _longColorBaseR;
@synthesize longColorBaseG           = _longColorBaseG;
@synthesize longColorBaseB           = _longColorBaseB;
@synthesize longColorTipR            = _longColorTipR;
@synthesize longColorTipG            = _longColorTipG;
@synthesize longColorTipB            = _longColorTipB;
@synthesize terraceNoiseStrength     = _terraceNoiseStrength;
@synthesize terraceNoiseScale        = _terraceNoiseScale;
@synthesize tModeActive              = _tModeActive;
@synthesize treesVisible             = _treesVisible;
@synthesize treeDensity              = _treeDensity;
@synthesize treeColorR               = _treeColorR;
@synthesize treeColorG               = _treeColorG;
@synthesize treeColorB               = _treeColorB;
@synthesize treeLeanMin              = _treeLeanMin;
@synthesize treeLeanMax              = _treeLeanMax;
@synthesize treeDeadDensity          = _treeDeadDensity;
@synthesize treeDeadLeanMin          = _treeDeadLeanMin;
@synthesize treeDeadLeanMax          = _treeDeadLeanMax;
@synthesize treeHeightMin            = _treeHeightMin;
@synthesize treeHeightMax            = _treeHeightMax;
@synthesize treeThickness            = _treeThickness;
@synthesize treePullPlaceMode        = _treePullPlaceMode;
@synthesize treePullActive           = _treePullActive;
@synthesize treePull                 = _treePull;
@synthesize treeDeadPull             = _treeDeadPull;
@synthesize stateJustLoaded          = _stateJustLoaded;
@synthesize fps            = _fps;
@synthesize frameTimeMs    = _frameTimeMs;
@synthesize drawCalls      = _drawCalls;
@synthesize visibleEntities= _visibleEntities;
@synthesize projectileCount= _projectileCount;
@synthesize gpuTimeMs      = _gpuTimeMs;
@synthesize cursorNormX    = _cursorNormX;
@synthesize cursorNormY    = _cursorNormY;
@synthesize cursorFloorX   = _cursorFloorX;
@synthesize cursorFloorZ   = _cursorFloorZ;
@synthesize lastClickBtn   = _lastClickBtn;
@synthesize mouseMoveCount = _mouseMoveCount;
@synthesize aModeActive    = _aModeActive;
@synthesize animPreviewWalk = _animPreviewWalk;

// ─── Animation (A panel) parameter bridge ────────────────────────────────────
- (NSInteger)animParamCount { return kGaitParamCount; }

- (float)animParamValue:(NSInteger)index { return GaitParamGet((int)index); }

- (void)setAnimParam:(NSInteger)index value:(float)value {
    if (GaitParamGet((int)index) == value) return;
    GaitParamSet((int)index, value);
    if (_state) _state->animParamsDirty = true;  // rebuild clip library next frame
}

- (NSString*)animParamLabel:(NSInteger)index {
    return [NSString stringWithUTF8String:GaitParamLabel((int)index)];
}

- (float)animPhaseValue:(NSInteger)index { return GaitPhaseGet((int)index); }

- (void)setAnimPhase:(NSInteger)index value:(float)value {
    if (GaitPhaseGet((int)index) == value) return;
    GaitPhaseSet((int)index, value);
    if (_state) _state->animParamsDirty = true;  // rebuild clip library next frame
}

- (void)copyAnimWalkToRun {
    gRunGaitParams = gWalkGaitParams;
    gRunGaitPhase  = gWalkGaitPhase;
    if (_state) _state->animParamsDirty = true;
}

- (BOOL)setupWithLayer:(CAMetalLayer*)layer width:(NSUInteger)w height:(NSUInteger)h {

    _state = std::make_unique<EngineState>();
    auto& s = *_state;

    _constructionPlaneVisible = YES;  // construction plane shown by default in D mode
    _autoNodeDensity          = 6.0f; // default interior grid: 6×6 nodes

    // G panel defaults
    _shellGrassVisible  = YES;
    _shellGrassDensity  = 1.0f;
    _shellColorBaseR    = 0.002f; _shellColorBaseG = 0.008f; _shellColorBaseB = 0.001f;
    _shellColorTipR     = 0.020f; _shellColorTipG  = 0.063f; _shellColorTipB  = 0.007f;
    _longGrassVisible       = YES;
    _longGrassDensity       = 1.0f;
    _longStepEdgeDensity    = 1.0f;
    _longColorBaseR     = 0.055f; _longColorBaseG  = 0.075f; _longColorBaseB  = 0.022f;
    _longColorTipR      = 0.200f; _longColorTipG   = 0.260f; _longColorTipB   = 0.070f;
    _terraceNoiseStrength = 0.0f;
    _terraceNoiseScale    = 1.0f;

    // Tree trunk defaults (match RenderScene::TreeParams)
    _treesVisible  = YES;
    _treeDensity   = 0.55f;
    _treeColorR    = 0.26f; _treeColorG = 0.17f; _treeColorB = 0.10f;
    _treeLeanMin   = 0.0f;  _treeLeanMax = 6.0f;
    _treeDeadDensity = 0.0f; _treeDeadLeanMin = 0.0f; _treeDeadLeanMax = 6.0f;
    _treeHeightMin = 9.0f;  _treeHeightMax = 17.0f;
    _treeThickness = 1.0f;
    _treePull      = 0.0f;  _treeDeadPull = 0.0f;
    _treePullActive = NO;   _treePullPlaceMode = NO;

    s.renderer = std::make_unique<MetalRenderer>();
    s.sim      = std::make_unique<GameSim>();
    s.input    = std::make_unique<InputSystem>();

    s.viewWidth  = static_cast<u32>(w);
    s.viewHeight = static_cast<u32>(h);

    // Init renderer
    if (!s.renderer->Init((__bridge void*)layer, s.viewWidth, s.viewHeight)) {
        LOG_ERR("App", "Renderer init failed");
        return NO;
    }

    // Ironclad-OH is a terrain/grass optimization bench — no units, projectiles, or buildings are
    // spawned (SpawnInitialScene disabled). Trees, grass, terrain and camera remain fully active.
    // s.sim->SpawnInitialScene();

    // Restore saved editor state (G/D panels + terrain shape).
    [self loadState];

    LOG_INF("App", "EngineHost initialised (%lux%lu)", (unsigned long)w, (unsigned long)h);
    return YES;
}

- (void)renderFrame:(double)dt {
    auto& s = *_state;
    if (!s.renderer) return;

    auto t0 = std::chrono::high_resolution_clock::now();

    // Advance simulation
    s.sim->Advance(dt);

    // FPS counter
    s.fpsTimer   += dt;
    s.fpsCounter += 1;
    if (s.fpsTimer >= 1.0) {
        s.fps       = s.fpsCounter;
        s.fpsCounter = 0;
        s.fpsTimer   = 0.0;
    }

    // ─── Build render scene from ECS ──────────────────────────────────────────
    RenderScene scene;
    auto& world = s.sim->GetWorld();
    const auto& stats = s.sim->Stats();

    // ─── Aura pre-pass: collect friendly shadow-disc positions → compute groups ─
    {
        struct FPos { float x, z; };
        FPos friendly[32]; int nFriendly = 0;
        world.Transforms().ForEach([&](EntityID id, TransformComponent& xf) {
            auto* own = world.Ownerships().Get(id);
            auto* ut  = world.UnitTypes().Get(id);
            if (!own || !ut) return;
            if (static_cast<u8>(own->owner) == 0) return;
            if (ut->type != UnitType::ShadowDisc) return;
            if (nFriendly < 32) friendly[nFriendly++] = { xf.position.x, xf.position.z };
        });

        // Simple union-find: merge units within kGroupDist of each other
        int parent[32];
        for (int i = 0; i < nFriendly; ++i) parent[i] = i;
        auto findRoot = [&](int i) -> int {
            while (parent[i] != i) i = parent[i]; return i;
        };
        constexpr float kGroupDist = 7.0f;
        for (int i = 0; i < nFriendly; ++i)
            for (int j = i + 1; j < nFriendly; ++j) {
                float dx = friendly[j].x - friendly[i].x;
                float dz = friendly[j].z - friendly[i].z;
                if (dx*dx + dz*dz < kGroupDist*kGroupDist)
                    parent[findRoot(j)] = findRoot(i);
            }

        // Centroid + sqrt(N) radius per root
        float sumX[32]={}, sumZ[32]={}; int cnt[32]={};
        for (int i = 0; i < nFriendly; ++i) {
            int r = findRoot(i);
            sumX[r] += friendly[i].x; sumZ[r] += friendly[i].z; cnt[r]++;
        }
        constexpr float kBaseAura = 8.0f;
        scene.auraCount = 0;
        for (int i = 0; i < nFriendly && scene.auraCount < RenderScene::kMaxAuras; ++i) {
            if (findRoot(i) != i || cnt[i] == 0) continue;
            auto& a  = scene.auras[scene.auraCount++];
            a.center = Vec3Make(sumX[i]/cnt[i], 0.f, sumZ[i]/cnt[i]);
            a.radius = kBaseAura * sqrtf((float)cnt[i]);
        }
    }

    // Visibility check for enemies: true if within any friendly aura
    auto isEnemyVisible = [&](float ex, float ez) -> bool {
        for (int a = 0; a < (int)scene.auraCount; ++a) {
            float dx = ex - scene.auras[a].center.x;
            float dz = ez - scene.auras[a].center.z;
            if (dx*dx + dz*dz <= scene.auras[a].radius * scene.auras[a].radius)
                return true;
        }
        return false;
    };

    // Units and props
    world.Transforms().ForEach([&](EntityID id, TransformComponent& xf) {
        auto* rend   = world.Renderables().Get(id);
        auto* unitT  = world.UnitTypes().Get(id);
        auto* sel    = world.Selections().Get(id);
        auto* projC  = world.Projectiles().Get(id);
        if (!rend || !rend->visible) return;

        if (projC) {
            // Projectile
            if (!projC->active) return;
            if (scene.projectileCount < RenderScene::kMaxProjectiles) {
                auto& rp = scene.projectiles[scene.projectileCount++];
                rp.position = xf.position;
                rp.radius   = projC->radius;
                rp.tint     = rend->tint;
            }
        } else if (unitT && unitT->type == UnitType::Building) {
            // Prop
            if (scene.propCount < RenderScene::kMaxProps) {
                auto& rp = scene.props[scene.propCount++];
                rp.position = xf.position;
                rp.scale    = xf.scale;
                rp.tint     = rend->tint;
                rp.selected = false;
            }
        } else if (unitT && unitT->type == UnitType::ShadowDisc) {
            // Pure shadow disc — no 3D body
            if (scene.shadowDiscCount < RenderScene::kMaxShadowDiscs) {
                auto* own = world.Ownerships().Get(id);
                // Compute smooth visibility for enemies based on aura proximity
                float visibility = 1.0f;
                if (own && own->owner == PlayerSlot::None) {
                    float auraBright = 0.0f;
                    for (int a = 0; a < (int)scene.auraCount; ++a) {
                        float dx = xf.position.x - scene.auras[a].center.x;
                        float dz = xf.position.z - scene.auras[a].center.z;
                        float d  = sqrtf(dx*dx + dz*dz) / scene.auras[a].radius;
                        auraBright = fmaxf(auraBright, 1.0f - d);
                    }
                    float t  = fminf(1.0f, fmaxf(0.0f, auraBright / 0.2f));
                    visibility = t * t * (3.0f - 2.0f * t); // smoothstep
                    if (visibility < 0.01f) return; // fully invisible — skip entirely
                }
                auto* mv  = world.Moves().Get(id);
                auto* cq  = world.Commands().Get(id);
                auto* ai  = world.AIControllers().Get(id);
                auto& sd = scene.shadowDiscs[scene.shadowDiscCount++];
                sd.position          = xf.position;
                sd.radius            = sel ? sel->radius : 0.5f;
                sd.playerSlot        = own ? static_cast<u8>(own->owner) : 0;
                sd.selected          = sel ? sel->selected : false;
                sd.velocity          = mv ? mv->velocity : Vec3Make(0, 0, 0);
                sd.onThrowCooldown   = cq && cq->throwCooldown > 0.0f;
                if (ai && ai->autonomy == AutonomyMode::Stationary) {
                    sd.hasColorOverride = true;
                    sd.colorOverride    = Vec3Make(0.05f, 0.05f, 0.05f); // near-black
                }
                sd.visibility = visibility;
                // Commanded facing: point toward destination the instant an order is issued
                if (mv && mv->hasDestination) {
                    float dx = mv->destination.x - xf.position.x;
                    float dz = mv->destination.z - xf.position.z;
                    float len = sqrtf(dx*dx + dz*dz);
                    if (len > 0.01f) {
                        sd.facingYaw = atan2f(dx, dz) + (float)M_PI;
                        sd.hasFacing = true;
                    }
                }
            }
        } else {
            // Unit
            if (scene.unitCount < RenderScene::kMaxUnits) {
                auto* own = world.Ownerships().Get(id);
                auto& ru  = scene.units[scene.unitCount++];
                ru.position     = xf.position;
                ru.scale        = xf.scale > 0 ? xf.scale : 1.0f;
                ru.tint         = rend->tint;
                ru.selected     = sel ? sel->selected : false;
                ru.playerSlot   = own ? static_cast<u8>(own->owner) : 0;
                ru.shadowRadius = sel ? sel->radius : 0.5f;
            }
        }
    });

    // ─── Procedural animation update + retarget feed [DISABLED] ───────────────
    // SHELVED (2026-06-24): the procedural humanoid + retarget pipeline is parked
    // as too large for this stage. While this block is disabled, scene.skinnedBoneRot
    // stays null, so MetalRenderer falls back to the original glTF-clip animation
    // (Idle/Walk blend via ComputeBoneMatrices, driven by scene.shadowDiscs).
    //
    // TO REIMPLEMENT: re-enable this block (and the retarget branch + BuildRetargetMap
    // call in MetalRenderer.mm, and the A-key toggle below). The full system lives in
    // Engine/Animation/* and is still compiled. See project_animation_system memory.
#if 0
    {
        const u32 discCount = scene.shadowDiscCount;

        if (!s.animInited && discCount > 0) {
            s.soldierSkeleton = Skeleton::CreateHumanoid();
            s.soldierAnimLib  = AnimationLibrary::BuildSoldierLibrary(s.soldierSkeleton);
            for (u32 i = 0; i < RenderScene::kMaxShadowDiscs; ++i) {
                s.animCtrl[i].Init(&s.soldierSkeleton, &s.soldierAnimLib);
                // Seed so first Update() speed = 0 instead of position − origin.
                if (i < discCount)
                    s.animCtrl[i].lastPosition = scene.shadowDiscs[i].position;
            }
            s.animInited = true;
        }

        // A panel edited a gait parameter → rebuild the clip library, preserving each
        // controller's locomotion state so the walk/jog continues seamlessly (no blip).
        if (s.animInited && s.animParamsDirty) {
            s.soldierAnimLib = AnimationLibrary::BuildSoldierLibrary(s.soldierSkeleton);
            for (u32 i = 0; i < RenderScene::kMaxShadowDiscs; ++i) {
                auto& c = s.animCtrl[i];
                AnimState st      = c.stateMachine.current;
                f32      clipTime = c.sampler.GetCurrentTime();
                Vec3     keepPos  = c.lastPosition;
                f32      stride   = c.stridePhase;
                f32      breath   = c.breathPhase;
                f32      smooth   = c.smoothedSpeed;
                c.Init(&s.soldierSkeleton, &s.soldierAnimLib);
                c.lastPosition  = keepPos;  c.stridePhase   = stride;
                c.breathPhase   = breath;   c.smoothedSpeed = smooth;
                c.stateMachine.current   = st;   c.stateMachine.previous = st;
                c.stateMachine.blendAlpha = 1.f; c.stateMachine.stateTime = 1.f;
                const AnimationClip* clip =
                    s.soldierAnimLib.Find(AnimationStateMachine::StateName(st));
                if (clip) { c.sampler.SetClip(clip, 0.f); c.sampler.layers[0].time = clipTime; }
            }
            s.animParamsDirty = false;
        }

        if (s.animInited) {
            for (u32 i = 0; i < discCount; ++i) {
                const RenderShadowDisc& sd = scene.shadowDiscs[i];

                // Facing/position only matter for foot IK (disabled here); the
                // renderer applies world placement + yaw via the instance matrix,
                // so the retarget deltas stay facing-independent.
                TransformComponent xf {};
                xf.position = sd.position;
                xf.rotation = QuatIdentity();
                xf.scale    = 1.f;
                // Walk-in-place preview: force a walk-speed override (below run threshold).
                s.animCtrl[i].speedOverride = _animPreviewWalk ? 1.5f : -1.f;
                s.animCtrl[i].Update((f32)dt, xf);

                const ModelPose& mp = s.animCtrl[i].modelPose;
                u16 bc = s.animCtrl[i].GetBoneCount();
                if (bc > kHumanoidBoneSlots) bc = (u16)kHumanoidBoneSlots;
                Quat* dst = s.animBoneRot + i * kHumanoidBoneSlots;
                for (u16 h = 0; h < bc; ++h)
                    dst[h] = QuatFromModelMat(mp.modelMats[h]);

                auto& su      = scene.skinnedUnits[i];
                su.boneOffset = (u16)(i * kHumanoidBoneSlots);
                su.boneCount  = bc;
            }
            scene.skinnedUnitCount = discCount;
            scene.skinnedBoneRot   = s.animBoneRot;
        }
    }
#endif // procedural animation disabled

    // Debug radius overlay — populated when D is toggled on
    scene.debugRingCount = 0;
    if (s.debugRadiiVisible) {
        auto addRing = [&](Vec3 center, f32 radius, Vec3 offset = Vec3Make(0,0,0)) {
            if (scene.debugRingCount >= RenderScene::kMaxDebugRings) return;
            auto& dr = scene.debugRings[scene.debugRingCount++];
            dr.center = center;
            dr.radius = radius;
            dr.offset = offset;
        };

        world.Moves().ForEach([&](EntityID id, MoveComponent& mv) {
            auto* xf  = world.Transforms().Get(id);
            auto* ai  = world.AIControllers().Get(id);
            if (!xf) return;

            // Selection / collision radius
            auto* sel = world.Selections().Get(id);
            f32 collR = sel ? sel->radius : 0.5f;
            addRing(xf->position, collR);

            // Avoidance detection circle (forward-biased) for moving non-stationary units
            if (mv.hasDestination && !(ai && ai->autonomy == AutonomyMode::Stationary)) {
                f32 toDx = mv.destination.x - xf->position.x;
                f32 toDz = mv.destination.z - xf->position.z;
                f32 len  = sqrtf(toDx*toDx + toDz*toDz);
                if (len > 0.05f) {
                    Vec3 off = Vec3Make(toDx/len * kAvoidForwardOff, 0, toDz/len * kAvoidForwardOff);
                    addRing(xf->position, kAvoidDetectR, off);
                }
            }

            // Auto-throw range centered on the follow target
            if (mv.followTarget.IsValid()) {
                auto* txf = world.Transforms().Get(mv.followTarget);
                if (txf) addRing(txf->position, mv.followRadius * 2.0f);
                // Standoff radius
                if (txf) addRing(txf->position, mv.followRadius);
            }
        });
    }

    // Selection rings: one per selected player unit that has ring data
    scene.selectionRingCount = 0;
    world.Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
        if (!sel.selected) return;
        if (scene.selectionRingCount >= RenderScene::kMaxSelectionRings) return;
        auto* xf = world.Transforms().Get(id);
        auto* rc = world.SelectionRings().Get(id);
        if (!xf || !rc) return;
        auto* own = world.Ownerships().Get(id);
        bool isEnemy = own && own->owner == PlayerSlot::None;
        auto& rd = scene.selectionRings[scene.selectionRingCount++];
        rd.center = xf->position;
        rd.color  = isEnemy ? Vec3Make(1.0f, 0.15f, 0.15f)   // red for targeted enemies
                            : Vec3Make(0.3f,  0.55f, 1.0f);   // blue for friendly selection
        for (int r = 0; r < 3; ++r) {
            rd.rotAngle[r] = rc->rotAngle[r];
            for (int h = 0; h < 4; ++h)
                rd.waves[r][h] = { rc->waves[r][h].amp, rc->waves[r][h].freq, rc->waves[r][h].phase };
        }
    });

    // Explosions
    int numEx = s.sim->ExplosionCount();
    for (int i = 0; i < numEx && scene.explosionCount < RenderScene::kMaxExplosions; ++i) {
        const auto& ex = s.sim->GetExplosion(i);
        f32 t = ex.elapsed / ex.duration;
        auto& re = scene.explosions[scene.explosionCount++];
        re.position = ex.position;
        re.radius   = ex.maxRadius * t;
        re.alpha    = 1.0f - t;
    }

    // Camera: computed from spherical orbit state
    Vec3 camPos = Vec3Make(
        s.camTarget.x + s.camDist * cosf(s.camPitch) * sinf(s.camYaw),
        s.camTarget.y + s.camDist * sinf(s.camPitch),
        s.camTarget.z + s.camDist * cosf(s.camPitch) * cosf(s.camYaw));
    scene.cameraPos    = camPos;
    scene.cameraTarget = s.camTarget;

    // Cursor floor projection (for input debug overlay)
    if (s.viewWidth > 0 && s.viewHeight > 0) {
        f32 aspect = (f32)s.viewWidth / (f32)s.viewHeight;
        f32 tanH   = tanf(scene.cameraFovY * 0.5f);
        f32 ndcX   = (f32)(s.cursorNormX * 2.0 - 1.0);
        f32 ndcY   = (f32)(1.0 - s.cursorNormY * 2.0);
        Vec3 cp    = scene.cameraPos;
        Vec3 ct    = scene.cameraTarget;
        Vec3 zAxis = Vec3Norm(Vec3Make(cp.x-ct.x, cp.y-ct.y, cp.z-ct.z));
        Vec3 xAxis = Vec3Norm(Vec3Cross(Vec3Make(0,1,0), zAxis));
        Vec3 yAxis = Vec3Cross(zAxis, xAxis);
        Vec3 rd    = Vec3Norm(Vec3Make(
            xAxis.x * ndcX * tanH * aspect + yAxis.x * ndcY * tanH - zAxis.x,
            xAxis.y * ndcX * tanH * aspect + yAxis.y * ndcY * tanH - zAxis.y,
            xAxis.z * ndcX * tanH * aspect + yAxis.z * ndcY * tanH - zAxis.z));
        scene.cursorRayDirX = rd.x;
        scene.cursorRayDirY = rd.y;
        scene.cursorRayDirZ = rd.z;
        if (fabsf(rd.y) > 1e-4f) {
            f32 t = -cp.y / rd.y;
            if (t > 0) {
                s.cursorFloorX = cp.x + rd.x * t;
                s.cursorFloorZ = cp.z + rd.z * t;
            }
        }
    }

    constexpr float kGrowRate = 3.5f;
    constexpr float kMaxGrow  = 12.0f;

    if (!_dModeActive) {
        // Left click: grow radius while held without dragging
        if (s.cursorClickState == 1 && !s.selectorFrozen && !s.ringDragging) {
            s.selectorHoldTime += (float)dt;
            s.selectorRadius = fminf(kMaxGrow, kGrowRate * s.selectorHoldTime);
        }

        // Right click: hold for 0.3 s, grow and sweep enemies for targeting
        if (s.cursorClickState == 2) {
            if (!s.rightSelectorMode && !s.rightDragStarted) {
                s.rightHoldTime += (float)dt;
                if (s.rightHoldTime >= 0.3f)
                    s.rightSelectorMode = true;
            }
            if (s.rightSelectorMode && !s.rightSelectorFrozen) {
                s.selectorHoldTime += (float)dt;
                s.selectorRadius = fminf(kMaxGrow, kGrowRate * s.selectorHoldTime);
            }
            if (s.rightSelectorMode) {
                const float pickR = 0.25f + s.selectorRadius;
                world.Selections().ForEach([&](EntityID eid, SelectionComponent& sel) {
                    auto* own = world.Ownerships().Get(eid);
                    if (!own || own->owner != PlayerSlot::None) return;
                    auto* exf = world.Transforms().Get(eid);
                    if (!exf) return;
                    float dx = exf->position.x - s.cursorFloorX;
                    float dz = exf->position.z - s.cursorFloorZ;
                    if (sqrtf(dx*dx + dz*dz) < pickR + sel.radius)
                        sel.selected = true;
                });
            }
        }
    }

    // Cursor ground indicator
    scene.cursor.visible        = (s.viewWidth > 0 && s.viewHeight > 0);
    scene.cursor.worldPos       = Vec3Make(s.cursorFloorX, Terrain::Height(s.cursorFloorX, s.cursorFloorZ) + 0.05f, s.cursorFloorZ);
    scene.cursor.selectorRadius = _dModeActive ? 0.0f : s.selectorRadius;
    if (s.cursorClickState == 1)
        scene.cursor.color = Vec3Make(1.0f, 0.50f, 0.0f);   // orange on left click
    else if (s.cursorClickState == 2 && s.rightSelectorMode)
        scene.cursor.color = Vec3Make(1.0f, 0.10f, 0.10f);  // red in right selector mode
    else if (s.cursorClickState == 2)
        scene.cursor.color = Vec3Make(0.05f, 0.05f, 0.05f); // near-black on right click
    else
        scene.cursor.color = Vec3Make(0.0f, 0.40f, 1.0f);   // blue default

    // Terrain construction editor
    scene.dModeActive          = _dModeActive ? true : false;
    scene.terrainNodePlaceMode = _terrainNodePlaceMode ? true : false;
    scene.cursorWorldX         = s.cursorFloorX;
    scene.cursorWorldZ         = s.cursorFloorZ;
    scene.leftMouseDown        = (s.cursorClickState == 1);
    scene.leftMouseJustDown    = s.leftJustDown;
    s.leftJustDown             = false;
    scene.mouseDeltaY          = s.accMouseDeltaY;
    s.accMouseDeltaY           = 0.0f;
    if (s.nodePlacePending) {
        s.nodePlacePending     = false;
        scene.requestNodePlace = true;
        scene.terrainNodeX     = s.cursorFloorX;
        scene.terrainNodeZ     = s.cursorFloorZ;
    }
    scene.erosionStep             = s.erosionStep;
    scene.erosionHeight           = s.erosionHeight;
    scene.erosionAngle            = s.erosionAngle;
    scene.constructionPlaneVisible = _constructionPlaneVisible ? true : false;
    scene.autoNode                 = _autoNode ? true : false;
    scene.autoNodeDensity          = _autoNodeDensity;
    if (s.generatePending) {
        s.generatePending     = false;
        scene.requestGenerate = true;
    }
    if (s.meshRebuildPending) {
        s.meshRebuildPending      = false;
        scene.requestMeshRebuild  = true;
    }
    scene.groundScale = s.groundScale;
    if (s.presetPending >= 0) {
        scene.requestPreset = s.presetPending;
        s.presetPending     = -1;
    }

    // Grass controls (G panel)
    scene.shellGrassVisible   = _shellGrassVisible  ? true : false;
    scene.shellGrassDensity   = _shellGrassDensity;
    scene.shellGrassColorBase = Vec3Make(_shellColorBaseR, _shellColorBaseG, _shellColorBaseB);
    scene.shellGrassColorTip  = Vec3Make(_shellColorTipR,  _shellColorTipG,  _shellColorTipB);
    scene.longGrassVisible      = _longGrassVisible       ? true : false;
    scene.longGrassDensity      = _longGrassDensity;
    scene.longStepEdgeDensity   = _longStepEdgeDensity;
    scene.longGrassColorBase  = Vec3Make(_longColorBaseR,  _longColorBaseG,  _longColorBaseB);
    scene.longGrassColorTip   = Vec3Make(_longColorTipR,   _longColorTipG,   _longColorTipB);

    // Terrace face roughness
    scene.terraceNoiseStrength = _terraceNoiseStrength;
    scene.terraceNoiseScale    = _terraceNoiseScale;

    // Tree trunks (T panel)
    scene.tree.visible   = _treesVisible ? true : false;
    scene.tree.density   = _treeDensity;
    scene.tree.color     = Vec3Make(_treeColorR, _treeColorG, _treeColorB);
    scene.tree.leanMin   = _treeLeanMin;
    scene.tree.leanMax   = _treeLeanMax;
    scene.tree.deadDensity = _treeDeadDensity;
    scene.tree.deadLeanMin = _treeDeadLeanMin;
    scene.tree.deadLeanMax = _treeDeadLeanMax;
    scene.tree.heightMin = _treeHeightMin;
    scene.tree.heightMax = _treeHeightMax;
    scene.tree.thickness = _treeThickness;
    scene.tree.pullActive = _treePullActive ? true : false;
    scene.tree.pullX      = _treePullX;
    scene.tree.pullZ      = _treePullZ;
    scene.tree.pull       = _treePull;
    scene.tree.deadPull   = _treeDeadPull;
    scene.debug.fps            = static_cast<u32>(s.fps);
    scene.debug.frameTimeMs    = s.frameTimeMs;
    scene.debug.drawCalls      = static_cast<u32>(s.renderer->DrawCallCount());
    scene.debug.visibleEntities= scene.unitCount + scene.propCount;
    scene.debug.physicsObjects = scene.projectileCount;
    scene.debug.simTick        = stats.currentTick;
    scene.debug.simAlpha       = static_cast<f32>(s.sim->InterpolationAlpha());
    scene.debug.gpuTimeMs      = s.renderer->LastGPUTimeMs();

    // Update property vars for SwiftUI
    _fps             = s.fps;
    _drawCalls       = s.renderer->DrawCallCount();
    _visibleEntities = scene.unitCount + scene.propCount;
    _projectileCount = scene.projectileCount;
    _gpuTimeMs       = s.renderer->LastGPUTimeMs();
    _cursorNormX     = s.cursorNormX;
    _cursorNormY     = s.cursorNormY;
    _cursorFloorX    = s.cursorFloorX;
    _cursorFloorZ    = s.cursorFloorZ;
    _lastClickBtn    = s.lastClickBtn;
    _mouseMoveCount  = s.mouseMoveCount;

    // ─── Follow rings: one per unique enemy followed by any selected friendly ──
    scene.followRingCount = 0;
    {
        EntityID seen[RenderScene::kMaxFollowRings]; int nSeen = 0;
        world.Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
            if (!sel.selected) return;
            auto* own = world.Ownerships().Get(id);
            if (!own || own->owner == PlayerSlot::None) return; // friendlies only
            auto* mv = world.Moves().Get(id);
            if (!mv || !mv->followTarget.IsValid()) return;
            EntityID target = mv->followTarget;
            for (int i = 0; i < nSeen; ++i) if (seen[i] == target) return; // dedupe
            if (nSeen >= RenderScene::kMaxFollowRings) return;
            seen[nSeen++] = target;
            auto* txf = world.Transforms().Get(target);
            if (!txf) return;
            auto& fr = scene.followRings[scene.followRingCount++];
            fr.center = txf->position;
            fr.radius = mv->followRadius;
        });
    }

    // ─── Handle pending input ──────────────────────────────────────────────────
    [self processInput:scene];

    // ─── Render ───────────────────────────────────────────────────────────────
    s.renderer->BeginFrame(static_cast<f32>(dt));
    s.renderer->RenderScene(scene);
    s.renderer->EndFrame();

    // Frame time
    auto t1 = std::chrono::high_resolution_clock::now();
    s.frameTimeMs = std::chrono::duration<float, std::milli>(t1 - t0).count();
    _frameTimeMs  = s.frameTimeMs;
}

- (void)processInput:(RenderScene&)scene {
    auto& s = *_state;
    auto& world = s.sim->GetWorld();

    // Handle selection — 2D circle overlap on the ground plane
    if (s.selectionPending) {
        s.selectionPending = false;
        Vec2 np = s.selectionNormPos;

        // Project the click onto the ground plane (y=0)
        f32 aspect = (f32)s.viewWidth / (f32)s.viewHeight;
        f32 tanH   = tanf(scene.cameraFovY * 0.5f);
        f32 ndcX   = np.x * 2.0f - 1.0f;
        f32 ndcY   = 1.0f - np.y * 2.0f;
        Vec3 cp    = scene.cameraPos;
        Vec3 ct    = scene.cameraTarget;
        Vec3 zAxis = Vec3Norm(Vec3Make(cp.x-ct.x, cp.y-ct.y, cp.z-ct.z));
        Vec3 xAxis = Vec3Norm(Vec3Cross(Vec3Make(0,1,0), zAxis));
        Vec3 yAxis = Vec3Cross(zAxis, xAxis);
        Vec3 rd    = Vec3Norm(Vec3Make(
            xAxis.x*ndcX*tanH*aspect + yAxis.x*ndcY*tanH - zAxis.x,
            xAxis.y*ndcX*tanH*aspect + yAxis.y*ndcY*tanH - zAxis.y,
            xAxis.z*ndcX*tanH*aspect + yAxis.z*ndcY*tanH - zAxis.z));

        if (fabsf(rd.y) > 1e-4f) {
            f32 t = -cp.y / rd.y;
            if (t > 0) {
                f32 clickX = cp.x + rd.x * t;
                f32 clickZ = cp.z + rd.z * t;

                // Check if click lands on any visible follow ring (derived from selected friendlies)
                bool hitRing = false;
                {
                    f32 bestDelta = 0.6f;
                    world.Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
                        if (!sel.selected) return;
                        auto* own = world.Ownerships().Get(id);
                        if (!own || own->owner == PlayerSlot::None) return; // friendlies only
                        auto* mv = world.Moves().Get(id);
                        if (!mv || !mv->followTarget.IsValid()) return;
                        EntityID target = mv->followTarget;
                        auto* exf = world.Transforms().Get(target);
                        if (!exf) return;
                        f32 dx = clickX - exf->position.x, dz = clickZ - exf->position.z;
                        f32 delta = fabsf(sqrtf(dx*dx + dz*dz) - mv->followRadius);
                        if (delta < bestDelta) {
                            bestDelta       = delta;
                            s.ringTargetEnt = target;
                            s.ringDragging  = true;
                            hitRing         = true;
                        }
                    });
                }

                // Click on any followed enemy body → clear follow for that enemy
                if (!hitRing) {
                    EntityID checked[8]; int nChecked = 0;
                    world.Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
                        if (hitRing || !sel.selected) return;
                        auto* own = world.Ownerships().Get(id);
                        if (!own || own->owner == PlayerSlot::None) return;
                        auto* mv = world.Moves().Get(id);
                        if (!mv || !mv->followTarget.IsValid()) return;
                        EntityID target = mv->followTarget;
                        for (int i = 0; i < nChecked; ++i) if (checked[i] == target) return;
                        if (nChecked >= 8) return;
                        checked[nChecked++] = target;
                        auto* exf = world.Transforms().Get(target);
                        if (!exf) return;
                        f32 dx = clickX - exf->position.x, dz = clickZ - exf->position.z;
                        if (sqrtf(dx*dx + dz*dz) < 0.75f) {
                            world.Moves().ForEach([&](EntityID, MoveComponent& mv2) {
                                if (mv2.followTarget == target)
                                    mv2.followTarget = EntityID::Invalid();
                            });
                            hitRing = true;
                        }
                    });
                }

                if (!hitRing) {
                    // Toggle selection on click: clicking an already-selected unit deselects it.
                    const f32 kCursorR = 0.25f;
                    world.Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
                        auto* own = world.Ownerships().Get(id);
                        if (own && own->owner == PlayerSlot::None) return; // enemies not left-selectable
                        auto* xf = world.Transforms().Get(id);
                        if (!xf) return;
                        f32 dx   = xf->position.x - clickX;
                        f32 dz   = xf->position.z - clickZ;
                        f32 dist = sqrtf(dx*dx + dz*dz);
                        if (dist < kCursorR + sel.radius)
                            sel.selected = !sel.selected;
                    });
                }
            }
        }
    }

    // Drag selection or ring resize — mutually exclusive
    if (s.leftDragging) {
        if (s.ringDragging && s.ringTargetEnt.IsValid()) {
            // Resize the follow ring: new radius = cursor distance from enemy center
            auto* rxf = world.Transforms().Get(s.ringTargetEnt);
            if (rxf) {
                f32 dx = s.cursorFloorX - rxf->position.x;
                f32 dz = s.cursorFloorZ - rxf->position.z;
                f32 newR = fmaxf(1.0f, fminf(12.0f, sqrtf(dx*dx + dz*dz)));
                // Apply to all enemies followed by selected friendlies (so all visible rings resize)
                EntityID targetSet[8]; int nTargets = 0;
                world.Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
                    if (!sel.selected) return;
                    auto* own = world.Ownerships().Get(id);
                    if (!own || own->owner == PlayerSlot::None) return;
                    auto* mv = world.Moves().Get(id);
                    if (!mv || !mv->followTarget.IsValid()) return;
                    for (int i = 0; i < nTargets; ++i) if (targetSet[i] == mv->followTarget) return;
                    if (nTargets < 8) targetSet[nTargets++] = mv->followTarget;
                });
                world.Moves().ForEach([&](EntityID, MoveComponent& mv) {
                    if (!mv.followTarget.IsValid()) return;
                    for (int i = 0; i < nTargets; ++i)
                        if (targetSet[i] == mv.followTarget) { mv.followRadius = newR; return; }
                });
            }
        } else {
            // Normal drag-select (radius grows with selectorRadius) — friendly units only
            const f32 kCursorR = 0.25f + s.selectorRadius;
            world.Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
                auto* own = world.Ownerships().Get(id);
                if (own && own->owner == PlayerSlot::None) return; // skip enemies
                auto* xf = world.Transforms().Get(id);
                if (!xf) return;
                f32 dx   = xf->position.x - s.cursorFloorX;
                f32 dz   = xf->position.z - s.cursorFloorZ;
                if (sqrtf(dx*dx + dz*dz) < kCursorR + sel.radius)
                    sel.selected = true;
            });
        }
    } else {
        s.ringDragging = false;  // clear when mouse released
    }

    // ESC — deselect all
    if (s.deselectAllPending) {
        s.deselectAllPending = false;
        world.Selections().ForEach([&](EntityID /*id*/, SelectionComponent& sel) {
            sel.selected = false;
        });
    }

    // Assign random targets from right-click sweep, then clear enemy selection
    if (s.rightTargetPending) {
        s.rightTargetPending = false;

        // Collect swept enemies (selected enemies) and friendly units (selected friendlies)
        EntityID enemies[16]; int nEnemies = 0;
        EntityID friendlies[256]; int nFriendlies = 0;
        world.Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
            auto* own = world.Ownerships().Get(id);
            bool isEnemy = own && own->owner == PlayerSlot::None;
            if (isEnemy) {
                if (sel.selected && nEnemies < 16) enemies[nEnemies++] = id;
                sel.selected = false; // always clear enemy selection after commit
            } else {
                if (sel.selected && nFriendlies < 256) friendlies[nFriendlies++] = id;
            }
        });

        if (nEnemies > 0) {
            for (int i = 0; i < nFriendlies; ++i) {
                auto* mv = world.Moves().Get(friendlies[i]);
                auto* ai = world.AIControllers().Get(friendlies[i]);
                if (!mv) continue;
                EntityID chosen = enemies[rand() % nEnemies];
                mv->followTarget = chosen;
                mv->followRadius = 5.0f;
                if (ai) ai->state = BehaviorState::Moving;
            }
        }
    }

    // Handle move command (right click)
    if (s.movePending) {
        s.movePending = false;

        // Cast ray to ground plane
        Vec2 np = s.movePendingPos;
        f32 aspect = (f32)s.viewWidth / (f32)s.viewHeight;
        f32 fovY   = scene.cameraFovY;
        f32 tanH   = tanf(fovY * 0.5f);
        f32 ndcX   = np.x * 2.0f - 1.0f;
        f32 ndcY   = 1.0f - np.y * 2.0f;

        Vec3 cp    = scene.cameraPos;
        Vec3 ct    = scene.cameraTarget;
        Vec3 zAxis = Vec3Norm(Vec3Make(cp.x-ct.x, cp.y-ct.y, cp.z-ct.z));
        Vec3 xAxis = Vec3Norm(Vec3Cross(Vec3Make(0,1,0), zAxis));
        Vec3 yAxis = Vec3Cross(zAxis, xAxis);
        Vec3 worldRayDir = Vec3Norm(Vec3Make(
            xAxis.x * ndcX * tanH * aspect + yAxis.x * ndcY * tanH - zAxis.x,
            xAxis.y * ndcX * tanH * aspect + yAxis.y * ndcY * tanH - zAxis.y,
            xAxis.z * ndcX * tanH * aspect + yAxis.z * ndcY * tanH - zAxis.z));

        // Ray-ground plane intersection
        if (fabsf(worldRayDir.y) > 1e-4f) {
            f32 t = -cp.y / worldRayDir.y;
            if (t > 0) {
                Vec3 groundPt = Vec3Make(cp.x + worldRayDir.x * t,
                                         0,
                                         cp.z + worldRayDir.z * t);

                // Check if click lands on an enemy entity (unselectable wanderer)
                const f32 kEnemyPickR = 0.8f;
                EntityID enemyTarget {};
                world.UnitTypes().ForEach([&](EntityID eid, UnitTypeComponent& ut) {
                    if (ut.type != UnitType::ShadowDisc) return;
                    auto* own = world.Ownerships().Get(eid);
                    if (!own || own->owner != PlayerSlot::None) return;
                    auto* exf = world.Transforms().Get(eid);
                    if (!exf) return;
                    f32 dx = exf->position.x - groundPt.x;
                    f32 dz = exf->position.z - groundPt.z;
                    if (sqrtf(dx*dx + dz*dz) < kEnemyPickR) enemyTarget = eid;
                });

                // Collect selected entities
                EntityID selEntities[256];
                int selCount = 0;
                world.Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
                    if (sel.selected && selCount < 256) selEntities[selCount++] = id;
                });

                if (enemyTarget.IsValid()) {
                    // Follow-with-standoff: surround the enemy at a safe radius
                    for (int i = 0; i < selCount; ++i) {
                        auto* mv = world.Moves().Get(selEntities[i]);
                        auto* ai = world.AIControllers().Get(selEntities[i]);
                        if (!mv) continue;
                        mv->followTarget = enemyTarget;
                        mv->followRadius = 5.0f;
                        if (ai) ai->state = BehaviorState::Moving;
                    }
                    // Skip the normal ground-move path
                    goto moveDone;
                }

                // Assign a unique ring slot and a randomized acceleration curve
                // to each selected unit. All units must arrive within ±1 s of
                // the base-curve optimal ETA for their slot distance.
                for (int i = 0; i < selCount; ++i) {
                    // ── Formation slot ────────────────────────────────────────
                    Vec3 slot;
                    if (selCount == 1) {
                        slot = groundPt;
                    } else {
                        f32 ring_r = 0.55f / sinf((float)M_PI / selCount);
                        f32 angle  = 2.0f * (float)M_PI * i / selCount;
                        slot = Vec3Make(groundPt.x + ring_r * cosf(angle),
                                        0,
                                        groundPt.z + ring_r * sinf(angle));
                    }
                    // Keep slots within the arena
                    constexpr f32 kSlotBound = PhysicsSystem::kArenaBound - 0.5f;
                    slot.x = fmaxf(-kSlotBound, fminf(kSlotBound, slot.x));
                    slot.z = fmaxf(-kSlotBound, fminf(kSlotBound, slot.z));

                    auto* mv = world.Moves().Get(selEntities[i]);
                    auto* ai = world.AIControllers().Get(selEntities[i]);
                    auto* xf = world.Transforms().Get(selEntities[i]);
                    if (!mv || !xf) continue;

                    // ── Optimal ETA (base curve, factoring in current velocity) ─
                    Vec3 toSlot = Vec3Make(slot.x - xf->position.x,
                                           0,
                                           slot.z - xf->position.z);
                    f32 dist    = Vec3Len(toSlot);
                    Vec3 dir    = dist > 0.001f ? Vec3Norm(toSlot) : Vec3Make(1,0,0);
                    f32  v0     = fmaxf(0.0f, Vec3Dot(mv->velocity, dir));
                    f32  T_opt  = ComputeETA(dist, v0, kVMaxBase, kAccelBase, kAccelBase);

                    // ── Randomized curve parameters ───────────────────────────
                    f32 accel_r = kAccelBase * RandF(0.5f, 2.0f);
                    f32 decel_r = kAccelBase * RandF(0.5f, 2.0f);

                    // Compute unclamped ETA for the randomized params
                    f32 vMax_trial = kVMaxBase * RandF(0.6f, 1.6f);
                    f32 T_rand     = ComputeETA(dist, v0, vMax_trial, accel_r, decel_r);

                    // Clamp to ±1 s of optimal, then re-solve for vMax
                    f32 T_min = fmaxf(T_opt - 1.0f, dist / (kVMaxBase * 2.0f));
                    f32 T_max = T_opt + 1.0f;
                    T_rand    = fmaxf(T_min, fminf(T_max, T_rand));
                    f32 vMax_r = SolveVMax(T_rand, dist, accel_r, decel_r);
                    vMax_r     = fmaxf(vMax_r, 0.5f);

                    mv->destination    = slot;
                    mv->hasDestination = true;
                    mv->vMaxCurve      = vMax_r;
                    mv->accelCurve     = accel_r;
                    mv->decelCurve     = decel_r;
                    mv->followTarget   = EntityID::Invalid();
                    if (ai) ai->state  = BehaviorState::Moving;
                }
                moveDone:;
            }
        }
    }

    // Throw projectile on Space key (5-second cooldown per unit)
    auto& input = *s.input;
    if (input.State().IsKeyPressed(Key::Space)) {
        // Find the nearest stationary enemy to use as a ballistic target
        Vec3  nearestStatPos {};
        bool  hasStatTarget  = false;
        f32   bestStatDist   = std::numeric_limits<f32>::max();
        world.AIControllers().ForEach([&](EntityID eid, AIControllerComponent& ai) {
            if (ai.autonomy != AutonomyMode::Stationary) return;
            auto* exf = world.Transforms().Get(eid);
            if (!exf) return;
            // Pick the nearest one across all selected units (good enough for single-select)
            world.Selections().ForEach([&](EntityID sid, SelectionComponent& sel) {
                if (!sel.selected) return;
                auto* sxf = world.Transforms().Get(sid);
                if (!sxf) return;
                f32 dx = exf->position.x - sxf->position.x;
                f32 dz = exf->position.z - sxf->position.z;
                f32 d  = sqrtf(dx*dx + dz*dz);
                if (d < bestStatDist) { bestStatDist = d; nearestStatPos = exf->position; hasStatTarget = true; }
            });
        });

        world.Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
            if (!sel.selected) return;
            auto* xf  = world.Transforms().Get(id);
            auto* own = world.Ownerships().Get(id);
            auto* cq  = world.Commands().Get(id);
            if (!xf || !own || !cq) return;
            if (cq->throwCooldown > 0.0f) return;
            Vec3 launchPos = Vec3Make(xf->position.x, xf->position.y + 1.2f, xf->position.z);
            Vec3 vel;
            if (hasStatTarget) {
                // Ballistic arc to land at the stationary enemy's position
                constexpr f32 g  = 9.81f;
                f32 dx = nearestStatPos.x - launchPos.x;
                f32 dz = nearestStatPos.z - launchPos.z;
                f32 dh = sqrtf(dx*dx + dz*dz);
                if (dh < 0.01f) {
                    vel = Vec3Make(0, 8.0f, 0);
                } else {
                    f32 vy = fmaxf(4.0f, fminf(14.0f, sqrtf(dh * g * 0.5f)));
                    f32 disc = vy*vy + 2.0f * g * (launchPos.y - nearestStatPos.y);
                    f32 t    = (vy + sqrtf(fmaxf(0.0f, disc))) / g;
                    if (t < 0.01f) t = 0.01f;
                    f32 vh = dh / t;
                    vel = Vec3Make(dx / dh * vh, vy, dz / dh * vh);
                }
            } else {
                Vec3 dir = Vec3Norm(Vec3Make(-xf->position.x, 0.3f, -xf->position.z));
                vel = Vec3Make(dir.x * 12.0f, dir.y * 12.0f, dir.z * 12.0f);
            }
            s.sim->SpawnProjectile(launchPos, vel, own->owner);
            cq->throwCooldown = 5.0f;
        });
    }

    input.NextFrame();
}

- (void)resizeWidth:(NSUInteger)w height:(NSUInteger)h {
    if (!_state) return;
    _state->viewWidth  = static_cast<u32>(w);
    _state->viewHeight = static_cast<u32>(h);
    _state->renderer->Resize(static_cast<u32>(w), static_cast<u32>(h));
}

- (void)setDisplayScale:(double)scale {
    if (_state) _state->renderer->SetDisplayScale(static_cast<f32>(scale));
}

// ─── Input forwarding ─────────────────────────────────────────────────────────
- (void)mouseDownX:(double)x y:(double)y button:(int)btn {
    if (!_state) return;
    auto& s = *_state;
    Vec2 np = Vec2Make((f32)x, (f32)y);  // already normalised [0,1] by GameView.swift
    s.lastClickBtn     = btn;
    s.cursorClickState = (btn == 0) ? 1 : 2;

    // Tree pull-node placement: left click drops/moves the green point on the ground.
    if (_treePullPlaceMode && btn == 0) {
        _treePullX      = s.cursorFloorX;
        _treePullZ      = s.cursorFloorZ;
        _treePullActive = YES;
        return;
    }

    // In D mode, always signal left-just-down so the renderer can decide:
    // if near an existing node → drag it; if not (and placement mode) → place new.
    if (_dModeActive && btn == 0) {
        s.leftJustDown = true;
        if (_terrainNodePlaceMode) {
            s.nodePlacePending = true;
            s.input->OnMouseDown(MouseButton::Left);
            return;
        }
    } else if (btn == 0) {
        s.leftJustDown = true;
    }

    if (btn == 0) {
        if (!_dModeActive) {
            s.selectionPending = true;
            s.selectionNormPos = np;
            s.leftDragging     = true;
            s.mouseDownNormX   = x;
            s.mouseDownNormY   = y;
            s.selectorFrozen   = false;
            s.selectorHoldTime = 0.0f;
            s.selectorRadius   = 0.0f;
        }
        s.input->OnMouseDown(MouseButton::Left);
    } else if (btn == 1) { // right click — record position; commit move on up only if no drag
        s.movePendingPos  = np;
        s.rightDragging   = false;
        s.selectorRadius  = 0.0f;
        s.selectorHoldTime= 0.0f;
        if (!_dModeActive) {
            s.rightHoldTime        = 0.0f;
            s.rightSelectorMode    = false;
            s.rightSelectorFrozen  = false;
            s.rightDragStarted     = false;
            s.targetCandidateCount = 0;
        }
        s.input->OnMouseDown(MouseButton::Right);
    }
    s.input->OnMouseMove(np, Vec2Make(0,0));
}

- (void)mouseUpX:(double)x y:(double)y button:(int)btn {
    if (!_state) return;
    auto& s = *_state;
    s.cursorClickState = 0;
    if (btn == 0) {
        s.leftDragging     = false;
        s.selectorFrozen   = false;
        s.selectorHoldTime = 0.0f;
        s.selectorRadius   = 0.0f;
    } else if (btn == 1) {
        if (!_dModeActive && s.rightSelectorMode) {
            s.rightTargetPending = true;
        } else if (!s.rightDragging) {
            s.movePending = true;
        }
        s.rightDragging       = false;
        s.rightSelectorMode   = false;
        s.rightSelectorFrozen = false;
        s.selectorRadius      = 0.0f;
        s.selectorHoldTime    = 0.0f;
    }
    Vec2 np = Vec2Make((f32)x, (f32)y);
    s.input->OnMouseUp(btn == 0 ? MouseButton::Left : MouseButton::Right);
    s.input->OnMouseMove(np, Vec2Make(0,0));
}

- (void)mouseMovedX:(double)x y:(double)y deltaX:(double)dx deltaY:(double)dy {
    if (!_state) return;
    auto& s = *_state;
    s.cursorNormX = x;
    s.cursorNormY = y;
    s.mouseMoveCount++;
    s.accMouseDeltaY += (float)dy;  // accumulated for terrain node drag
    // Freeze selector growth once the cursor drifts more than ~0.5% of screen width
    if (s.cursorClickState == 1 && !s.selectorFrozen) {
        double ddx = x - s.mouseDownNormX;
        double ddy = y - s.mouseDownNormY;
        if (ddx*ddx + ddy*ddy > 0.005 * 0.005)
            s.selectorFrozen = true;
    }
    Vec2 np    = Vec2Make((f32)x, (f32)y);
    Vec2 delta = Vec2Make((f32)dx, (f32)dy);
    s.input->OnMouseMove(np, delta);
}

- (void)scrollDelta:(double)delta {
    if (_state) _state->input->OnScroll((f32)delta);
}

- (void)generateTerrainWithStep:(float)step height:(float)height angle:(float)angle {
    if (!_state) return;
    _state->erosionStep     = step;
    _state->erosionHeight   = height;
    _state->erosionAngle    = angle;
    _state->generatePending = true;
}

- (void)applyTerrainPreset:(NSInteger)index step:(float)step height:(float)height
                     angle:(float)angle groundScale:(float)scale {
    if (!_state) return;
    _state->erosionStep   = step;
    _state->erosionHeight = height;
    _state->erosionAngle  = angle;
    _state->groundScale   = scale;
    _state->presetPending = (int)index;
}

// ─── Saved erosion param accessors ───────────────────────────────────────────

- (float)savedErosionStep   { return _state ? _state->erosionStep   : 1.0f;  }
- (float)savedErosionHeight { return _state ? _state->erosionHeight : 0.0f;  }
- (float)savedErosionAngle  { return _state ? _state->erosionAngle  : 90.0f; }

// ─── Save / Load ──────────────────────────────────────────────────────────────

- (void)saveState {
    if (!_state) return;
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];

    // G panel — shell grass
    [ud setBool:_shellGrassVisible   forKey:@"pf_shellGrassVisible"];
    [ud setFloat:_shellGrassDensity  forKey:@"pf_shellGrassDensity"];
    [ud setFloat:_shellColorBaseR    forKey:@"pf_shellColorBaseR"];
    [ud setFloat:_shellColorBaseG    forKey:@"pf_shellColorBaseG"];
    [ud setFloat:_shellColorBaseB    forKey:@"pf_shellColorBaseB"];
    [ud setFloat:_shellColorTipR     forKey:@"pf_shellColorTipR"];
    [ud setFloat:_shellColorTipG     forKey:@"pf_shellColorTipG"];
    [ud setFloat:_shellColorTipB     forKey:@"pf_shellColorTipB"];

    // G panel — long grass
    [ud setBool:_longGrassVisible        forKey:@"pf_longGrassVisible"];
    [ud setFloat:_longGrassDensity       forKey:@"pf_longGrassDensity"];
    [ud setFloat:_longStepEdgeDensity    forKey:@"pf_longStepEdgeDensity"];
    [ud setFloat:_longColorBaseR         forKey:@"pf_longColorBaseR"];
    [ud setFloat:_longColorBaseG         forKey:@"pf_longColorBaseG"];
    [ud setFloat:_longColorBaseB         forKey:@"pf_longColorBaseB"];
    [ud setFloat:_longColorTipR          forKey:@"pf_longColorTipR"];
    [ud setFloat:_longColorTipG          forKey:@"pf_longColorTipG"];
    [ud setFloat:_longColorTipB          forKey:@"pf_longColorTipB"];

    // G panel — terrace face roughness
    [ud setFloat:_terraceNoiseStrength   forKey:@"pf_terraceNoiseStr"];
    [ud setFloat:_terraceNoiseScale      forKey:@"pf_terraceNoiseScl"];

    // T panel — tree trunks
    [ud setBool:_treesVisible    forKey:@"pf_treesVisible"];
    [ud setFloat:_treeDensity    forKey:@"pf_treeDensity"];
    [ud setFloat:_treeColorR     forKey:@"pf_treeColorR"];
    [ud setFloat:_treeColorG     forKey:@"pf_treeColorG"];
    [ud setFloat:_treeColorB     forKey:@"pf_treeColorB"];
    [ud setFloat:_treeLeanMin    forKey:@"pf_treeLeanMin"];
    [ud setFloat:_treeLeanMax    forKey:@"pf_treeLeanMax"];
    [ud setFloat:_treeDeadDensity forKey:@"pf_treeDeadDensity"];
    [ud setFloat:_treeDeadLeanMin forKey:@"pf_treeDeadLeanMin"];
    [ud setFloat:_treeDeadLeanMax forKey:@"pf_treeDeadLeanMax"];
    [ud setFloat:_treeHeightMin  forKey:@"pf_treeHeightMin"];
    [ud setFloat:_treeHeightMax  forKey:@"pf_treeHeightMax"];
    [ud setFloat:_treeThickness  forKey:@"pf_treeThickness"];
    [ud setBool:_treePullActive  forKey:@"pf_treePullActive"];
    [ud setFloat:_treePullX      forKey:@"pf_treePullX"];
    [ud setFloat:_treePullZ      forKey:@"pf_treePullZ"];
    [ud setFloat:_treePull       forKey:@"pf_treePull"];
    [ud setFloat:_treeDeadPull   forKey:@"pf_treeDeadPull"];

    // D panel — erosion params
    [ud setFloat:_state->erosionStep     forKey:@"pf_erosionStep"];
    [ud setFloat:_state->erosionHeight   forKey:@"pf_erosionHeight"];
    [ud setFloat:_state->erosionAngle    forKey:@"pf_erosionAngle"];

    // A panel — animation gait params + phase offsets
    for (int i = 0; i < kGaitParamCount; ++i) {
        [ud setFloat:GaitParamGet(i) forKey:[NSString stringWithFormat:@"pf_anim_%d", i]];
        [ud setFloat:GaitPhaseGet(i) forKey:[NSString stringWithFormat:@"pf_animph_%d", i]];
    }

    // Terrain heightfield (+ active grid divisions / world scale so an enlarged plane reloads)
    [ud setBool:Terrain::gHeightFieldActive forKey:@"pf_hfActive"];
    if (Terrain::gHeightFieldActive) {
        NSData *hfData = [NSData dataWithBytes:Terrain::gHeightField
                                        length:sizeof(Terrain::gHeightField)];
        [ud setObject:hfData forKey:@"pf_heightField"];
        [ud setInteger:Terrain::gHFDivs   forKey:@"pf_hfDivs"];
        [ud setFloat:Terrain::gWorldScale forKey:@"pf_hfWorldScale"];
    }

    [ud synchronize];
}

- (void)loadState {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud objectForKey:@"pf_shellGrassDensity"]) return;  // nothing saved yet

    // G panel — shell grass
    _shellGrassVisible  = [ud boolForKey:@"pf_shellGrassVisible"];
    _shellGrassDensity  = [ud floatForKey:@"pf_shellGrassDensity"];
    _shellColorBaseR    = [ud floatForKey:@"pf_shellColorBaseR"];
    _shellColorBaseG    = [ud floatForKey:@"pf_shellColorBaseG"];
    _shellColorBaseB    = [ud floatForKey:@"pf_shellColorBaseB"];
    _shellColorTipR     = [ud floatForKey:@"pf_shellColorTipR"];
    _shellColorTipG     = [ud floatForKey:@"pf_shellColorTipG"];
    _shellColorTipB     = [ud floatForKey:@"pf_shellColorTipB"];

    // G panel — long grass
    _longGrassVisible       = [ud boolForKey:@"pf_longGrassVisible"];
    _longGrassDensity       = [ud floatForKey:@"pf_longGrassDensity"];
    _longStepEdgeDensity    = [ud floatForKey:@"pf_longStepEdgeDensity"];
    _longColorBaseR         = [ud floatForKey:@"pf_longColorBaseR"];
    _longColorBaseG         = [ud floatForKey:@"pf_longColorBaseG"];
    _longColorBaseB         = [ud floatForKey:@"pf_longColorBaseB"];
    _longColorTipR          = [ud floatForKey:@"pf_longColorTipR"];
    _longColorTipG          = [ud floatForKey:@"pf_longColorTipG"];
    _longColorTipB          = [ud floatForKey:@"pf_longColorTipB"];

    // G panel — terrace face roughness
    _terraceNoiseStrength = [ud floatForKey:@"pf_terraceNoiseStr"];
    _terraceNoiseScale    = [ud floatForKey:@"pf_terraceNoiseScl"];
    if (_terraceNoiseScale == 0.0f) _terraceNoiseScale = 1.0f;  // guard against stale 0 saves

    // T panel — tree trunks (only if previously saved)
    if ([ud objectForKey:@"pf_treeDensity"]) {
        _treesVisible  = [ud boolForKey:@"pf_treesVisible"];
        _treeDensity   = [ud floatForKey:@"pf_treeDensity"];
        _treeColorR    = [ud floatForKey:@"pf_treeColorR"];
        _treeColorG    = [ud floatForKey:@"pf_treeColorG"];
        _treeColorB    = [ud floatForKey:@"pf_treeColorB"];
        _treeLeanMin   = [ud floatForKey:@"pf_treeLeanMin"];
        _treeLeanMax   = [ud floatForKey:@"pf_treeLeanMax"];
        _treeDeadDensity = [ud floatForKey:@"pf_treeDeadDensity"];
        _treeDeadLeanMin = [ud floatForKey:@"pf_treeDeadLeanMin"];
        _treeDeadLeanMax = [ud floatForKey:@"pf_treeDeadLeanMax"];
        _treeHeightMin = [ud floatForKey:@"pf_treeHeightMin"];
        _treeHeightMax = [ud floatForKey:@"pf_treeHeightMax"];
        _treeThickness = [ud floatForKey:@"pf_treeThickness"];
        _treePullActive = [ud boolForKey:@"pf_treePullActive"];
        _treePullX      = [ud floatForKey:@"pf_treePullX"];
        _treePullZ      = [ud floatForKey:@"pf_treePullZ"];
        _treePull       = [ud floatForKey:@"pf_treePull"];
        _treeDeadPull   = [ud floatForKey:@"pf_treeDeadPull"];
    }

    // D panel — erosion params
    if (_state) {
        _state->erosionStep   = [ud floatForKey:@"pf_erosionStep"];
        _state->erosionHeight = [ud floatForKey:@"pf_erosionHeight"];
        _state->erosionAngle  = [ud floatForKey:@"pf_erosionAngle"];
    }

    // A panel — animation gait params + phases (rebuild applied lazily on first frame)
    if ([ud objectForKey:@"pf_anim_0"]) {
        for (int i = 0; i < kGaitParamCount; ++i) {
            GaitParamSet(i, [ud floatForKey:[NSString stringWithFormat:@"pf_anim_%d", i]]);
            if ([ud objectForKey:[NSString stringWithFormat:@"pf_animph_%d", i]])
                GaitPhaseSet(i, [ud floatForKey:[NSString stringWithFormat:@"pf_animph_%d", i]]);
        }
        if (_state) _state->animParamsDirty = true;
    }

    // Terrain heightfield (+ active grid divisions / world scale)
    if ([ud boolForKey:@"pf_hfActive"]) {
        NSData *hfData = [ud objectForKey:@"pf_heightField"];
        if (hfData && hfData.length == sizeof(Terrain::gHeightField)) {
            memcpy(Terrain::gHeightField, hfData.bytes, sizeof(Terrain::gHeightField));
            Terrain::gHeightFieldActive = true;
            if ([ud objectForKey:@"pf_hfDivs"]) {
                int divs = (int)[ud integerForKey:@"pf_hfDivs"];
                Terrain::gHFDivs     = (divs < Terrain::kHFBaseDivs) ? Terrain::kHFBaseDivs
                                     : (divs > Terrain::kHFMaxDivs)  ? Terrain::kHFMaxDivs : divs;
                Terrain::gWorldScale = [ud floatForKey:@"pf_hfWorldScale"];
                if (Terrain::gWorldScale < 0.1f) Terrain::gWorldScale = 1.f;
            }
            if (_state) _state->meshRebuildPending = true;
        }
    }

    _stateJustLoaded = YES;
}

- (void)magnifyDelta:(double)delta {
    if (!_state) return;
    auto& s = *_state;
    // Positive delta = fingers spreading = zoom in (reduce distance)
    s.camDist *= (1.0f - (f32)delta);
    s.camDist  = fmaxf(3.0f, fminf(120.0f, s.camDist));
}

- (void)orbitDeltaX:(double)dx deltaY:(double)dy {
    if (!_state) return;
    auto& s = *_state;
    if (s.rightSelectorMode) { s.rightSelectorFrozen = true; return; }
    s.rightDragStarted = true; // early drag — prevents selector mode from activating
    const f32 kSens = 0.008f;
    s.camYaw   += (f32)dx * kSens;
    s.camPitch += (f32)dy * kSens;
    s.camPitch  = fmaxf(0.15f, fminf(1.50f, s.camPitch));
}

- (void)panDeltaX:(double)dx deltaY:(double)dy {
    if (!_state) return;
    auto& s = *_state;
    if (s.rightSelectorMode) { s.rightSelectorFrozen = true; return; }
    s.rightDragStarted = true; // early drag — prevents selector mode from activating
    s.rightDragging = true;
    // Camera right and forward vectors projected to the XZ ground plane
    f32 rightX =  cosf(s.camYaw);
    f32 rightZ = -sinf(s.camYaw);
    f32 fwdX   = -sinf(s.camYaw);
    f32 fwdZ   = -cosf(s.camYaw);
    // Scale speed with distance so the grab feels stable at any zoom level
    const f32 kSpeed = s.camDist * 0.0015f;
    s.camTarget.x -= rightX * (f32)dx * kSpeed;
    s.camTarget.z -= rightZ * (f32)dx * kSpeed;
    s.camTarget.x += fwdX  * (f32)dy * kSpeed;
    s.camTarget.z += fwdZ  * (f32)dy * kSpeed;
}

- (void)keyDown:(int)keyCode {
    if (!_state) return;
    // Map macOS key codes to engine Key enum (subset)
    // macOS: 49=Space, 0=A, 13=W, 1=S, 2=D
    if (keyCode == 53) { // Escape
        _state->deselectAllPending = true;
        return;
    }
    if (keyCode == 2) { // D — toggle debug overlay + terrain editor
        _state->debugRadiiVisible = !_state->debugRadiiVisible;
        _dModeActive = _state->debugRadiiVisible ? YES : NO;
        if (!_dModeActive) _terrainNodePlaceMode = NO;
        return;
    }
    // A panel (procedural gait editor) shelved — see disabled block in renderFrame.
    // if (keyCode == 0) { // A — toggle animation editor panel
    //     _aModeActive = !_aModeActive;
    //     return;
    // }
    if (keyCode == 5) { // G — toggle grass editor panel
        _gModeActive = !_gModeActive;
        return;
    }
    if (keyCode == 17) { // T — toggle tree editor panel
        _tModeActive = !_tModeActive;
        return;
    }
    if (keyCode == 1) { // S — save editor state
        [self saveState];
        return;
    }
    Key k = Key::Unknown;
    switch (keyCode) {
        case 49: k = Key::Space; break;
        case 0:  k = Key::A;     break;
        case 1:  k = Key::S;     break;
        case 2:  k = Key::D;     break;
        case 13: k = Key::W;     break;
        default: break;
    }
    if (k != Key::Unknown) _state->input->OnKeyDown(k);
}

- (void)keyUp:(int)keyCode {
    if (!_state) return;
    Key k = Key::Unknown;
    switch (keyCode) {
        case 49: k = Key::Space; break;
        case 0:  k = Key::A;     break;
        case 1:  k = Key::S;     break;
        case 2:  k = Key::D;     break;
        case 13: k = Key::W;     break;
        default: break;
    }
    if (k != Key::Unknown) _state->input->OnKeyUp(k);
}

@end
