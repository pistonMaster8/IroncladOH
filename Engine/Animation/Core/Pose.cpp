#include "Pose.hpp"
#include <cstring>

// ─── LocalPose ────────────────────────────────────────────────────────────────

void LocalPose::SetToBindPose(const Skeleton& skel) {
    boneCount = skel.boneCount;
    for (u16 i = 0; i < boneCount; ++i)
        bones[i] = skel.bones[i].bindPose;
}

void LocalPose::SetToIdentity(u16 count) {
    boneCount = count;
    for (u16 i = 0; i < count; ++i)
        bones[i] = BoneTransform::Identity();
}

LocalPose LocalPose::Blend(const LocalPose& a, const LocalPose& b, f32 t) {
    PFGE_ASSERT(a.boneCount == b.boneCount);
    LocalPose out;
    out.boneCount = a.boneCount;
    for (u16 i = 0; i < out.boneCount; ++i)
        out.bones[i] = BoneTransform::Lerp(a.bones[i], b.bones[i], t);
    return out;
}

LocalPose LocalPose::BlendMasked(const LocalPose& a, const LocalPose& b,
                                  f32 t, const BoneMask& mask) {
    PFGE_ASSERT(a.boneCount == b.boneCount);
    LocalPose out = a;
    for (u16 i = 0; i < out.boneCount; ++i) {
        if (mask.Test(i))
            out.bones[i] = BoneTransform::Lerp(a.bones[i], b.bones[i], t);
    }
    return out;
}

LocalPose LocalPose::AddAdditive(const LocalPose& base, const LocalPose& add, f32 weight) {
    PFGE_ASSERT(base.boneCount == add.boneCount);
    LocalPose out = base;
    if (weight < 1e-4f) return out;
    for (u16 i = 0; i < out.boneCount; ++i) {
        // Scale additive translation and rotation by weight.
        BoneTransform scaled;
        scaled.translation = Vec3Scale(add.bones[i].translation, weight);
        scaled.rotation    = QuatSlerp(QuatIdentity(), add.bones[i].rotation, weight);
        scaled.scale       = Vec3Lerp(Vec3Make(1,1,1), add.bones[i].scale, weight);
        out.bones[i] = out.bones[i].Apply(scaled);
    }
    return out;
}

// ─── ModelPose ────────────────────────────────────────────────────────────────

void ModelPose::EvaluateFK(const Skeleton& skel, const LocalPose& local) {
    boneCount = skel.boneCount;
    for (u16 i = 0; i < skel.boneCount; ++i) {
        Mat4 localMat = local.bones[i].ToMatrix();
        BoneIndex parent = skel.bones[i].parent;
        if (parent == kInvalidBone) {
            modelMats[i] = localMat;
        } else {
            modelMats[i] = Mat4Mul(modelMats[parent], localMat);
        }
    }
}

void ModelPose::ComputeSkinningMatrices(const Skeleton& skel) {
    for (u16 i = 0; i < boneCount; ++i)
        skinningMats[i] = Mat4Mul(modelMats[i], skel.bones[i].inverseBind);
}
