#include "Skeleton.hpp"
#include <cstring>

BoneIndex Skeleton::AddBone(StringID name, BoneIndex parent, const BoneTransform& bindPose) {
    PFGE_ASSERT(boneCount < kMaxBones);
    BoneIndex idx = boneCount++;
    bones[idx].name      = name;
    bones[idx].parent    = parent;
    bones[idx].bindPose  = bindPose;
    bones[idx].inverseBind = Mat4Identity();
    return idx;
}

BoneIndex Skeleton::FindBone(StringID name) const {
    for (u16 i = 0; i < boneCount; ++i)
        if (bones[i].name == name) return i;
    return kInvalidBone;
}

void Skeleton::ComputeInverseBindPose() {
    // Accumulate model-space bind matrices (parent-before-child ordering guaranteed).
    Mat4 modelMats[kMaxBones];
    for (u16 i = 0; i < boneCount; ++i) {
        Mat4 localMat = bones[i].bindPose.ToMatrix();
        if (bones[i].parent == kInvalidBone) {
            modelMats[i] = localMat;
        } else {
            modelMats[i] = Mat4Mul(modelMats[bones[i].parent], localMat);
        }
        bones[i].inverseBind = Mat4Inverse(modelMats[i]);
    }
}

// ─── Humanoid skeleton factory ────────────────────────────────────────────────
// Produces a T-pose at unit height (pelvis at 0.5, crown at ~1.02).

Skeleton Skeleton::CreateHumanoid() {
    Skeleton s;
    using BT = BoneTransform;

    auto add = [&](const char* name, BoneIndex parent, Vec3 t) -> BoneIndex {
        BT bt = BT::Identity();
        bt.translation = t;
        return s.AddBone(StringID(name), parent, bt);
    };

    // Root at origin, pelvis up half a unit.
    BoneIndex root   = add("root",       kInvalidBone,      Vec3Make( 0.00f, 0.00f, 0.00f));
    BoneIndex pelv   = add("pelvis",     root,              Vec3Make( 0.00f, 0.50f, 0.00f));

    // Spine chain (slight forward lean accumulates).
    BoneIndex sp01   = add("spine_01",   pelv,              Vec3Make( 0.00f, 0.12f, 0.01f));
    BoneIndex sp02   = add("spine_02",   sp01,              Vec3Make( 0.00f, 0.12f, 0.01f));
    BoneIndex neck   = add("neck",       sp02,              Vec3Make( 0.00f, 0.14f,-0.01f));
    /* head */        add("head",        neck,              Vec3Make( 0.00f, 0.12f, 0.00f));

    // Left arm.
    BoneIndex clL    = add("clavicle_l", sp02,              Vec3Make(-0.05f, 0.10f, 0.00f));
    BoneIndex uaL    = add("upper_arm_l",clL,               Vec3Make(-0.18f, 0.00f, 0.00f));
    BoneIndex laL    = add("lower_arm_l",uaL,               Vec3Make(-0.26f, 0.00f, 0.00f));
    /* hand_l */      add("hand_l",      laL,               Vec3Make(-0.20f, 0.00f, 0.00f));

    // Right arm (mirrored on X).
    BoneIndex clR    = add("clavicle_r", sp02,              Vec3Make( 0.05f, 0.10f, 0.00f));
    BoneIndex uaR    = add("upper_arm_r",clR,               Vec3Make( 0.18f, 0.00f, 0.00f));
    BoneIndex laR    = add("lower_arm_r",uaR,               Vec3Make( 0.26f, 0.00f, 0.00f));
    /* hand_r */      add("hand_r",      laR,               Vec3Make( 0.20f, 0.00f, 0.00f));

    // Left leg.
    BoneIndex ulL    = add("upper_leg_l",pelv,              Vec3Make(-0.10f,-0.02f, 0.00f));
    BoneIndex llL    = add("lower_leg_l",ulL,               Vec3Make( 0.00f,-0.44f, 0.00f));
    BoneIndex ftL    = add("foot_l",     llL,               Vec3Make( 0.00f,-0.40f, 0.00f));
    /* toe_l */       add("toe_l",       ftL,               Vec3Make( 0.14f, 0.00f, 0.12f));

    // Right leg (mirrored on X).
    BoneIndex ulR    = add("upper_leg_r",pelv,              Vec3Make( 0.10f,-0.02f, 0.00f));
    BoneIndex llR    = add("lower_leg_r",ulR,               Vec3Make( 0.00f,-0.44f, 0.00f));
    BoneIndex ftR    = add("foot_r",     llR,               Vec3Make( 0.00f,-0.40f, 0.00f));
    /* toe_r */       add("toe_r",       ftR,               Vec3Make( 0.14f, 0.00f, 0.12f));

    (void)sp02; (void)neck;
    (void)clL; (void)uaL; (void)laL;
    (void)clR; (void)uaR; (void)laR;
    (void)ulL; (void)llL; (void)ftL;
    (void)ulR; (void)llR; (void)ftR;

    s.ComputeInverseBindPose();
    return s;
}
