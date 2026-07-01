#include "AnimationController.hpp"
#include "../Procedural/ProceduralAnimator.hpp"
#include <cmath>

// Forward declarations of procedural clip factories (defined in AnimationClip.cpp).
AnimationClip MakeSoldierIdleClip(const Skeleton& skel);
AnimationClip MakeSoldierWalkClip(const Skeleton& skel);
AnimationClip MakeSoldierRunClip(const Skeleton& skel);
AnimationClip MakeSoldierHitReactClip(const Skeleton& skel);

// ─── AnimationLibrary ─────────────────────────────────────────────────────────

const AnimationClip* AnimationLibrary::Find(const char* name) const {
    u64 key = StringID::Compute(name);
    auto it = clips.find(key);
    return (it != clips.end()) ? &it->second : nullptr;
}

void AnimationLibrary::Add(AnimationClip clip) {
    u64 key = StringID::Compute(clip.name.c_str());
    clips[key] = std::move(clip);
}

AnimationLibrary AnimationLibrary::BuildSoldierLibrary(const Skeleton& skel) {
    AnimationLibrary lib;
    lib.Add(MakeSoldierIdleClip(skel));
    lib.Add(MakeSoldierWalkClip(skel));
    lib.Add(MakeSoldierRunClip(skel));
    lib.Add(MakeSoldierHitReactClip(skel));
    return lib;
}

// ─── AnimationController ─────────────────────────────────────────────────────

void AnimationController::Init(const Skeleton* skel, AnimationLibrary* lib) {
    skeleton = skel;
    library  = lib;
    if (!skel) return;

    rig = HumanoidRig::FromSkeleton(*skel);
    localPose.SetToBindPose(*skel);
    modelPose.EvaluateFK(*skel, localPose);
    modelPose.ComputeSkinningMatrices(*skel);

    // Start on the idle clip.
    const AnimationClip* idle = lib->Find("soldier_idle");
    if (idle) sampler.SetClip(idle, 0.f);
}

