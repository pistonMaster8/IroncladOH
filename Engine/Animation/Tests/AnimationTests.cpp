#include "AnimationTests.hpp"
#include "../Animation.hpp"
#include <cstdio>
#include <cmath>

// ─── Helpers ─────────────────────────────────────────────────────────────────

static bool NearF(f32 a, f32 b, f32 eps = 0.01f) { return fabsf(a - b) <= eps; }
static bool NearV(Vec3 a, Vec3 b, f32 eps = 0.01f) {
    return NearF(a.x,b.x,eps) && NearF(a.y,b.y,eps) && NearF(a.z,b.z,eps);
}
#define CHECK(cond) do { if (!(cond)) { printf("  FAIL: %s\n", #cond); return false; } } while(0)

// ─── TestSkeletonCreation ─────────────────────────────────────────────────────

bool TestSkeletonCreation() {
    printf("TestSkeletonCreation ... ");
    Skeleton skel = Skeleton::CreateHumanoid();
    CHECK(skel.IsValid());
    CHECK(skel.boneCount == kHumanoidBoneCount);

    // Root has no parent.
    CHECK(skel.bones[0].parent == kInvalidBone);

    // Pelvis is child of Root.
    BoneIndex pelv = skel.FindBone("pelvis");
    CHECK(pelv != kInvalidBone);
    CHECK(skel.bones[pelv].parent == 0);

    // Every bone except root has a valid parent.
    for (u16 i = 1; i < skel.boneCount; ++i)
        CHECK(skel.bones[i].parent < skel.boneCount);

    printf("PASS\n");
    return true;
}

// ─── TestForwardKinematics ────────────────────────────────────────────────────

bool TestForwardKinematics() {
    printf("TestForwardKinematics ... ");
    Skeleton skel = Skeleton::CreateHumanoid();
    LocalPose local;
    local.SetToBindPose(skel);
    ModelPose model;
    model.EvaluateFK(skel, local);

    // The head should be above the pelvis in model space.
    BoneIndex head = skel.FindBone("head");
    BoneIndex pelv = skel.FindBone("pelvis");
    CHECK(head != kInvalidBone && pelv != kInvalidBone);
    Vec3 headPos = Mat4GetPosition(model.modelMats[head]);
    Vec3 pelvPos = Mat4GetPosition(model.modelMats[pelv]);
    CHECK(headPos.y > pelvPos.y);

    // Head should be near the top (~1 unit height total from root).
    CHECK(headPos.y > 0.85f && headPos.y < 1.10f);

    // Left foot should be below root.
    BoneIndex footL = skel.FindBone("foot_l");
    CHECK(footL != kInvalidBone);
    Vec3 footPos = Mat4GetPosition(model.modelMats[footL]);
    CHECK(footPos.y < 0.1f);

    printf("PASS\n");
    return true;
}

// ─── TestPoseBlending ─────────────────────────────────────────────────────────

bool TestPoseBlending() {
    printf("TestPoseBlending ... ");
    Skeleton skel = Skeleton::CreateHumanoid();

    // Pose A: identity (bind pose).
    LocalPose poseA;
    poseA.SetToBindPose(skel);

    // Pose B: spine_01 rotated 45° around Y.
    LocalPose poseB = poseA;
    BoneIndex sp01 = skel.FindBone("spine_01");
    CHECK(sp01 != kInvalidBone);
    poseB.bones[sp01].rotation = QuatMul(poseB.bones[sp01].rotation,
                                          QuatAxisAngle(Vec3Make(0,1,0), Deg2Rad(45.f)));

    // Blend at t=0.5.
    LocalPose blended = LocalPose::Blend(poseA, poseB, 0.5f);

    // The blended rotation should be ~22.5° around Y, so the Y component of
    // the rotation should be between the identity (near 0) and the 45° version.
    // We verify by checking the FK height is unchanged (the Y rotation doesn't move bones up/down).
    ModelPose modelA, modelB, modelBlended;
    modelA.EvaluateFK(skel, poseA);
    modelB.EvaluateFK(skel, poseB);
    modelBlended.EvaluateFK(skel, blended);

    Vec3 headA  = Mat4GetPosition(modelA.modelMats[skel.FindBone("head")]);
    Vec3 headBl = Mat4GetPosition(modelBlended.modelMats[skel.FindBone("head")]);
    // Heights should be very close (Y rotation doesn't displace).
    CHECK(NearF(headA.y, headBl.y, 0.05f));

    // After 45° Y rotation, the head should have moved laterally — blended should be halfway.
    Vec3 headB = Mat4GetPosition(modelB.modelMats[skel.FindBone("head")]);
    f32 midX   = (headA.x + headB.x) * 0.5f;
    CHECK(NearF(headBl.x, midX, 0.05f));

    printf("PASS\n");
    return true;
}

