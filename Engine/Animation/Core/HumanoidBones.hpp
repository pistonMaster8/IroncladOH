#pragma once
#include "AnimationTypes.hpp"
#include "Skeleton.hpp"

// Standard bone name strings — match Skeleton::CreateHumanoid() ordering.
namespace HumanoidBoneNames {
    constexpr const char* kRoot       = "root";
    constexpr const char* kPelvis     = "pelvis";
    constexpr const char* kSpine01    = "spine_01";
    constexpr const char* kSpine02    = "spine_02";
    constexpr const char* kNeck       = "neck";
    constexpr const char* kHead       = "head";
    constexpr const char* kClavicleL  = "clavicle_l";
    constexpr const char* kUpperArmL  = "upper_arm_l";
    constexpr const char* kLowerArmL  = "lower_arm_l";
    constexpr const char* kHandL      = "hand_l";
    constexpr const char* kClavicleR  = "clavicle_r";
    constexpr const char* kUpperArmR  = "upper_arm_r";
    constexpr const char* kLowerArmR  = "lower_arm_r";
    constexpr const char* kHandR      = "hand_r";
    constexpr const char* kUpperLegL  = "upper_leg_l";
    constexpr const char* kLowerLegL  = "lower_leg_l";
    constexpr const char* kFootL      = "foot_l";
    constexpr const char* kToeL       = "toe_l";
    constexpr const char* kUpperLegR  = "upper_leg_r";
    constexpr const char* kLowerLegR  = "lower_leg_r";
    constexpr const char* kFootR      = "foot_r";
    constexpr const char* kToeR       = "toe_r";

    // Indexed by HumanoidBone enum value.
    inline const char* ByEnum(HumanoidBone b) {
        static const char* names[(u16)HumanoidBone::Count] = {
            kRoot, kPelvis, kSpine01, kSpine02, kNeck, kHead,
            kClavicleL, kUpperArmL, kLowerArmL, kHandL,
            kClavicleR, kUpperArmR, kLowerArmR, kHandR,
            kUpperLegL, kLowerLegL, kFootL, kToeL,
            kUpperLegR, kLowerLegR, kFootR, kToeR
        };
        u16 idx = (u16)b;
        return idx < (u16)HumanoidBone::Count ? names[idx] : "unknown";
    }
}

// Maps HumanoidBone enum values to concrete bone indices in an arbitrary skeleton.
// Populated automatically by scanning bone names against the standard set.
struct HumanoidRig {
    BoneIndex map[(u16)HumanoidBone::Count];

    HumanoidRig() { for (auto& m : map) m = kInvalidBone; }

    BoneIndex Get(HumanoidBone b) const { return map[(u16)b]; }
    bool IsMapped(HumanoidBone b) const { return map[(u16)b] != kInvalidBone; }

    bool IsComplete() const {
        for (u16 i = 0; i < (u16)HumanoidBone::Count; ++i)
            if (map[i] == kInvalidBone) return false;
        return true;
    }

    // Auto-populate by matching skeleton bone names to standard names.
    static HumanoidRig FromSkeleton(const Skeleton& skel) {
        HumanoidRig rig;
        for (u16 b = 0; b < (u16)HumanoidBone::Count; ++b) {
            const char* name = HumanoidBoneNames::ByEnum((HumanoidBone)b);
            rig.map[b] = skel.FindBone(name);
        }
        return rig;
    }
};
