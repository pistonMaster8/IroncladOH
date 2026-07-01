#pragma once
#include "../../Core/Types.hpp"

// ─── Runtime-tunable gait parameters ─────────────────────────────────────────
// These drive MakeSoldierWalkClip / MakeSoldierRunClip. They are mutable globals
// so the in-game A panel can retune the locomotion live (rebuild the clip library
// after changing them). Field order is fixed — the editor indexes it flatly.

struct GaitParams {
    f32 duration;     // one full stride (two steps), seconds
    f32 thighAmp;     // hip fore/aft swing amplitude (deg)
    f32 thighBias;    // forward mean of hip swing (deg)
    f32 kneeBase;     // stance knee flex (deg)
    f32 kneeSwing;    // extra swing-phase knee flex (deg)
    f32 armAmp;       // shoulder fore/aft swing (deg)
    f32 lean;         // constant forward torso lean (deg)
    f32 bob;          // pelvis vertical bob amplitude (world units)
    f32 sway;         // pelvis lateral sway amplitude (world units)
    f32 pelvYaw;      // pelvis transverse rotation (deg)
    f32 foot;         // ankle pitch amplitude (deg)
    f32 elbowSwing;   // dynamic elbow flex over the swing (deg, on top of a 28° base)
};

static constexpr int kGaitParamFields = 12;            // floats per GaitParams
static constexpr int kGaitParamCount  = kGaitParamFields * 2;  // walk + run

extern GaitParams gWalkGaitParams;
extern GaitParams gRunGaitParams;

// Per-field stride-phase offsets (degrees); default 0 = authored phasing.
extern GaitParams gWalkGaitPhase;
extern GaitParams gRunGaitPhase;

// Flat editor access: index 0..11 = walk fields, 12..23 = run fields.
const char* GaitParamLabel(int index);
f32         GaitParamGet(int index);
void        GaitParamSet(int index, f32 value);
f32         GaitPhaseGet(int index);
void        GaitPhaseSet(int index, f32 value);
