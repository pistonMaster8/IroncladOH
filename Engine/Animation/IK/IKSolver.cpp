#include "IKSolver.hpp"
#include <cmath>

namespace IKSolver {

Vec3 WorldToModelSpace(Vec3 worldPos, const Mat4& unitWorldMatrix) {
    // Invert the unit's world matrix and transform the world point.
    Mat4 invWorld = Mat4Inverse(unitWorldMatrix);
#if defined(__APPLE__)
    simd_float4 p = simd_mul(invWorld, Vec4Make(worldPos.x, worldPos.y, worldPos.z, 1.f));
    return p.xyz;
#else
    f32 x = invWorld.m[0][0]*worldPos.x + invWorld.m[0][1]*worldPos.y + invWorld.m[0][2]*worldPos.z + invWorld.m[0][3];
    f32 y = invWorld.m[1][0]*worldPos.x + invWorld.m[1][1]*worldPos.y + invWorld.m[1][2]*worldPos.z + invWorld.m[1][3];
    f32 z = invWorld.m[2][0]*worldPos.x + invWorld.m[2][1]*worldPos.y + invWorld.m[2][2]*worldPos.z + invWorld.m[2][3];
    return Vec3Make(x, y, z);
#endif
}

bool SolveTwoBone(const IKChain& chain,
                   const Skeleton& skel,
                   const ModelPose& modelPose,
                   Vec3 targetModelSpace,
                   LocalPose& outPose) {
    BoneIndex root = chain.root;
    BoneIndex mid  = chain.mid;
    BoneIndex tip  = chain.tip;

    if (root == kInvalidBone || mid == kInvalidBone || tip == kInvalidBone) return false;
    if (chain.weight < 1e-4f) return true;

    // Model-space bone positions extracted from the FK pose.
    Vec3 P0 = Mat4GetPosition(modelPose.modelMats[root]);
    Vec3 P1 = Mat4GetPosition(modelPose.modelMats[mid]);
    Vec3 P2 = Mat4GetPosition(modelPose.modelMats[tip]);
    Vec3 T  = targetModelSpace;

    // Bone lengths.
    f32 l0 = Vec3Len(Vec3Sub(P1, P0));
    f32 l1 = Vec3Len(Vec3Sub(P2, P1));
    if (l0 < 1e-6f || l1 < 1e-6f) return false;

    // Distance from root to target, clamped to reachable range.
    f32 d = Vec3Len(Vec3Sub(T, P0));
    d = Clamp(d, fabsf(l0 - l1) + 1e-4f, l0 + l1 - 1e-4f);

    // Law of cosines: angle at root between chain axis and root bone.
    f32 cosRoot = Clamp((l0*l0 + d*d - l1*l1) / (2.f*l0*d), -1.f, 1.f);
    f32 sinRoot = sqrtf(1.f - cosRoot*cosRoot);

    // Law of cosines: angle at mid between the two bone segments.
    f32 cosMid  = Clamp((l0*l0 + l1*l1 - d*d) / (2.f*l0*l1), -1.f, 1.f);
    f32 midAngle = acosf(cosMid);  // desired angle between bone segments

    // Direction vectors.
    Vec3 dirToTarget = Vec3Norm(Vec3Sub(T, P0));

    // Build pole vector: component of poleHint perpendicular to dirToTarget.
    Vec3 pole = chain.poleHint;
    if (Vec3Len(pole) < 1e-6f)
        pole = Vec3Make(0.f, 0.f, 1.f);  // fallback: forward

    f32 pDot = Vec3Dot(pole, dirToTarget);
    Vec3 polePerp = Vec3Norm(Vec3Sub(pole, Vec3Scale(dirToTarget, pDot)));
    if (Vec3Len(polePerp) < 1e-5f) {
        // poleHint is parallel to dirToTarget; choose an arbitrary perpendicular.
        polePerp = (fabsf(dirToTarget.x) < 0.9f)
            ? Vec3Norm(Vec3Cross(dirToTarget, Vec3Make(1,0,0)))
            : Vec3Norm(Vec3Cross(dirToTarget, Vec3Make(0,1,0)));
    }

    // Desired mid-point in model space.
    Vec3 P1new = Vec3Add(P0,
        Vec3Add(Vec3Scale(dirToTarget, cosRoot * l0),
                Vec3Scale(polePerp,    sinRoot * l0)));

    // ── Root bone rotation ────────────────────────────────────────────────────
    // Current direction: P1 - P0 (already in model space).
    // Desired direction: P1new - P0.
    Vec3 curRootDir = Vec3Norm(Vec3Sub(P1, P0));
    Vec3 desRootDir = Vec3Norm(Vec3Sub(P1new, P0));

    Quat rootDelta    = QuatBetween(curRootDir, desRootDir);
    Quat rootModelRot = QuatFromMat4(modelPose.modelMats[root]);
    Quat newRootModelRot = QuatMul(rootDelta, rootModelRot);

    // Convert to local space: localRot = inv(parentModelRot) * newModelRot
    BoneIndex rootParent = skel.bones[root].parent;
    Quat parentModelRot  = (rootParent != kInvalidBone)
        ? QuatFromMat4(modelPose.modelMats[rootParent])
        : QuatIdentity();
    outPose.bones[root].rotation = QuatNorm(QuatMul(QuatInverse(parentModelRot), newRootModelRot));

    // ── Mid bone rotation ─────────────────────────────────────────────────────
    // Current direction: P2 - P1.
    // Desired: T - P1new.
    Vec3 curMidDir = Vec3Norm(Vec3Sub(P2, P1));
    Vec3 desMidDir = Vec3Norm(Vec3Sub(T, P1new));

    Quat midDelta    = QuatBetween(curMidDir, desMidDir);
    Quat midModelRot = QuatFromMat4(modelPose.modelMats[mid]);
    Quat newMidModelRot = QuatMul(midDelta, midModelRot);

    // Mid's parent is root; use the NEW root model rotation we just computed.
    outPose.bones[mid].rotation = QuatNorm(QuatMul(QuatInverse(newRootModelRot), newMidModelRot));

    // Blend with original pose if weight < 1.
    if (chain.weight < 0.9999f) {
        outPose.bones[root].rotation = QuatSlerp(
            skel.bones[root].bindPose.rotation,
            outPose.bones[root].rotation, chain.weight);
        outPose.bones[mid].rotation = QuatSlerp(
            skel.bones[mid].bindPose.rotation,
            outPose.bones[mid].rotation, chain.weight);
    }

    return true;
}

} // namespace IKSolver
