#pragma once
#include "../Core/AnimationTypes.hpp"
#include "../../Simulation/Components.hpp"

// ─── Animation states ─────────────────────────────────────────────────────────

enum class AnimState : u8 {
    Idle=0, Walk, Run, Turn, Attack, HitReact, Stunned, Dead, Count
};

// ─── AnimationParameters ──────────────────────────────────────────────────────
// Written by the simulation each frame before calling AnimationStateMachine::Update.

struct AnimationParameters {
    f32  speed          { 0.f };    // current world-space movement speed (units/s)
    f32  desiredSpeed   { 0.f };
    f32  facingDelta    { 0.f };    // radians: signed angle from current to desired facing
    f32  healthFraction { 1.f };    // [0,1] — 0 = dead
    f32  damageAmount   { 0.f };    // damage received this frame (0 if none)
    Vec3 damageDir      {};         // world direction of the hit
    bool isAttacking    { false };
    bool wasDamaged     { false };  // true for exactly one frame after damage
    BehaviorState behaviorState { BehaviorState::Idle };
};

// ─── AnimationStateMachine ────────────────────────────────────────────────────

struct AnimationStateMachine {
    AnimState current  { AnimState::Idle };
    AnimState previous { AnimState::Idle };
    f32       stateTime     { 0.f };    // time spent in current state (seconds)
    f32       blendAlpha    { 1.f };    // 0 = fully previous, 1 = fully current
    f32       blendDuration { 0.15f };  // cross-fade duration in seconds

    // Evaluate transition rules and advance blend.
    void Update(f32 dt, const AnimationParameters& params);

    AnimState GetState()     const { return current; }
    AnimState GetPrevState() const { return previous; }
    f32       GetBlend()     const { return blendAlpha; }
    bool      JustEntered()  const { return stateTime < 0.016f; }

    static const char* StateName(AnimState s);

private:
    void TransitionTo(AnimState next);
};