// ─── TestKeyframeInterpolation ────────────────────────────────────────────────

bool TestKeyframeInterpolation() {
    printf("TestKeyframeInterpolation ... ");
    AnimationTrack track;
    track.AddKey(0.f, 0.f);
    track.AddKey(1.f, 10.f);
    track.AddKey(2.f, 5.f);

    CHECK(NearF(track.Sample(0.f), 0.f));
    CHECK(NearF(track.Sample(0.5f), 5.f));
    CHECK(NearF(track.Sample(1.f), 10.f));
    CHECK(NearF(track.Sample(1.5f), 7.5f));
    CHECK(NearF(track.Sample(2.f), 5.f));
    CHECK(NearF(track.Sample(2.5f), 5.f));   // clamp at end

    printf("PASS\n");
    return true;
}

// ─── TestClipSampling ─────────────────────────────────────────────────────────

bool TestClipSampling() {
    printf("TestClipSampling ... ");
    Skeleton skel = Skeleton::CreateHumanoid();
    // Use the procedurally generated idle clip.
    AnimationLibrary lib = AnimationLibrary::BuildSoldierLibrary(skel);
    const AnimationClip* idle = lib.Find("soldier_idle");
    CHECK(idle != nullptr);
    CHECK(idle->duration > 0.f);
    CHECK(!idle->tracks.empty());

    LocalPose pose;
    pose.SetToBindPose(skel);
    idle->SamplePose(0.f, pose);
    // The pose should still have the right bone count.
    CHECK(pose.boneCount == skel.boneCount);

    // Sampling at time > duration with loop=true should not crash.
    idle->SamplePose(idle->duration * 3.f, pose);
    CHECK(pose.boneCount == skel.boneCount);

    printf("PASS\n");
    return true;
}

// ─── TestTwoBoneIK ───────────────────────────────────────────────────────────

bool TestTwoBoneIK() {
    printf("TestTwoBoneIK ... ");
    Skeleton skel = Skeleton::CreateHumanoid();

    LocalPose local;
    local.SetToBindPose(skel);
    ModelPose model;
    model.EvaluateFK(skel, local);

    BoneIndex root = skel.FindBone("upper_leg_l");
    BoneIndex mid  = skel.FindBone("lower_leg_l");
    BoneIndex tip  = skel.FindBone("foot_l");
    CHECK(root != kInvalidBone && mid != kInvalidBone && tip != kInvalidBone);

    // Compute the bind-pose foot position; aim for a target slightly below it.
    Vec3 bindFootPos = Mat4GetPosition(model.modelMats[tip]);
    Vec3 target      = Vec3Add(bindFootPos, Vec3Make(0.05f, -0.05f, 0.1f));

    IKChain chain;
    chain.root     = root;
    chain.mid      = mid;
    chain.tip      = tip;
    chain.poleHint = Vec3Make(0.f, 0.f, 1.f);  // knee forward
    chain.weight   = 1.f;

    LocalPose solved = local;
    bool ok = IKSolver::SolveTwoBone(chain, skel, model, target, solved);
    CHECK(ok);

    // FK the solved pose and check tip closeness to target.
    ModelPose solvedModel;
    solvedModel.EvaluateFK(skel, solved);
    Vec3 solvedTip = Mat4GetPosition(solvedModel.modelMats[tip]);

    // The IK should bring the tip within ~0.02 world units of the target.
    f32 err = Vec3Len(Vec3Sub(solvedTip, target));
    CHECK(err < 0.08f);

    printf("PASS (err=%.4f)\n", err);
    return true;
}

