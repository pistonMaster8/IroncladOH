#pragma once
#include "../Core/AnimationTypes.hpp"
#include "../Core/Skeleton.hpp"
#include "../Core/Pose.hpp"
#include "../../Renderer/IRenderer.hpp"
#include <vector>
#include <string>

// ─── AnimationDebugRenderer ───────────────────────────────────────────────────
// Accumulates per-frame debug primitives for the animation system.
// Call Clear() at the start of each frame.  The renderer may read from it any
// time after the simulation update.

struct AnimationDebugRenderer {
    struct BoneLine {
        Vec3 a, b;
        Vec3 color;
    };
    struct DebugSphere {
        Vec3 center;
        f32  radius;
        Vec3 color;
    };

    std::vector<BoneLine>    boneLines;
    std::vector<DebugSphere> spheres;

    void Clear();

    // Draw skeleton bones as line segments from parent to child.
    void DrawSkeleton(const Skeleton& skel, const ModelPose& pose,
                      const Mat4& worldTransform,
                      Vec3 boneColor = Vec3Make(0.2f, 0.8f, 1.0f),
                      Vec3 rootColor = Vec3Make(1.0f, 0.5f, 0.1f));

    // Draw a sphere at an IK target position.
    void DrawIKTarget(Vec3 worldPos, bool contacted);

    // Draw a foot contact indicator.
    void DrawFootContact(Vec3 worldPos, bool isGrounded);

    // Emit debug primitives to the RenderScene debug ring list.
    // Bone lines are approximated as small radius circles at the midpoint.
    void EmitToRenderScene(RenderScene& scene) const;
};

// Global per-frame debug renderer (reset each frame in the simulation update).
extern AnimationDebugRenderer gAnimDebug;
