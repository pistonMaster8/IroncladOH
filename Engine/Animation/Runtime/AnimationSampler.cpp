#include "AnimationSampler.hpp"
#include <cstring>

void AnimationSampler::SetClip(const AnimationClip* clip, f32 blendIn) {
    if (!clip) return;
    // If already playing this clip, just reset time.
    if (layers[0].clip == clip && layers[0].active) {
        layers[0].time = 0.f;
        return;
    }
    // Shift current layer 0 into layer 1 (for cross-fade).
    if (layers[0].active && layers[0].clip != nullptr) {
        layers[1] = layers[0];
        layers[1].weight = 1.f - layers[0].blendInRemaining / layers[0].blendInDuration;
    }
    layers[0].clip             = clip;
    layers[0].time             = 0.f;
    layers[0].weight           = (blendIn < 1e-4f) ? 1.f : 0.f;
    layers[0].blendInDuration  = blendIn;
    layers[0].blendInRemaining = blendIn;
    layers[0].active           = true;
    m_prevTime[0]              = 0.f;
}

void AnimationSampler::Advance(f32 dt) {
    for (int i = 0; i < kMaxLayers; ++i) {
        if (!layers[i].active || !layers[i].clip) continue;
        m_prevTime[i] = layers[i].time;
        layers[i].time += dt;
        layers[i].time  = layers[i].clip->WrapTime(layers[i].time);

        // Advance blend-in ramp.
        if (layers[i].blendInRemaining > 0.f) {
            layers[i].blendInRemaining -= dt;
            if (layers[i].blendInRemaining <= 0.f) {
                layers[i].blendInRemaining = 0.f;
                layers[i].weight = 1.f;
                // Deactivate blend-out layer when the primary is fully blended in.
                if (i == 0 && layers[1].active)
                    layers[1].active = false;
            } else {
                layers[i].weight = 1.f - layers[i].blendInRemaining / layers[i].blendInDuration;
            }
        }
    }
}

void AnimationSampler::SampleBlended(LocalPose& outPose, const Skeleton& skel) const {
    // Layer 0 is the primary; layer 1 is the fade-out layer.
    // Blend layer 1 → layer 0 using layer 0's weight.
    if (layers[1].active && layers[1].clip && layers[0].weight < 1.f) {
        LocalPose poseA = outPose;
        LocalPose poseB = outPose;
        layers[1].clip->SamplePose(layers[1].time, poseA);
        if (layers[0].clip) layers[0].clip->SamplePose(layers[0].time, poseB);
        outPose = LocalPose::Blend(poseA, poseB, layers[0].weight);
    } else if (layers[0].active && layers[0].clip) {
        layers[0].clip->SamplePose(layers[0].time, outPose);
    }

    // Additional overlay layers (layers 2 and 3) are additive.
    for (int i = 2; i < kMaxLayers; ++i) {
        if (!layers[i].active || !layers[i].clip) continue;
        LocalPose addPose = outPose;
        layers[i].clip->SamplePose(layers[i].time, addPose);
        outPose = LocalPose::AddAdditive(outPose, addPose, layers[i].weight);
    }
}

void AnimationSampler::CollectEvents(std::vector<AnimationEvent>& outEvents) const {
    for (int i = 0; i < kMaxLayers; ++i) {
        if (!layers[i].active || !layers[i].clip) continue;
        const auto& clip = *layers[i].clip;
        f32 prev = m_prevTime[i];
        f32 curr = layers[i].time;
        for (const auto& ev : clip.events) {
            // Detect forward crossing (handles wrap-around).
            bool crossed = (curr >= prev)
                ? (ev.time > prev && ev.time <= curr)
                : (ev.time > prev || ev.time <= curr);
            if (crossed) {
                AnimationEvent ae;
                ae.time  = ev.time;
                ae.id    = ev.nameID;
                ae.value = ev.param;
                outEvents.push_back(ae);
            }
        }
    }
}