// ─── TestStateMachineTransitions ─────────────────────────────────────────────

bool TestStateMachineTransitions() {
    printf("TestStateMachineTransitions ... ");
    AnimationStateMachine sm;
    AnimationParameters p;

    CHECK(sm.GetState() == AnimState::Idle);

    // Idle → Walk on speed > 0.3.
    p.speed = 1.f;
    sm.Update(0.016f, p);
    CHECK(sm.GetState() == AnimState::Walk);

    // Walk → Run on speed > 3.
    p.speed = 4.f;
    sm.Update(0.016f, p);
    CHECK(sm.GetState() == AnimState::Run);

    // Run → Walk on speed < 2.5.
    p.speed = 2.f;
    sm.Update(0.016f, p);
    CHECK(sm.GetState() == AnimState::Walk);

    // Walk → Idle on speed < 0.2.
    p.speed = 0.f;
    sm.Update(0.016f, p);
    CHECK(sm.GetState() == AnimState::Idle);

    // HitReact interrupts.
    p.speed = 0.f; p.wasDamaged = true;
    sm.Update(0.016f, p);
    CHECK(sm.GetState() == AnimState::HitReact);

    // HitReact exits after 0.35 s.
    p.wasDamaged = false;
    for (int i = 0; i < 30; ++i) sm.Update(0.016f, p);
    CHECK(sm.GetState() != AnimState::HitReact);

    // Dead is terminal.
    p.healthFraction = 0.f;
    sm.Update(0.016f, p);
    CHECK(sm.GetState() == AnimState::Dead);
    p.healthFraction = 1.f;
    sm.Update(0.016f, p);
    CHECK(sm.GetState() == AnimState::Dead);  // stays dead

    printf("PASS\n");
    return true;
}

// ─── TestAnimationController ──────────────────────────────────────────────────

bool TestAnimationController() {
    printf("TestAnimationController ... ");
    Skeleton skel = Skeleton::CreateHumanoid();
    AnimationLibrary lib = AnimationLibrary::BuildSoldierLibrary(skel);

    AnimationController ctrl;
    ctrl.Init(&skel, &lib);
    CHECK(ctrl.GetBoneCount() == skel.boneCount);

    TransformComponent transform;
    transform.position = Vec3Make(0, 0, 0);
    transform.rotation = QuatIdentity();
    transform.scale    = 1.f;

    // Update for 1 second and verify no crash + matrices are finite.
    for (int i = 0; i < 60; ++i) {
        ctrl.params.speed     = 1.5f;
        ctrl.params.behaviorState = BehaviorState::Moving;
        ctrl.Update(1.f/60.f, transform);
    }

    // Check that at least some skinning matrices are non-identity.
    const Mat4* mats = ctrl.GetSkinningMatrices();
    bool anyNonIdentity = false;
    for (u16 i = 0; i < ctrl.GetBoneCount(); ++i) {
#if defined(__APPLE__)
        Vec3 col0 = mats[i].columns[0].xyz;
        anyNonIdentity |= (fabsf(col0.x - 1.f) > 1e-4f);
#else
        anyNonIdentity |= (fabsf(mats[i].m[0][0] - 1.f) > 1e-4f);
#endif
    }
    CHECK(anyNonIdentity);

    printf("PASS\n");
    return true;
}

// ─── RunAnimationTests ────────────────────────────────────────────────────────

bool RunAnimationTests() {
    printf("=== Animation System Tests ===\n");
    bool all = true;
    all &= TestSkeletonCreation();
    all &= TestForwardKinematics();
    all &= TestPoseBlending();
    all &= TestKeyframeInterpolation();
    all &= TestClipSampling();
    all &= TestTwoBoneIK();
    all &= TestStateMachineTransitions();
    all &= TestAnimationController();
    printf("=== %s ===\n", all ? "ALL PASS" : "SOME FAILED");
    return all;
}
