#pragma once
#include "../Core/AnimationTypes.hpp"
#include "../Core/Skeleton.hpp"
#include "../Core/Pose.hpp"
#include "../Core/HumanoidBones.hpp"

// ─── Per-entity locomotion state ──────────────────────────────────────────────

struct ProceduralLocomotionState {
    f32  stridePhase  { 0.f };   // 0 … 2π
    f32  breathPhase  { 0.f };   // 0 … 2π
    f32  leanAmount   { 0.f };   // current forward lean (radians), smoothed
    Vec3 prevVelocity {};
};

// ─── ProceduralAnimator ───────────────────────────────────────────────────────
// Applies additive procedural modifiers on top of a sampled LocalPose.

namespace ProceduralAnimator {
    // Advance stride phase and apply pelvis bob, arm swing, and leg drive.
    // speed  – world-space movement speed (units/sec)
    // dt     – frame delta
    void ApplyLocomotion(LocalPose& pose, const Skeleton& skel,
                         const HumanoidRig& rig,
                         f32 speed, f32 dt,
                         ProceduralLocomotionState& state);

    // Additive hit reaction: flinch spine and head away from damage direction.
    // hitDirLocal – damage direction in model space (normalised)
    // amount      – damage amount (0..1 relative scale)
    // elapsed     – seconds since the hit was received (for decay curve)
    void ApplyHitReaction(LocalPose& pose, const Skeleton& skel,
                          const HumanoidRig& rig,
                          Vec3 hitDirLocal, f32 amount, f32 elapsed);

    // Smoothly lean the spine forward/backward based on acceleration.
    void ApplyAccelerationLean(LocalPose& pose, const Skeleton& skel,
                               const HumanoidRig& rig,
                               Vec3 accelerationLocal, f32 dt,
                               ProceduralLocomotionState& state);

    // Subtle idle breathing bob on the spine (always on).
    void ApplyBreathing(LocalPose& pose, const Skeleton& skel,
                        const HumanoidRig& rig,
                        f32 dt, f32& breathPhase);
}
