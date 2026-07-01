#pragma once
#include "AnimationStateMachine.hpp"
#include "AnimationSampler.hpp"
#include "../Core/HumanoidBones.hpp"
#include "../Core/Pose.hpp"
#include "../../Simulation/Components.hpp"
#include <unordered_map>
#include <functional>

// ─── AnimationLibrary ─────────────────────────────────────────────────────────
// Owns a flat map of named AnimationClips.  Build once at startup.

struct AnimationLibrary {
    std::unordered_map<u64, AnimationClip> clips;

    const AnimationClip* Find(const char* name) const;
    void                 Add(AnimationClip clip);

    // Build the default soldier library with procedurally generated clips.
    static AnimationLibrary BuildSoldierLibrary(const Skeleton& skel);
};

// ─── AnimationController ──────────────────────────────────────────────────────
// Per-entity component.  The simulation creates one per unit, calls Init once,
// then calls Update each simulation tick.
//
// Usage (in simulation):
//   ctrl.params.behaviorState = ai.state;
//   ctrl.params.speed         = len(move.velocity);
//   ctrl.params.wasDamaged    = (health.damageTakenThisFrame > 0);
//   ctrl.Update(dt, transform, [](f32 x, f32 z){ return Terrain::Height(x,z); });

struct AnimationController {
    const Skeleton*   skeleton { nullptr };
    AnimationLibrary* library  { nullptr };
    HumanoidRig       rig;

    AnimationStateMachine stateMachine;
    AnimationParameters   params;
    AnimationSampler      sampler;
    LocalPose             localPose;
    ModelPose             modelPose;

    // Procedural locomotion state
    f32  stridePhase   { 0.f };    // 0 … 2π
    f32  breathPhase   { 0.f };
    Vec3 lastPosition  {};
    f32  smoothedSpeed { 0.f };
    f32  speedOverride { -1.f };   // >= 0 forces this speed (e.g. walk-in-place preview)
    f32  hitReactTime  { -1.f };   // >= 0 while hit reaction is playing

    AnimationDebugData debug;

    void Init(const Skeleton* skel, AnimationLibrary* lib);

    // dt            – frame delta (seconds)
    // transform     – unit's world transform
    // terrainHeight – optional callable (x,z)->y for foot placement
    void Update(f32 dt, const TransformComponent& transform,
                std::function<f32(f32,f32)> terrainHeight = nullptr);

    const Mat4* GetSkinningMatrices() const { return modelPose.skinningMats; }
    u16         GetBoneCount()        const { return modelPose.boneCount; }
};
