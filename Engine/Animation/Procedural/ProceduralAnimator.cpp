#include "ProceduralAnimator.hpp"
#include <cmath>

namespace ProceduralAnimator {

// ─── Helpers ─────────────────────────────────────────────────────────────────

static void AddRotDelta(LocalPose& pose, BoneIndex bone, Vec3 axis, f32 angle) {
    if (bone == kInvalidBone) return;
    Quat delta = QuatAxisAngle(Vec3Norm(axis), angle);
    pose.bones[bone].rotation = QuatNorm(QuatMul(pose.bones[bone].rotation, delta));
}

static void AddTransDelta(LocalPose& pose, BoneIndex bone, Vec3 delta) {
    if (bone == kInvalidBone) return;
    pose.bones[bone].translation = Vec3Add(pose.bones[bone].translation, delta);
}

// ─── Breathing ───────────────────────────────────────────────────────────────

void ApplyBreathing(LocalPose& pose, const Skeleton& skel,
                    const HumanoidRig& rig,
                    f32 dt, f32& breathPhase) {
    (void)skel;
    breathPhase += dt * (kTwoPi / 3.5f);  // 3.5 s breath cycle
    if (breathPhase > kTwoPi) breathPhase -= kTwoPi;

    f32 breath = sinf(breathPhase);

    BoneIndex sp01 = rig.Get(HumanoidBone::Spine01);
    BoneIndex sp02 = rig.Get(HumanoidBone::Spine02);

    // Subtle chest expansion: spine tips forward slightly on inhale.
    AddRotDelta(pose, sp01, Vec3Make(1,0,0), breath * Deg2Rad(0.8f));
    AddRotDelta(pose, sp02, Vec3Make(1,0,0), breath * Deg2Rad(0.5f));

    // Micro pelvis rise.
    BoneIndex pelv = rig.Get(HumanoidBone::Pelvis);
    AddTransDelta(pose, pelv, Vec3Make(0.f, breath * 0.003f, 0.f));
}

// ─── Locomotion ──────────────────────────────────────────────────────────────

void ApplyLocomotion(LocalPose& pose, const Skeleton& skel,
                     const HumanoidRig& rig,
                     f32 speed, f32 dt,
                     ProceduralLocomotionState& state) {
    (void)skel;

    // Stride rate scales with speed: ~1 step/s at walk (1 unit/s), faster at run.
    f32 strideFreq = Clamp(speed * 1.8f, 0.5f, 8.f);
    state.stridePhase += dt * kTwoPi * strideFreq;
    if (state.stridePhase > kTwoPi) state.stridePhase -= kTwoPi;

    f32 ph = state.stridePhase;
    f32 w  = Clamp(speed / 4.f, 0.f, 1.f);  // blend weight by speed

    // Pelvis vertical bob.
    f32 bob = sinf(ph * 2.f) * 0.008f * w;
    BoneIndex pelv = rig.Get(HumanoidBone::Pelvis);
    AddTransDelta(pose, pelv, Vec3Make(0.f, bob, 0.f));

    // Lateral pelvis sway.
    f32 sway = sinf(ph) * 0.005f * w;
    AddTransDelta(pose, pelv, Vec3Make(sway, 0.f, 0.f));

    // Spine counter-twist to pelvis.
    BoneIndex sp01 = rig.Get(HumanoidBone::Spine01);
    BoneIndex sp02 = rig.Get(HumanoidBone::Spine02);
    f32 twist = sinf(ph + kPi) * Deg2Rad(3.f) * w;
    AddRotDelta(pose, sp01, Vec3Make(0,1,0), twist);
    AddRotDelta(pose, sp02, Vec3Make(0,1,0), twist * 0.5f);

    // Forward lean with speed.
    f32 lean = Clamp(speed * 0.018f, 0.f, Deg2Rad(8.f));
    AddRotDelta(pose, sp01, Vec3Make(1,0,0), lean * 0.6f);
    AddRotDelta(pose, sp02, Vec3Make(1,0,0), lean * 0.4f);
}

// ─── Hit reaction ─────────────────────────────────────────────────────────────

void ApplyHitReaction(LocalPose& pose, const Skeleton& skel,
                      const HumanoidRig& rig,
                      Vec3 hitDirLocal, f32 amount, f32 elapsed) {
    (void)skel;

    // Decay curve: fast rise (0.05s), exponential fall.
    f32 decay  = (elapsed < 0.05f) ? (elapsed / 0.05f) : expf(-(elapsed - 0.05f) * 8.f);
    f32 scale  = decay * Clamp(amount / 20.f, 0.1f, 1.f);

    // Lean spine away from the hit direction (away = negate hit dir component on X/Z).
    f32 leanX = -hitDirLocal.x * scale * Deg2Rad(12.f);
    f32 leanZ = -hitDirLocal.z * scale * Deg2Rad(6.f);

    BoneIndex sp01 = rig.Get(HumanoidBone::Spine01);
    BoneIndex sp02 = rig.Get(HumanoidBone::Spine02);
    BoneIndex head = rig.Get(HumanoidBone::Head);

    AddRotDelta(pose, sp01, Vec3Make(1,0,0), leanX * 0.6f);
    AddRotDelta(pose, sp01, Vec3Make(0,0,1), leanZ * 0.6f);
    AddRotDelta(pose, sp02, Vec3Make(1,0,0), leanX * 0.4f);
    AddRotDelta(pose, head, Vec3Make(1,0,0), leanX * 0.3f);
}

// ─── Acceleration lean ────────────────────────────────────────────────────────

void ApplyAccelerationLean(LocalPose& pose, const Skeleton& skel,
                            const HumanoidRig& rig,
                            Vec3 accelerationLocal, f32 dt,
                            ProceduralLocomotionState& state) {
    (void)skel;

    f32 accelMag  = Vec3Len(accelerationLocal);
    f32 targetLean = Clamp(-accelerationLocal.z * 0.04f, Deg2Rad(-6.f), Deg2Rad(6.f));
    state.leanAmount = Lerp(state.leanAmount, targetLean, Clamp(dt * 5.f, 0.f, 1.f));

    BoneIndex sp01 = rig.Get(HumanoidBone::Spine01);
    BoneIndex sp02 = rig.Get(HumanoidBone::Spine02);
    (void)accelMag;

    AddRotDelta(pose, sp01, Vec3Make(1,0,0), state.leanAmount * 0.6f);
    AddRotDelta(pose, sp02, Vec3Make(1,0,0), state.leanAmount * 0.4f);
}

} // namespace ProceduralAnimator
