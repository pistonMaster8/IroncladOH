#pragma once
#include "AnimationClip.hpp"
#include "../Core/Skeleton.hpp"
#include <vector>

// ─── ClipLayer ────────────────────────────────────────────────────────────────

struct ClipLayer {
    const AnimationClip* clip   { nullptr };
    f32                  time   { 0.f };
    f32                  weight { 1.f };
    f32                  blendInRemaining  { 0.f };  // seconds left in blend-in ramp
    f32                  blendInDuration   { 0.1f };
    bool                 active { false };
};

// ─── AnimationSampler ─────────────────────────────────────────────────────────
// Manages up to 4 concurrent clip layers and blends them into one LocalPose.

struct AnimationSampler {
    static constexpr int kMaxLayers = 4;
    ClipLayer layers[kMaxLayers];

    // Set the primary clip (layer 0), with optional blend-in duration.
    void SetClip(const AnimationClip* clip, f32 blendIn = 0.1f);

    // Advance all active layers by dt.
    void Advance(f32 dt);

    // Blend all active layers into outPose, using outPose's current state as the base.
    void SampleBlended(LocalPose& outPose, const Skeleton& skel) const;

    // Collect events that fired during the last Advance() step.
    void CollectEvents(std::vector<AnimationEvent>& outEvents) const;

    f32  GetCurrentTime()  const { return layers[0].time; }
    const AnimationClip* GetCurrentClip() const { return layers[0].clip; }

private:
    f32 m_prevTime[kMaxLayers] {};  // times before last Advance(), for event detection
};
