#pragma once
#include "../Core/AnimationTypes.hpp"
#include "../Core/Skeleton.hpp"
#include "../Runtime/AnimationClip.hpp"
#include <string>
#include <vector>

// ─── ObjectiveCoordImporter ───────────────────────────────────────────────────
// Converts objective bone-endpoint coordinate data to AnimationClips.
//
// Input format (JSON or text stream):
//   {
//     "animation_id": "run_01",
//     "fps": 30.0,
//     "loop": true,
//     "frames": [
//       {
//         "frame": 0,
//         "bones": [
//           {
//             "bone_id":    "upper_leg_l",
//             "parent_id":  "pelvis",
//             "start":      [0.0, 0.5, 0.0],   // bone root in world space
//             "end":        [0.0, 0.06, 0.0],   // bone tip in world space
//             "roll":       0.0,                // optional twist around bone axis (rad)
//             "confidence": 1.0,               // optional weight [0,1]
//             "contact":    false              // foot/hand ground contact flag
//           }
//         ]
//       }
//     ]
//   }
//
// Conversion algorithm (per frame, per bone):
//   1.  Compute bone direction = normalise(end – start).
//   2.  Compute expected bind direction = normalise(childBindPos – parentBindPos) from Skeleton.
//   3.  Infer local rotation = QuatBetween(expectedDir, actualDir) composed with bind local rot.
//   4.  Apply roll as a twist quaternion around the bone direction axis.
//   5.  Validate bone length ‖end – start‖ against bind length; emit warning on deviation.
//   6.  Store quaternion components as AnimationTrack keyframes (RX/RY/RZ/RW channels).
//
// Not fully implemented in MVP — stub interface preserved for future tooling.

struct ObjectiveCoordBone {
    std::string boneID;
    std::string parentID;
    Vec3        start      {};
    Vec3        end        {};
    f32         roll       { 0.f };
    f32         confidence { 1.f };
    bool        contact    { false };
};

struct ObjectiveCoordFrame {
    int                           frame { 0 };
    std::vector<ObjectiveCoordBone> bones;
};

struct ObjectiveCoordClip {
    std::string name;
    f32         fps   { 30.f };
    bool        loop  { false };
    std::vector<ObjectiveCoordFrame> frames;
};

// Convert an ObjectiveCoordClip to a runtime AnimationClip.
// Returns false on degenerate input (missing bones, frame 0 absent, etc.).
// boneStretchTolerance: fraction of bind-length deviation that triggers a warning
//   (default 5%).  Frames above 1.5× tolerance are dropped.
bool ConvertToAnimationClip(const ObjectiveCoordClip& src,
                             const Skeleton&            skel,
                             AnimationClip&             outClip,
                             f32 boneStretchTolerance = 0.05f);
