#include "AnimationDebug.hpp"
#include <cstring>

AnimationDebugRenderer gAnimDebug;

void AnimationDebugRenderer::Clear() {
    boneLines.clear();
    spheres.clear();
}

void AnimationDebugRenderer::DrawSkeleton(const Skeleton& skel, const ModelPose& pose,
                                           const Mat4& worldTransform,
                                           Vec3 boneColor, Vec3 rootColor) {
    for (u16 i = 0; i < skel.boneCount; ++i) {
        BoneIndex parent = skel.bones[i].parent;
        if (parent == kInvalidBone) continue;

        // Bone endpoints in model space.
        Vec3 childModel  = Mat4GetPosition(pose.modelMats[i]);
        Vec3 parentModel = Mat4GetPosition(pose.modelMats[parent]);

        // Transform to world space.
        auto toWorld = [&](Vec3 v) -> Vec3 {
#if defined(__APPLE__)
            simd_float4 p = simd_mul(worldTransform, Vec4Make(v.x, v.y, v.z, 1.f));
            return p.xyz;
#else
            return Vec3Make(
                worldTransform.m[0][0]*v.x + worldTransform.m[0][1]*v.y + worldTransform.m[0][2]*v.z + worldTransform.m[0][3],
                worldTransform.m[1][0]*v.x + worldTransform.m[1][1]*v.y + worldTransform.m[1][2]*v.z + worldTransform.m[1][3],
                worldTransform.m[2][0]*v.x + worldTransform.m[2][1]*v.y + worldTransform.m[2][2]*v.z + worldTransform.m[2][3]
            );
#endif
        };

        boneLines.push_back({ toWorld(parentModel), toWorld(childModel),
            (parent == 0) ? rootColor : boneColor });
    }
}

void AnimationDebugRenderer::DrawIKTarget(Vec3 worldPos, bool contacted) {
    Vec3 color = contacted ? Vec3Make(0.1f, 1.f, 0.2f) : Vec3Make(1.f, 0.4f, 0.1f);
    spheres.push_back({ worldPos, 0.04f, color });
}

void AnimationDebugRenderer::DrawFootContact(Vec3 worldPos, bool isGrounded) {
    Vec3 color = isGrounded ? Vec3Make(0.f, 1.f, 0.5f) : Vec3Make(1.f, 0.8f, 0.f);
    spheres.push_back({ worldPos, 0.03f, color });
}

void AnimationDebugRenderer::EmitToRenderScene(RenderScene& scene) const {
    // Emit bone lines as small-radius debug rings at the midpoint of each bone.
    for (const auto& line : boneLines) {
        if (scene.debugRingCount >= RenderScene::kMaxDebugRings) break;
        Vec3 mid = Vec3Scale(Vec3Add(line.a, line.b), 0.5f);
        auto& ring = scene.debugRings[scene.debugRingCount++];
        ring.center = mid;
        ring.radius = 0.02f;
        ring.offset = Vec3Make(0, 0, 0);
    }
    // Emit spheres as small debug rings.
    for (const auto& sph : spheres) {
        if (scene.debugRingCount >= RenderScene::kMaxDebugRings) break;
        auto& ring = scene.debugRings[scene.debugRingCount++];
        ring.center = sph.center;
        ring.radius = sph.radius;
        ring.offset = Vec3Make(0, 0, 0);
    }
}