void AnimationController::Update(f32 dt, const TransformComponent& transform,
                                  std::function<f32(f32,f32)> terrainHeight) {
    if (!skeleton || !library) return;

    // ── 1. Compute smoothed speed ─────────────────────────────────────────────
    Vec3 pos = transform.position;
    Vec3 delta = Vec3Sub(pos, lastPosition);
    f32 rawSpeed = (dt > 1e-5f) ? Vec3Len(delta) / dt : 0.f;
    smoothedSpeed = Lerp(smoothedSpeed, rawSpeed, Clamp(dt * 8.f, 0.f, 1.f));
    lastPosition  = pos;

    // Preview override: force a speed (walk-in-place) regardless of actual motion.
    if (speedOverride >= 0.f) smoothedSpeed = speedOverride;

    params.speed = smoothedSpeed;

    // ── 2. State machine ──────────────────────────────────────────────────────
    AnimState prevState = stateMachine.GetState();
    stateMachine.Update(dt, params);
    AnimState curState  = stateMachine.GetState();

    // If the state just changed, hot-swap the primary clip.
    if (curState != prevState) {
        const char* clipName = AnimationStateMachine::StateName(curState);
        const AnimationClip* clip = library->Find(clipName);
        if (clip) sampler.SetClip(clip, stateMachine.blendDuration);
    }

    // ── 3. Sample clip ────────────────────────────────────────────────────────
    sampler.Advance(dt);
    localPose.SetToBindPose(*skeleton);

    // Base stance offsets applied over the T-pose bind. The clip sampler only
    // overwrites channels it animates, so any bone a clip doesn't touch (e.g. the
    // arms during idle) keeps this natural pose instead of staying T-posed.
    auto setBaseRot = [&](HumanoidBone hb, Vec3 axis, f32 deg) {
        BoneIndex b = rig.Get(hb);
        if (b != kInvalidBone)
            localPose.bones[b].rotation = QuatAxisAngle(axis, Deg2Rad(deg));
    };
    // Lower arms to the sides (T-pose arms lie along ±X; rotate about Z to hang them).
    setBaseRot(HumanoidBone::UpperArmL, Vec3Make(0,0,1),  72.f);
    setBaseRot(HumanoidBone::UpperArmR, Vec3Make(0,0,1), -72.f);
    // Slight elbow + knee flex so the stance doesn't read as a stiff mannequin.
    // Elbow hinge is QRZ(∓72)·X (the forearm frame is rotated by the upper-arm lower);
    // negative angle flexes the hand forward. Plain X here would only twist the forearm.
    setBaseRot(HumanoidBone::LowerArmL, Vec3Make(0.309f, -0.951f, 0.f), -22.f);
    setBaseRot(HumanoidBone::LowerArmR, Vec3Make(0.309f,  0.951f, 0.f), -22.f);
    setBaseRot(HumanoidBone::LowerLegL, Vec3Make(1,0,0),  6.f);
    setBaseRot(HumanoidBone::LowerLegR, Vec3Make(1,0,0),  6.f);

    sampler.SampleBlended(localPose, *skeleton);

    // ── 4. Procedural modifiers ───────────────────────────────────────────────
    // Breathing is always on (subtle; reads mostly at idle).
    ProceduralLocomotionState locomotionState { stridePhase, breathPhase };
    ProceduralAnimator::ApplyBreathing(localPose, *skeleton, rig, dt, breathPhase);

    // NOTE: the walk/run *clips* now author the full gait (stride, pelvis bob/sway,
    // counter-rotation, lean). The ApplyLocomotion overlay runs on its own unsynced
    // stride phase, so layering it on top fights the clip and causes wobble — keep it
    // off while clip-driven locomotion is the base. Advance the phase for continuity.
    if (smoothedSpeed > 0.05f) {
        f32 strideFreq = Clamp(smoothedSpeed * 1.8f, 0.5f, 8.f);
        stridePhase += dt * kTwoPi * strideFreq;
        if (stridePhase > kTwoPi) stridePhase -= kTwoPi;
    }

    // Hit reaction decay.
    if (params.wasDamaged) hitReactTime = 0.f;
    if (hitReactTime >= 0.f) {
        ProceduralAnimator::ApplyHitReaction(localPose, *skeleton, rig,
                                             params.damageDir, params.damageAmount,
                                             hitReactTime);
        hitReactTime += dt;
        if (hitReactTime > 0.5f) hitReactTime = -1.f;
    }

    // Clear per-frame flags.
    params.wasDamaged  = false;
    params.damageAmount = 0.f;

    // ── 5. FK + skinning ──────────────────────────────────────────────────────
    modelPose.EvaluateFK(*skeleton, localPose);

    // Optional: foot IK using terrain height.
    if (terrainHeight) {
        auto applyFootIK = [&](HumanoidBone upperLegBone, HumanoidBone lowerLegBone,
                                HumanoidBone footBone, Vec3& targetOut, bool& contactOut) {
            BoneIndex foot = rig.Get(footBone);
            if (foot == kInvalidBone) return;
            Vec3 footModel = Mat4GetPosition(modelPose.modelMats[foot]);
            // Transform foot position to world space.
            Vec3 footWorld = QuatAct(transform.rotation,
                Vec3Scale(footModel, transform.scale));
            footWorld = Vec3Add(footWorld, transform.position);
            f32 terrainY = terrainHeight(footWorld.x, footWorld.z);
            f32 diff = terrainY - footWorld.y;
            contactOut = (diff > -0.05f && diff < 0.15f);
            if (fabsf(diff) < 0.15f) {
                targetOut = Vec3Add(footModel, Vec3Make(0, diff / transform.scale, 0));
                // TODO: call IKSolver::SolveTwoBone here in a future pass.
            } else {
                targetOut = footModel;
            }
        };
        applyFootIK(HumanoidBone::UpperLegL, HumanoidBone::LowerLegL, HumanoidBone::FootL,
                    debug.leftFootTarget, debug.leftFootContact);
        applyFootIK(HumanoidBone::UpperLegR, HumanoidBone::LowerLegR, HumanoidBone::FootR,
                    debug.rightFootTarget, debug.rightFootContact);
    }

    modelPose.ComputeSkinningMatrices(*skeleton);

    // ── 6. Update debug data ──────────────────────────────────────────────────
    debug.currentState = (u8)stateMachine.GetState();
    debug.blendWeight  = stateMachine.GetBlend();
    debug.clipTime     = sampler.GetCurrentTime();
    debug.speed        = smoothedSpeed;
}
