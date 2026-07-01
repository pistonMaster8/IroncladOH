#pragma once
#include "../Core/AnimationTypes.hpp"
#include "../Core/Skeleton.hpp"
#include "../Core/Pose.hpp"

// ─── IKChain ──────────────────────────────────────────────────────────────────

struct IKChain {
    BoneIndex root     { kInvalidBone };  // e.g. UpperLegL
    BoneIndex mid      { kInvalidBone };  // e.g. LowerLegL
    BoneIndex tip      { kInvalidBone };  // e.g. FootL
    Vec3      poleHint {};                // model-space preferred bend direction (e.g. knee forward)
    f32       weight   { 1.f };           // blend weight [0,1]
};

// ─── IKSolver ─────────────────────────────────────────────────────────────────

namespace IKSolver {
    // Two-bone analytical IK using the law of cosines.
    //
    // targetModelSpace – desired tip position in model space
    // outPose          – receives updated local rotations for root and mid bones
    //
    // Returns false if the target is unreachable (chain too short / degenerate input).
    // Chain lengths are inferred from modelPose.modelMats at call time.
    bool SolveTwoBone(const IKChain&    chain,
                      const Skeleton&   skel,
                      const ModelPose&  modelPose,
                      Vec3              targetModelSpace,
                      LocalPose&        outPose);

    // Convert a world-space position to model space given the unit's world matrix.
    Vec3 WorldToModelSpace(Vec3 worldPos, const Mat4& unitWorldMatrix);
}
