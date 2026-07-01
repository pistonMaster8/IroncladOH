#include "AnimationStateMachine.hpp"
#include <cmath>

const char* AnimationStateMachine::StateName(AnimState s) {
    switch (s) {
        case AnimState::Idle:     return "soldier_idle";
        case AnimState::Walk:     return "soldier_walk";
        case AnimState::Run:      return "soldier_run";
        case AnimState::Turn:     return "soldier_idle";   // reuse idle for now
        case AnimState::Attack:   return "soldier_walk";   // placeholder
        case AnimState::HitReact: return "soldier_hit_react";
        case AnimState::Stunned:  return "soldier_idle";
        case AnimState::Dead:     return "soldier_idle";
        default:                  return "soldier_idle";
    }
}

void AnimationStateMachine::TransitionTo(AnimState next) {
    if (next == current) return;
    previous  = current;
    current   = next;
    stateTime = 0.f;
    blendAlpha = (blendDuration < 1e-4f) ? 1.f : 0.f;
}

void AnimationStateMachine::Update(f32 dt, const AnimationParameters& p) {
    stateTime += dt;

    // Advance blend alpha.
    if (blendAlpha < 1.f) {
        blendAlpha += dt / blendDuration;
        if (blendAlpha > 1.f) blendAlpha = 1.f;
    }

    // ── Highest-priority transitions (evaluated every frame) ──────────────────

    // Death is terminal.
    if (current != AnimState::Dead) {
        if (p.behaviorState == BehaviorState::Dead || p.healthFraction <= 0.f) {
            TransitionTo(AnimState::Dead);
            return;
        }
    }

    // Stunned (stays until behavior changes).
    if (current != AnimState::Stunned && current != AnimState::Dead) {
        if (p.behaviorState == BehaviorState::Stunned) {
            TransitionTo(AnimState::Stunned);
            return;
        }
    }
    if (current == AnimState::Stunned) {
        if (p.behaviorState != BehaviorState::Stunned)
            TransitionTo(AnimState::Idle);
        return;
    }

    // Hit reaction — one-shot, minimum 0.35 s.
    if (p.wasDamaged && current != AnimState::Dead && current != AnimState::HitReact) {
        TransitionTo(AnimState::HitReact);
        return;
    }
    if (current == AnimState::HitReact) {
        if (stateTime >= 0.35f)
            TransitionTo(p.speed > 0.3f ? AnimState::Walk : AnimState::Idle);
        return;
    }

    // ── Normal locomotion transitions ─────────────────────────────────────────

    switch (current) {
        case AnimState::Idle:
            if (fabsf(p.facingDelta) > 0.5f)        TransitionTo(AnimState::Turn);
            else if (p.speed > 0.3f)                 TransitionTo(AnimState::Walk);
            break;

        case AnimState::Turn:
            if (p.speed > 0.3f)                      TransitionTo(AnimState::Walk);
            else if (fabsf(p.facingDelta) < 0.15f)   TransitionTo(AnimState::Idle);
            break;

        case AnimState::Walk:
            if (p.speed < 0.2f)                      TransitionTo(AnimState::Idle);
            else if (p.speed > 3.0f)                 TransitionTo(AnimState::Run);
            else if (p.isAttacking)                   TransitionTo(AnimState::Attack);
            break;

        case AnimState::Run:
            if (p.speed < 2.5f)                      TransitionTo(AnimState::Walk);
            break;

        case AnimState::Attack:
            if (!p.isAttacking)
                TransitionTo(p.speed > 0.3f ? AnimState::Walk : AnimState::Idle);
            break;

        default: break;
    }
}
