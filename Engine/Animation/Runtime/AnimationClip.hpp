#pragma once
#include "../Core/AnimationTypes.hpp"
#include "../Core/Pose.hpp"
#include <vector>
#include <string>

// ─── Keyframe ─────────────────────────────────────────────────────────────────

struct Keyframe {
    f32 time  { 0.f };
    f32 value { 0.f };
};

// ─── AnimationTrack ───────────────────────────────────────────────────────────

struct AnimationTrack {
    enum class Channel : u8 {
        TX, TY, TZ,      // translation XYZ
        RX, RY, RZ, RW,  // rotation quaternion XYZW
        SX, SY, SZ       // scale XYZ
    };

    BoneIndex bone    { kInvalidBone };
    Channel   channel { Channel::TX };
    std::vector<Keyframe> keys;

    void AddKey(f32 time, f32 value) { keys.push_back({time, value}); }

    // Linear interpolation between bracketing keyframes.
    f32 Sample(f32 t) const;
};

// ─── ClipEvent ────────────────────────────────────────────────────────────────

struct ClipEvent {
    f32 time   { 0.f };
    u32 nameID { 0 };   // FNV-1a hash of the event name
    f32 param  { 0.f };
};

// ─── AnimationClip ────────────────────────────────────────────────────────────

struct AnimationClip {
    std::string name;
    f32         duration    { 1.f };
    bool        loop        { true };
    f32         ticksPerSec { 30.f };

    std::vector<AnimationTrack> tracks;
    std::vector<ClipEvent>      events;

    // Sample all tracks into outPose at the given time.
    // outPose must already be initialized (SetToBindPose or prior sample).
    // Only bones referenced by tracks are modified.
    void SamplePose(f32 time, LocalPose& outPose) const;

    // Wrap/clamp time to [0, duration).
    f32 WrapTime(f32 t) const;
};
