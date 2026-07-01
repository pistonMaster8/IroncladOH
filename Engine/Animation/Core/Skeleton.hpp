#pragma once
#include "AnimationTypes.hpp"
#include "../../Core/StringID.hpp"
#include <array>

struct Bone {
    StringID      name;
    BoneIndex     parent   { kInvalidBone };
    BoneTransform bindPose { BoneTransform::Identity() };
    Mat4          inverseBind;   // set by Skeleton::ComputeInverseBindPose()
};

struct Skeleton {
    static constexpr u16 kMaxBones = kMaxBonesPerSkeleton;

    std::array<Bone, kMaxBones> bones {};
    u16 boneCount { 0 };

    // Add a bone and return its index. Parents must be added before children.
    BoneIndex AddBone(StringID name, BoneIndex parent, const BoneTransform& bindPose);

    BoneIndex FindBone(StringID name) const;
    BoneIndex FindBone(const char* name) const { return FindBone(StringID(name)); }

    // Walk the hierarchy in order to compute model-space bind matrices, then
    // store their inverses in each Bone::inverseBind.
    void ComputeInverseBindPose();

    // Build the standard 22-bone humanoid skeleton at unit height (1.0 world unit).
    static Skeleton CreateHumanoid();

    bool IsValid() const { return boneCount > 0; }
};
