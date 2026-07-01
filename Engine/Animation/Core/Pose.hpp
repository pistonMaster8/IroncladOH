#pragma once
#include "AnimationTypes.hpp"
#include "Skeleton.hpp"

// ─── LocalPose: per-bone transforms in parent-local space ────────────────────

struct LocalPose {
    BoneTransform bones[kMaxBonesPerSkeleton];
    u16           boneCount { 0 };

    // Reset every bone to the skeleton's bind pose.
    void SetToBindPose(const Skeleton& skel);

    // Reset every bone to identity transform.
    void SetToIdentity(u16 count);

    // Blend two poses linearly (slerp on rotation).
    static LocalPose Blend(const LocalPose& a, const LocalPose& b, f32 t);

    // Blend only the bones where mask.Test(i) is true; other bones come from 'a'.
    static LocalPose BlendMasked(const LocalPose& a, const LocalPose& b,
                                  f32 t, const BoneMask& mask);

    // Additive overlay: result[i] = base[i].Apply(add[i] * weight).
    static LocalPose AddAdditive(const LocalPose& base, const LocalPose& add, f32 weight);
};

// ─── ModelPose: bone transforms in model (root) space ────────────────────────

struct ModelPose {
    Mat4 modelMats[kMaxBonesPerSkeleton];       // model-space transform per bone
    Mat4 skinningMats[kMaxBonesPerSkeleton];    // modelMats[i] * skeleton.inverseBind[i]
    u16  boneCount { 0 };

    // Forward kinematics: walks the hierarchy and accumulates parent matrices.
    void EvaluateFK(const Skeleton& skel, const LocalPose& local);

    // Compute skinning matrices from model-space matrices + inverse bind.
    // Call after EvaluateFK.
    void ComputeSkinningMatrices(const Skeleton& skel);
};
