// MetalRenderer.mm — Metal (Objective-C++) implementation of IRenderer
// Requires macOS 12+ / iOS 15+, Metal GPU family Apple7 (M1 / A15) baseline.

// std headers BEFORE Apple simd to avoid namespace pollution
#include <vector>
#include <cstring>
#include <cmath>
#include <memory>
#include <limits>
#include <cstdio>
#include <queue>
#include <utility>
#include <unordered_map>
#include <unordered_set>
#include <algorithm>
#include <climits>

// ─── GLTF loader (single-header, one translation unit only) ──────────────────
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Weverything"
#define CGLTF_IMPLEMENTATION
#include "cgltf.h"
#pragma clang diagnostic pop

#include "MetalRenderer.hpp"
#include "../../Core/Log.hpp"
#include "../../Core/Math.hpp"
#include "../../Simulation/Terrain.hpp"

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>
#import <QuartzCore/CAMetalLayer.h>
#import <Foundation/Foundation.h>
#import <simd/simd.h>

// ─── GPU-side vertex/uniform structs (must match shader definitions) ──────────
struct GpuVertex {
    simd_float3 position;
    simd_float3 normal;
    simd_float2 uv;
};

struct GpuFrameUniforms {
    simd_float4x4 viewProj;
    simd_float3   cameraPos;
    float         time;
    simd_float3   lightDir;
    float         _pad0;
    simd_float3   lightColor;
    float         _pad1;
    simd_float3   ambientColor;
    float         _pad2;
    simd_float4   auraData[8]; // xy = XZ center, z = radius, w = unused
    int32_t       auraCount;
    float         _pad3[3];
};

struct RingGpuVertex {
    float x, y, z;    // position (offset 0, 12 bytes)
    float r, g, b, a; // RGBA color (offset 12, 16 bytes)
};                     // stride: 28 bytes, no padding needed

struct GpuInstanceData {
    simd_float4x4 model;     // named 'model' to match MSL shader
    simd_float3   tint;
    float         selected;  // 0 or 1
};

struct SkyGpuUniforms {
    simd_float4x4 invViewProj;
    simd_float3   sunDir;
    float         time;
};

struct ShellCtrlGpu {
    simd_float3 colorBase;
    float       density;
    simd_float3 colorTip;
    float       _pad;
};

// ─── Skinned mesh types (GLTF) ────────────────────────────────────────────────
struct SkinnedGpuVertex {
    simd_float3 position;   // offset  0, size 16
    simd_float3 normal;     // offset 16, size 16
    simd_float2 uv;         // offset 32, size  8
    uint16_t    joints[4];  // offset 40, size  8
    float       weights[4]; // offset 48, size 16
};                          // total:         64

static constexpr uint32_t kMaxJoints = 64;
static constexpr uint32_t kMaxNodes  = 256;

struct GltfModel {
    id<MTLBuffer>  vertexBuf        = nil;
    id<MTLBuffer>  indexBuf         = nil;
    uint32_t       indexCount       = 0;
    bool           indexU32         = false;
    bool           loaded           = false;

    uint32_t       jointCount       = 0;
    simd_float4x4  invBind[kMaxJoints];
    int            jointNode[kMaxJoints];

    int            nodeCount        = 0;
    int            nodeParent[kMaxNodes];
    bool           nodeHasMat[kMaxNodes];
    simd_float4x4  nodeMat[kMaxNodes];   // used when nodeHasMat[i]
    float          nodeT[kMaxNodes][3];  // rest translation
    float          nodeR[kMaxNodes][4];  // rest rotation (xyzw quaternion)
    float          nodeS[kMaxNodes][3];  // rest scale

    int            sortedNodes[kMaxNodes];
    int            sortedNodeCount  = 0;

    std::string    nodeName[kMaxNodes];

    // ─── Animation retargeting (built once after load) ───────────────────────
    // Drives this glTF (Mixamo) skeleton from the procedural humanoid pose.
    int            nodeToHumanoid[kMaxNodes];     // HumanoidBone ordinal driving node, or -1
    simd_quatf     nodeRestModelRot[kMaxNodes];   // rest-pose model-space rotation per node
    int            retargetMappedCount = 0;       // # joints mapped to a humanoid bone

    struct Channel {
        int nodeIdx, prop;  // prop: 0=translation 1=rotation 2=scale
        std::vector<float>       times;
        std::vector<simd_float4> vals;
    };
    struct AnimClip {
        std::string          name;
        float                duration = 0.0f;
        std::vector<Channel> channels;
    };
    std::vector<AnimClip> clips;

    int FindClip(const char* name) const {
        for (int i = 0; i < (int)clips.size(); ++i)
            if (clips[i].name == name) return i;
        return -1;
    }

    float scale = 1.0f;
    float offX  = 0.0f;
    float offZ  = 0.0f;
};

// ─── Procedural geometry helpers ──────────────────────────────────────────────
static void BuildUnitMesh(std::vector<GpuVertex>& verts, std::vector<uint16_t>& idx) {
    // Simple capsule-ish shape: hexagonal prism + hemisphere top
    // For brevity: 8-sided prism, height 1.5, radius 0.4
    const int kSides = 8;
    const float kR   = 0.4f;
    const float kH   = 0.75f; // half height
    const float kStep = (float)(2.0 * M_PI / kSides);

    uint16_t base = 0;

    // Bottom ring
    for (int i = 0; i < kSides; ++i) {
        float a = i * kStep;
        GpuVertex v;
        v.position = { kR * cosf(a), -kH, kR * sinf(a) };
        v.normal   = simd_normalize(simd_make_float3(cosf(a), 0, sinf(a)));
        v.uv       = { (float)i / kSides, 0 };
        verts.push_back(v);
    }
    // Top ring
    for (int i = 0; i < kSides; ++i) {
        float a = i * kStep;
        GpuVertex v;
        v.position = { kR * cosf(a), kH, kR * sinf(a) };
        v.normal   = simd_normalize(simd_make_float3(cosf(a), 0, sinf(a)));
        v.uv       = { (float)i / kSides, 1 };
        verts.push_back(v);
    }
    // Side quads
    for (int i = 0; i < kSides; ++i) {
        uint16_t a = base + i;
        uint16_t b = base + (i + 1) % kSides;
        uint16_t c = base + kSides + i;
        uint16_t d = base + kSides + (i + 1) % kSides;
        idx.insert(idx.end(), {a, c, b, b, c, d});
    }
    // Top cap
    uint16_t apex = (uint16_t)verts.size();
    GpuVertex top; top.position={0, kH+kR, 0}; top.normal={0,1,0}; top.uv={0.5f,0.5f};
    verts.push_back(top);
    for (int i = 0; i < kSides; ++i) {
        uint16_t a = base + kSides + i;
        uint16_t b = base + kSides + (i + 1) % kSides;
        idx.insert(idx.end(), {apex, b, a});
    }
    // Bottom cap
    uint16_t bot = (uint16_t)verts.size();
    GpuVertex bv; bv.position={0,-kH,0}; bv.normal={0,-1,0}; bv.uv={0.5f,0.5f};
    verts.push_back(bv);
    for (int i = 0; i < kSides; ++i) {
        uint16_t a = base + i;
        uint16_t b = base + (i + 1) % kSides;
        idx.insert(idx.end(), {bot, a, b});
    }
}

static void BuildGroundMesh(std::vector<GpuVertex>& verts, std::vector<uint16_t>& idx) {
    const float kSize  = 90.0f;
    const int   kDivs  = 200;
    const float kStep  = kSize * 2.0f / kDivs;

    const int stride = kDivs + 1;
    verts.resize((size_t)stride * stride);
    for (int zi = 0; zi <= kDivs; ++zi) {
        for (int xi = 0; xi <= kDivs; ++xi) {
            float x = -kSize + xi * kStep;
            float z = -kSize + zi * kStep;
            GpuVertex& v = verts[zi * stride + xi];
            v.position = { x, Terrain::Height(x, z), z };
            v.normal   = { 0, 1, 0 };
            v.uv       = { (float)xi / kDivs, (float)zi / kDivs };
        }
    }

    // Per-vertex normals via central finite differences
    for (int zi = 0; zi <= kDivs; ++zi) {
        for (int xi = 0; xi <= kDivs; ++xi) {
            int xi0 = (xi > 0) ? xi-1 : xi, xi1 = (xi < kDivs) ? xi+1 : xi;
            int zi0 = (zi > 0) ? zi-1 : zi, zi1 = (zi < kDivs) ? zi+1 : zi;
            float hL = verts[zi  * stride + xi0].position.y;
            float hR = verts[zi  * stride + xi1].position.y;
            float hD = verts[zi0 * stride + xi ].position.y;
            float hU = verts[zi1 * stride + xi ].position.y;
            float dhdx = (hR - hL) / ((float)(xi1 - xi0) * kStep);
            float dhdz = (hU - hD) / ((float)(zi1 - zi0) * kStep);
            verts[zi * stride + xi].normal = simd_normalize(simd_make_float3(-dhdx, 1.f, -dhdz));
        }
    }

    for (int zi = 0; zi < kDivs; ++zi) {
        for (int xi = 0; xi < kDivs; ++xi) {
            uint16_t a = (uint16_t)(zi * stride + xi);
            uint16_t b = a + 1;
            uint16_t c = (uint16_t)((zi+1) * stride + xi);
            uint16_t d = c + 1;
            idx.insert(idx.end(), {a, c, b, b, c, d});
        }
    }
}

static void BuildSphereMesh(std::vector<GpuVertex>& verts, std::vector<uint16_t>& idx,
                            int stacks = 8, int slices = 12) {
    for (int i = 0; i <= stacks; ++i) {
        float phi = (float)M_PI * i / stacks;
        for (int j = 0; j <= slices; ++j) {
            float theta = 2.0f * (float)M_PI * j / slices;
            GpuVertex v;
            v.position = { sinf(phi)*cosf(theta), cosf(phi), sinf(phi)*sinf(theta) };
            v.normal   = v.position;
            v.uv       = { (float)j / slices, (float)i / stacks };
            verts.push_back(v);
        }
    }
    for (int i = 0; i < stacks; ++i) {
        for (int j = 0; j < slices; ++j) {
            uint16_t a = (uint16_t)(i * (slices+1) + j);
            uint16_t b = a + 1;
            uint16_t c = (uint16_t)((i+1) * (slices+1) + j);
            uint16_t d = c + 1;
            idx.insert(idx.end(), {a, c, b, b, c, d});
        }
    }
}

static void BuildDiscMesh(std::vector<GpuVertex>& verts, std::vector<uint16_t>& idx, int sides = 20) {
    // Flat disc in the XZ plane, radius 1, normal pointing up
    GpuVertex center; center.position={0,0,0}; center.normal={0,1,0}; center.uv={0.5f,0.5f};
    verts.push_back(center);
    for (int i = 0; i < sides; ++i) {
        float a = 2.0f * (float)M_PI * i / sides;
        GpuVertex v;
        v.position = { cosf(a), 0, sinf(a) };
        v.normal   = { 0, 1, 0 };
        v.uv       = { 0.5f + 0.5f * cosf(a), 0.5f + 0.5f * sinf(a) };
        verts.push_back(v);
    }
    for (int i = 0; i < sides; ++i) {
        idx.push_back(0);
        idx.push_back((uint16_t)(1 + i));
        idx.push_back((uint16_t)(1 + (i + 1) % sides));
    }
}

static void BuildBoxMesh(std::vector<GpuVertex>& verts, std::vector<uint16_t>& idx) {
    // Unit cube -0.5..+0.5, 6 faces with per-face normals (24 verts, 36 indices)
    struct Face { float nx,ny,nz; float v[4][3]; };
    static const Face faces[6] = {
        { 0,1,0,  {{-0.5f,0.5f,-0.5f},{0.5f,0.5f,-0.5f},{0.5f,0.5f,0.5f},{-0.5f,0.5f,0.5f}} },  // +Y
        { 0,-1,0, {{-0.5f,-0.5f,0.5f},{0.5f,-0.5f,0.5f},{0.5f,-0.5f,-0.5f},{-0.5f,-0.5f,-0.5f}} }, // -Y
        { 1,0,0,  {{0.5f,-0.5f,-0.5f},{0.5f,-0.5f,0.5f},{0.5f,0.5f,0.5f},{0.5f,0.5f,-0.5f}} },   // +X
        { -1,0,0, {{-0.5f,-0.5f,0.5f},{-0.5f,-0.5f,-0.5f},{-0.5f,0.5f,-0.5f},{-0.5f,0.5f,0.5f}} }, // -X
        { 0,0,1,  {{-0.5f,-0.5f,0.5f},{0.5f,-0.5f,0.5f},{0.5f,0.5f,0.5f},{-0.5f,0.5f,0.5f}} },   // +Z
        { 0,0,-1, {{0.5f,-0.5f,-0.5f},{-0.5f,-0.5f,-0.5f},{-0.5f,0.5f,-0.5f},{0.5f,0.5f,-0.5f}} }, // -Z
    };
    for (int f = 0; f < 6; ++f) {
        uint16_t b = (uint16_t)verts.size();
        for (int v = 0; v < 4; ++v) {
            GpuVertex gv;
            gv.position = simd_make_float3(faces[f].v[v][0], faces[f].v[v][1], faces[f].v[v][2]);
            gv.normal   = simd_make_float3(faces[f].nx, faces[f].ny, faces[f].nz);
            gv.uv       = simd_make_float2((float)(v&1), (float)(v>>1));
            verts.push_back(gv);
        }
        idx.insert(idx.end(), { b, (uint16_t)(b+1), (uint16_t)(b+2), b, (uint16_t)(b+2), (uint16_t)(b+3) });
    }
}

// ─── Procedural tree trunk ────────────────────────────────────────────────────
// A thick, gnarly, mostly-cylindrical trunk (unit height, base at y=0): only a mild
// taper, with lumpy/asymmetric radius (vertical lumps + per-side bulges) so each
// looks like a rough log rather than a spike. Per-instance yaw/scale/tint vary the
// scattered forest. Branches/leaves come later.
static void BuildTrunkMesh(std::vector<GpuVertex>& verts, std::vector<uint16_t>& idx) {
    const int   sides   = 9;
    const int   segs    = 9;
    const float H       = 1.0f;
    const float baseR   = 0.32f;    // thick base
    const float topR    = 0.24f;    // only mild taper → cylindrical
    const float bendX   = 0.05f;    // subtle lean
    const float taperUp = 0.15f;    // normal up-tilt for shading
    const float kTwoPiF = 6.2831853f;

    auto centerAt = [&](float t, float& cx, float& cz) {
        cx = bendX * t * t;
        cz = 0.04f * sinf(t * 3.5f);
    };
    // Uneven radius — varies with height AND around the ring (asymmetric lumps).
    auto radiusAt = [&](float t, int k) {
        float profile = baseR + (topR - baseR) * t;
        float uneven  = 0.16f * sinf(t * 6.5f + 1.7f)        // vertical lumps
                      + 0.09f * sinf(t * 13.0f)
                      + 0.13f * sinf((float)k * 2.39996f + t * 4.0f); // per-side bulges
        return profile * (1.0f + uneven);
    };

    // Side rings.
    for (int s = 0; s <= segs; ++s) {
        float t = (float)s / segs, y = t * H, cx, cz;
        centerAt(t, cx, cz);
        for (int k = 0; k < sides; ++k) {
            float a = (float)k / sides * kTwoPiF, ca = cosf(a), sa = sinf(a);
            float r = radiusAt(t, k);
            GpuVertex gv;
            gv.position = simd_make_float3(cx + r * ca, y, cz + r * sa);
            gv.normal   = simd_normalize(simd_make_float3(ca, taperUp, sa));
            gv.uv       = simd_make_float2((float)k / sides, t);
            verts.push_back(gv);
        }
    }
    // Side quads.
    for (int s = 0; s < segs; ++s)
        for (int k = 0; k < sides; ++k) {
            uint16_t a = (uint16_t)(s * sides + k);
            uint16_t b = (uint16_t)(s * sides + (k + 1) % sides);
            uint16_t c = (uint16_t)((s + 1) * sides + (k + 1) % sides);
            uint16_t e = (uint16_t)((s + 1) * sides + k);
            idx.insert(idx.end(), { a, b, c, a, c, e });
        }
    // Top cap.
    {
        float cx, cz; centerAt(1.0f, cx, cz);
        uint16_t center = (uint16_t)verts.size();
        GpuVertex cv;
        cv.position = simd_make_float3(cx, H, cz);
        cv.normal   = simd_make_float3(0, 1, 0);
        cv.uv       = simd_make_float2(0.5f, 0.5f);
        verts.push_back(cv);
        uint16_t ring = (uint16_t)(segs * sides);
        for (int k = 0; k < sides; ++k)
            idx.insert(idx.end(), { center, (uint16_t)(ring + (k + 1) % sides), (uint16_t)(ring + k) });
    }
}

// ─── GLTF skinned model helpers ───────────────────────────────────────────────

static simd_float4x4 QuatToMat4x4(float qx, float qy, float qz, float qw) {
    float x2=qx*qx, y2=qy*qy, z2=qz*qz;
    return (simd_float4x4){{
        simd_make_float4(1-2*(y2+z2),     2*(qx*qy+qz*qw),  2*(qx*qz-qy*qw), 0),
        simd_make_float4(2*(qx*qy-qz*qw), 1-2*(x2+z2),      2*(qy*qz+qx*qw), 0),
        simd_make_float4(2*(qx*qz+qy*qw), 2*(qy*qz-qx*qw),  1-2*(x2+y2),     0),
        simd_make_float4(0, 0, 0, 1)
    }};
}

// Elementwise linear interpolation of 4x4 matrices (good enough for blending bone poses).
static simd_float4x4 LerpMat4x4(simd_float4x4 a, simd_float4x4 b, float t) {
    simd_float4 tv = simd_make_float4(t, t, t, t);
    return (simd_float4x4){{
        simd_mix(a.columns[0], b.columns[0], tv),
        simd_mix(a.columns[1], b.columns[1], tv),
        simd_mix(a.columns[2], b.columns[2], tv),
        simd_mix(a.columns[3], b.columns[3], tv)
    }};
}

// Compute kMaxJoints bone matrices for the given clip and time, writing into outBones.
// outBones must point to kMaxJoints * simd_float4x4 storage.
static void ComputeBoneMatrices(const GltfModel& m, const GltfModel::AnimClip& clip,
                                float time, simd_float4x4* outBones) {
    float t = (clip.duration > 1e-6f) ? fmodf(fmaxf(0.0f, time), clip.duration) : 0.0f;

    // Working per-node TRS (initialized to rest pose)
    float wT[kMaxNodes][3], wR[kMaxNodes][4], wS[kMaxNodes][3];
    for (int i = 0; i < m.nodeCount; ++i) {
        memcpy(wT[i], m.nodeT[i], 12);
        memcpy(wR[i], m.nodeR[i], 16);
        memcpy(wS[i], m.nodeS[i], 12);
    }

    // Apply animation channels (linear interpolation)
    for (const auto& ch : clip.channels) {
        if (ch.times.empty()) continue;
        int ni = ch.nodeIdx;
        if (ni < 0 || ni >= m.nodeCount || m.nodeHasMat[ni]) continue;

        int hi = (int)ch.times.size() - 1;
        int lo = 0;
        for (int k = 0; k < hi; ++k) {
            if (t <= ch.times[k+1]) { lo = k; hi = k+1; break; }
        }
        float range = ch.times[hi] - ch.times[lo];
        float alpha = (range > 1e-6f) ? (t - ch.times[lo]) / range : 0.0f;
        alpha = fmaxf(0.0f, fminf(1.0f, alpha));

        simd_float4 vlo = ch.vals[lo], vhi = ch.vals[hi];
        if (ch.prop == 0) {
            wT[ni][0] = vlo.x + (vhi.x-vlo.x)*alpha;
            wT[ni][1] = vlo.y + (vhi.y-vlo.y)*alpha;
            wT[ni][2] = vlo.z + (vhi.z-vlo.z)*alpha;
        } else if (ch.prop == 1) {
            // NLERP (good enough for walk cycles)
            simd_float4 q = vlo + (vhi - vlo) * alpha;
            float len = simd_length(q);
            if (len > 1e-6f) q /= len;
            wR[ni][0]=q.x; wR[ni][1]=q.y; wR[ni][2]=q.z; wR[ni][3]=q.w;
        } else {
            wS[ni][0] = vlo.x + (vhi.x-vlo.x)*alpha;
            wS[ni][1] = vlo.y + (vhi.y-vlo.y)*alpha;
            wS[ni][2] = vlo.z + (vhi.z-vlo.z)*alpha;
        }
    }

    // Compute world matrices in topological order (parent always processed first)
    simd_float4x4 worldMat[kMaxNodes];
    for (int si = 0; si < m.sortedNodeCount; ++si) {
        int n = m.sortedNodes[si];
        simd_float4x4 local;
        if (m.nodeHasMat[n]) {
            local = m.nodeMat[n];
        } else {
            float* T=wT[n]; float* R=wR[n]; float* S=wS[n];
            simd_float4x4 Tm = {{
                simd_make_float4(1,0,0,0), simd_make_float4(0,1,0,0),
                simd_make_float4(0,0,1,0), simd_make_float4(T[0],T[1],T[2],1)
            }};
            simd_float4x4 Rm = QuatToMat4x4(R[0], R[1], R[2], R[3]);
            simd_float4x4 Sm = {{
                simd_make_float4(S[0],0,0,0), simd_make_float4(0,S[1],0,0),
                simd_make_float4(0,0,S[2],0), simd_make_float4(0,0,0,1)
            }};
            local = simd_mul(Tm, simd_mul(Rm, Sm));
        }
        worldMat[n] = (m.nodeParent[n] < 0)
            ? local
            : simd_mul(worldMat[m.nodeParent[n]], local);
    }

    // Skin matrices = worldTransform * inverseBindMatrix
    for (uint32_t j = 0; j < m.jointCount && j < kMaxJoints; ++j) {
        int ni = m.jointNode[j];
        outBones[j] = (ni >= 0 && ni < m.nodeCount)
            ? simd_mul(worldMat[ni], m.invBind[j])
            : matrix_identity_float4x4;
    }
    for (uint32_t j = m.jointCount; j < kMaxJoints; ++j)
        outBones[j] = matrix_identity_float4x4;
}

// ─── Animation retargeting [SHELVED 2026-06-24] ──────────────────────────────
// Drives the glTF (Mixamo) skeleton from the procedural humanoid pose using a
// model-space additive retarget: both rigs share a T-pose bind with matching
// limb directions, so a humanoid bone's model-space rotation delta transfers
// directly onto the corresponding Mixamo joint. We then run the same
// worldMat * invBind skinning math, so scale/orientation come from the mesh's
// own bind data (no giants, no supine soldiers).
//
// Disabled while the procedural system is parked. To reimplement, restore the
// #if 0 region below, the BuildRetargetMap call in init, and the retarget branch
// in the skinned render loop, plus the EngineHost procedural feed.
#if 0
// Humanoid ordinals — MUST mirror HumanoidBone enum order (Engine/Animation).
enum HBone {
    HB_Root=0, HB_Pelvis, HB_Spine01, HB_Spine02, HB_Neck, HB_Head,
    HB_ClavicleL, HB_UpperArmL, HB_LowerArmL, HB_HandL,
    HB_ClavicleR, HB_UpperArmR, HB_LowerArmR, HB_HandR,
    HB_UpperLegL, HB_LowerLegL, HB_FootL, HB_ToeL,
    HB_UpperLegR, HB_LowerLegR, HB_FootR, HB_ToeR
};

static simd_quatf QuatFromMat4(simd_float4x4 m) {
    simd_float3 c0 = simd_normalize(m.columns[0].xyz);
    simd_float3 c1 = simd_normalize(m.columns[1].xyz);
    simd_float3 c2 = simd_normalize(m.columns[2].xyz);
    return simd_quaternion(simd_matrix(c0, c1, c2));
}

static simd_float4x4 MakeTRS(const float T[3], simd_quatf R, const float S[3]) {
    simd_float4x4 m = simd_matrix4x4(R);
    m.columns[0] *= S[0];
    m.columns[1] *= S[1];
    m.columns[2] *= S[2];
    m.columns[3]  = simd_make_float4(T[0], T[1], T[2], 1.0f);
    return m;
}

// Exact Mixamo joint name (sans "mixamorig:" prefix) → humanoid ordinal.
// Fingers and the extra Spine2 chest joint are intentionally left unmapped
// (they ride their animated parent at rest orientation).
static void BuildRetargetMap(GltfModel& m) {
    struct HMap { const char* name; int hb; };
    static const HMap kMixamoMap[] = {
        {"Hips", HB_Pelvis},
        {"Spine", HB_Spine01}, {"Spine1", HB_Spine02},
        {"Neck", HB_Neck}, {"Head", HB_Head},
        {"LeftShoulder", HB_ClavicleL}, {"LeftArm", HB_UpperArmL},
        {"LeftForeArm", HB_LowerArmL},  {"LeftHand", HB_HandL},
        {"RightShoulder", HB_ClavicleR},{"RightArm", HB_UpperArmR},
        {"RightForeArm", HB_LowerArmR}, {"RightHand", HB_HandR},
        {"LeftUpLeg", HB_UpperLegL}, {"LeftLeg", HB_LowerLegL},
        {"LeftFoot", HB_FootL},      {"LeftToeBase", HB_ToeL},
        {"RightUpLeg", HB_UpperLegR},{"RightLeg", HB_LowerLegR},
        {"RightFoot", HB_FootR},     {"RightToeBase", HB_ToeR},
    };

    // Rest-pose model-space rotation for every node (parent-before-child order).
    std::vector<simd_float4x4> worldMat(m.nodeCount);
    for (int si = 0; si < m.sortedNodeCount; ++si) {
        int n = m.sortedNodes[si];
        simd_float4x4 local;
        if (m.nodeHasMat[n]) {
            local = m.nodeMat[n];
        } else {
            simd_quatf R = simd_quaternion(m.nodeR[n][0], m.nodeR[n][1],
                                           m.nodeR[n][2], m.nodeR[n][3]);
            local = MakeTRS(m.nodeT[n], R, m.nodeS[n]);
        }
        worldMat[n] = (m.nodeParent[n] < 0)
            ? local : simd_mul(worldMat[m.nodeParent[n]], local);
        m.nodeRestModelRot[n] = QuatFromMat4(worldMat[n]);
    }

    // Match each joint node's name to a humanoid bone.
    m.retargetMappedCount = 0;
    for (uint32_t j = 0; j < m.jointCount; ++j) {
        int n = m.jointNode[j];
        if (n < 0 || n >= m.nodeCount) continue;
        const std::string& nm = m.nodeName[n];
        size_t c = nm.find_last_of(':');
        std::string bare = (c == std::string::npos) ? nm : nm.substr(c + 1);
        for (const auto& e : kMixamoMap) {
            if (bare == e.name) { m.nodeToHumanoid[n] = e.hb; m.retargetMappedCount++; break; }
        }
    }
    LOG_INF("Renderer", "Retarget: mapped %d/%u joints to humanoid bones",
            m.retargetMappedCount, m.jointCount);
}

// Produce skinning matrices by retargeting humanoid model-space rotations
// (deltas[], indexed by HumanoidBone ordinal) onto the glTF skeleton.
static void ComputeRetargetedBoneMatrices(const GltfModel& m,
                                          const simd_quatf* deltas,
                                          simd_float4x4* outBones) {
    const simd_quatf qId = simd_quaternion(0.f, 0.f, 0.f, 1.f);
    std::vector<simd_float4x4> worldMat(m.nodeCount);
    std::vector<simd_quatf>    animModelRot(m.nodeCount);

    for (int si = 0; si < m.sortedNodeCount; ++si) {
        int n      = m.sortedNodes[si];
        int parent = m.nodeParent[n];
        simd_quatf parentModelRot = (parent < 0) ? qId : animModelRot[parent];

        simd_float4x4 local;
        if (m.nodeHasMat[n]) {
            local = m.nodeMat[n];
            simd_float4x4 w = (parent < 0) ? local : simd_mul(worldMat[parent], local);
            animModelRot[n] = QuatFromMat4(w);
        } else {
            int h = m.nodeToHumanoid[n];
            simd_quatf localRot;
            if (h >= 0) {
                // Frame correction: the Mixamo rig faces -Z while the humanoid rig
                // faces +Z — a Z-reflection between the two world bases. Reflecting a
                // rotation across the XY plane negates the quaternion's x and y parts.
                simd_quatf d  = deltas[h];
                simd_quatf dm = simd_quaternion(-d.vector.x, -d.vector.y,
                                                 d.vector.z,  d.vector.w);
                // Animated model rotation = corrected delta applied to rest model rotation.
                simd_quatf modelRot = simd_mul(dm, m.nodeRestModelRot[n]);
                localRot        = simd_mul(simd_conjugate(parentModelRot), modelRot);
                animModelRot[n] = modelRot;
            } else {
                // Unmapped: keep rest local rotation, ride the animated parent.
                localRot = simd_quaternion(m.nodeR[n][0], m.nodeR[n][1],
                                           m.nodeR[n][2], m.nodeR[n][3]);
                animModelRot[n] = simd_mul(parentModelRot, localRot);
            }
            local = MakeTRS(m.nodeT[n], localRot, m.nodeS[n]);
        }
        worldMat[n] = (parent < 0) ? local : simd_mul(worldMat[parent], local);
    }

    for (uint32_t j = 0; j < m.jointCount && j < kMaxJoints; ++j) {
        int n = m.jointNode[j];
        outBones[j] = (n >= 0 && n < m.nodeCount)
            ? simd_mul(worldMat[n], m.invBind[j])
            : matrix_identity_float4x4;
    }
    for (uint32_t j = m.jointCount; j < kMaxJoints; ++j)
        outBones[j] = matrix_identity_float4x4;
}
#endif // animation retargeting shelved

static bool LoadGltfModel(id<MTLDevice> device, const char* path, GltfModel& out) {
    cgltf_options opts = {};
    cgltf_data* data   = nullptr;
    if (cgltf_parse_file(&opts, path, &data) != cgltf_result_success) {
        LOG_ERR("Renderer", "GLTF parse failed: %s", path);
        return false;
    }
    if (cgltf_load_buffers(&opts, data, path) != cgltf_result_success) {
        cgltf_free(data);
        LOG_ERR("Renderer", "GLTF buffer load failed");
        return false;
    }
    if (data->meshes_count == 0 || data->skins_count == 0) {
        cgltf_free(data);
        LOG_ERR("Renderer", "GLTF has no mesh/skin");
        return false;
    }

    // ─── Mesh ─────────────────────────────────────────────────────────────────
    cgltf_primitive& prim = data->meshes[0].primitives[0];
    cgltf_accessor *posAcc=nullptr, *nrmAcc=nullptr, *uvAcc=nullptr,
                   *jtAcc=nullptr,  *wtAcc=nullptr;
    for (size_t a = 0; a < prim.attributes_count; ++a) {
        auto& attr = prim.attributes[a];
        if (attr.type == cgltf_attribute_type_position  )              posAcc = attr.data;
        if (attr.type == cgltf_attribute_type_normal    )              nrmAcc = attr.data;
        if (attr.type == cgltf_attribute_type_texcoord && attr.index==0) uvAcc = attr.data;
        if (attr.type == cgltf_attribute_type_joints   && attr.index==0) jtAcc = attr.data;
        if (attr.type == cgltf_attribute_type_weights  && attr.index==0) wtAcc = attr.data;
    }
    if (!posAcc || !jtAcc || !wtAcc) {
        cgltf_free(data);
        LOG_ERR("Renderer", "GLTF missing position/joints/weights");
        return false;
    }

    size_t vCount = posAcc->count;
    std::vector<SkinnedGpuVertex> verts(vCount);
    float mnX=1e9f, mxX=-1e9f, mnY=1e9f, mxY=-1e9f, mnZ=1e9f, mxZ=-1e9f;

    for (size_t i = 0; i < vCount; ++i) {
        float pos[3]={0,0,0}, nrm[3]={0,1,0}, uv[2]={0,0}, wt[4]={1,0,0,0};
        cgltf_uint jt[4]={0,0,0,0};
        cgltf_accessor_read_float(posAcc, i, pos, 3);
        if (nrmAcc) cgltf_accessor_read_float(nrmAcc, i, nrm, 3);
        if (uvAcc ) cgltf_accessor_read_float(uvAcc,  i, uv,  2);
        if (wtAcc ) cgltf_accessor_read_float(wtAcc,  i, wt,  4);
        cgltf_accessor_read_uint(jtAcc, i, jt, 4);

        auto& v = verts[i];
        v.position  = simd_make_float3(pos[0], pos[1], pos[2]);
        v.normal    = simd_make_float3(nrm[0], nrm[1], nrm[2]);
        v.uv        = simd_make_float2(uv[0], uv[1]);
        v.joints[0] = (uint16_t)jt[0]; v.joints[1] = (uint16_t)jt[1];
        v.joints[2] = (uint16_t)jt[2]; v.joints[3] = (uint16_t)jt[3];
        v.weights[0]= wt[0]; v.weights[1]= wt[1];
        v.weights[2]= wt[2]; v.weights[3]= wt[3];

        mnX=fminf(mnX,pos[0]); mxX=fmaxf(mxX,pos[0]);
        mnY=fminf(mnY,pos[1]); mxY=fmaxf(mxY,pos[1]);
        mnZ=fminf(mnZ,pos[2]); mxZ=fmaxf(mxZ,pos[2]);
    }

    out.vertexBuf = [device newBufferWithBytes:verts.data()
                                        length:verts.size() * sizeof(SkinnedGpuVertex)
                                       options:MTLResourceStorageModeShared];

    // ─── Indices ──────────────────────────────────────────────────────────────
    if (prim.indices) {
        auto* idxAcc   = prim.indices;
        out.indexCount = (uint32_t)idxAcc->count;
        out.indexU32   = (idxAcc->component_type == cgltf_component_type_r_32u);
        if (out.indexU32) {
            std::vector<uint32_t> idx(out.indexCount);
            for (uint32_t i = 0; i < out.indexCount; ++i) {
                cgltf_uint v; cgltf_accessor_read_uint(idxAcc, i, &v, 1); idx[i] = v;
            }
            out.indexBuf = [device newBufferWithBytes:idx.data()
                                               length:out.indexCount*4
                                              options:MTLResourceStorageModeShared];
        } else {
            std::vector<uint16_t> idx(out.indexCount);
            for (uint32_t i = 0; i < out.indexCount; ++i) {
                cgltf_uint v; cgltf_accessor_read_uint(idxAcc, i, &v, 1); idx[i] = (uint16_t)v;
            }
            out.indexBuf = [device newBufferWithBytes:idx.data()
                                               length:out.indexCount*2
                                              options:MTLResourceStorageModeShared];
        }
    }

    // ─── Node hierarchy ───────────────────────────────────────────────────────
    out.nodeCount = (int)std::min(data->nodes_count, (size_t)kMaxNodes);
    for (int i = 0; i < out.nodeCount; ++i) {
        auto& node       = data->nodes[i];
        out.nodeParent[i]= -1;
        out.nodeToHumanoid[i]   = -1;
        out.nodeRestModelRot[i] = simd_quaternion(0.f, 0.f, 0.f, 1.f);
        out.nodeName[i]  = node.name ? node.name : "";
        out.nodeHasMat[i]= (bool)node.has_matrix;
        if (node.has_matrix) {
            memcpy(&out.nodeMat[i], node.matrix, 64);
        } else {
            float defT[3]={0,0,0}, defR[4]={0,0,0,1}, defS[3]={1,1,1};
            if (node.has_translation) memcpy(defT, node.translation, 12);
            if (node.has_rotation)    memcpy(defR, node.rotation,    16);
            if (node.has_scale)       memcpy(defS, node.scale,       12);
            memcpy(out.nodeT[i], defT, 12);
            memcpy(out.nodeR[i], defR, 16);
            memcpy(out.nodeS[i], defS, 12);
        }
    }
    for (int i = 0; i < out.nodeCount; ++i) {
        auto& node = data->nodes[i];
        for (size_t c = 0; c < node.children_count; ++c) {
            int ci = (int)(node.children[c] - data->nodes);
            if (ci >= 0 && ci < out.nodeCount) out.nodeParent[ci] = i;
        }
    }

    // BFS topological sort (parent before child)
    out.sortedNodeCount = 0;
    std::vector<bool> vis(out.nodeCount, false);
    std::queue<int> bfsQ;
    for (int i = 0; i < out.nodeCount; ++i)
        if (out.nodeParent[i] == -1) { bfsQ.push(i); vis[i] = true; }
    while (!bfsQ.empty()) {
        int n = bfsQ.front(); bfsQ.pop();
        out.sortedNodes[out.sortedNodeCount++] = n;
        auto& node = data->nodes[n];
        for (size_t c = 0; c < node.children_count; ++c) {
            int ci = (int)(node.children[c] - data->nodes);
            if (ci >= 0 && ci < out.nodeCount && !vis[ci]) {
                vis[ci] = true; bfsQ.push(ci);
            }
        }
    }

    // ─── Scale from root node's effective world-space height ──────────────────
    // Done here, after BFS, so sortedNodes[0] is the scene root node.
    {
        simd_float4x4 rootWorld = matrix_identity_float4x4;
        if (out.sortedNodeCount > 0) {
            int rn = out.sortedNodes[0];
            if (out.nodeHasMat[rn]) {
                rootWorld = out.nodeMat[rn];
            } else {
                float* T = out.nodeT[rn], *R = out.nodeR[rn], *S = out.nodeS[rn];
                simd_float4x4 Tm = {{
                    simd_make_float4(1,0,0,0), simd_make_float4(0,1,0,0),
                    simd_make_float4(0,0,1,0), simd_make_float4(T[0],T[1],T[2],1)
                }};
                simd_float4x4 Rm = QuatToMat4x4(R[0],R[1],R[2],R[3]);
                simd_float4x4 Sm = {{
                    simd_make_float4(S[0],0,0,0), simd_make_float4(0,S[1],0,0),
                    simd_make_float4(0,0,S[2],0), simd_make_float4(0,0,0,1)
                }};
                rootWorld = simd_mul(Tm, simd_mul(Rm, Sm));
            }
        }
        float wmnY = 1e9f, wmxY = -1e9f;
        float bx[2]={mnX,mxX}, by[2]={mnY,mxY}, bz[2]={mnZ,mxZ};
        for (int ci = 0; ci < 8; ++ci) {
            simd_float4 w = simd_mul(rootWorld,
                simd_make_float4(bx[(ci>>0)&1], by[(ci>>1)&1], bz[(ci>>2)&1], 1.0f));
            wmnY = fminf(wmnY, w.y);
            wmxY = fmaxf(wmxY, w.y);
        }
        float worldHeight = wmxY - wmnY;
        out.scale = (worldHeight > 0.001f) ? 2.0f / worldHeight : 1.0f;
    }

    // ─── Skin ─────────────────────────────────────────────────────────────────
    cgltf_skin& skin  = data->skins[0];
    out.jointCount    = (uint32_t)std::min(skin.joints_count, (size_t)kMaxJoints);
    for (uint32_t j = 0; j < out.jointCount; ++j) {
        out.jointNode[j] = (int)(skin.joints[j] - data->nodes);
        if (skin.inverse_bind_matrices) {
            float m16[16];
            cgltf_accessor_read_float(skin.inverse_bind_matrices, j, m16, 16);
            memcpy(&out.invBind[j], m16, 64);
        } else {
            out.invBind[j] = matrix_identity_float4x4;
        }
    }

    // ─── Animations (all clips) ───────────────────────────────────────────────
    for (size_t ai = 0; ai < data->animations_count; ++ai) {
        cgltf_animation& anim = data->animations[ai];
        GltfModel::AnimClip clip;
        clip.name     = anim.name ? anim.name : "";
        clip.duration = 0.0f;

        for (size_t ch = 0; ch < anim.channels_count; ++ch) {
            auto& channel = anim.channels[ch];
            if (!channel.target_node) continue;
            int nIdx = (int)(channel.target_node - data->nodes);
            if (nIdx < 0 || nIdx >= out.nodeCount) continue;
            int prop;
            if      (channel.target_path == cgltf_animation_path_type_translation) prop = 0;
            else if (channel.target_path == cgltf_animation_path_type_rotation   ) prop = 1;
            else if (channel.target_path == cgltf_animation_path_type_scale      ) prop = 2;
            else continue;

            auto& samp = *channel.sampler;
            size_t kfN = samp.input->count;

            GltfModel::Channel c;
            c.nodeIdx = nIdx; c.prop = prop;
            c.times.resize(kfN); c.vals.resize(kfN);
            for (size_t k = 0; k < kfN; ++k) {
                float tv; cgltf_accessor_read_float(samp.input, k, &tv, 1);
                c.times[k] = tv;
                clip.duration = fmaxf(clip.duration, tv);
                float v[4]={0,0,0,(prop==1)?1.0f:0.0f};
                cgltf_accessor_read_float(samp.output, k, v, (prop==1)?4:3);
                c.vals[k] = simd_make_float4(v[0], v[1], v[2], v[3]);
            }
            clip.channels.push_back(std::move(c));
        }
        out.clips.push_back(std::move(clip));
        LOG_INF("Renderer", "  anim[%zu] \"%s\" duration=%.2fs channels=%zu",
                ai, anim.name ? anim.name : "(unnamed)",
                out.clips.back().duration, out.clips.back().channels.size());
    }

    cgltf_free(data);
    out.loaded = true;
    LOG_INF("Renderer", "GLTF loaded: %zu verts, %u idx, %u joints, %zu clips, scale=%.3f",
            vCount, out.indexCount, out.jointCount, out.clips.size(), out.scale);
    return true;
}

// ─── Frame-in-flight triple buffering ────────────────────────────────────────
// Every buffer the CPU rewrites each frame is backed by kFramesInFlight copies.
// The CPU writes/binds the current frame's slot while the GPU may still be
// reading earlier slots, and a counting semaphore (frameSem) bounds how far the
// CPU may run ahead so a slot is never clobbered while still in flight. Without
// this the single shared viewProj buffer was overwritten mid-render, which tore
// geometry whenever the camera moved fast (the matrix changed a lot per frame).
static constexpr NSUInteger kFramesInFlight = 3;

struct FrameRing {
    id<MTLBuffer> slot[kFramesInFlight] = {};
    void alloc(id<MTLDevice> dev, NSUInteger bytes) {
        for (NSUInteger i = 0; i < kFramesInFlight; ++i)
            slot[i] = bytes ? [dev newBufferWithLength:bytes
                                               options:MTLResourceStorageModeShared]
                            : nil;
    }
};

// Ring helpers: allocate all slots and bind the live pointer to the current
// frame's slot. Both assume a local `MetalRendererImpl& d` is in scope.
#define RING_ALLOC(name, bytes) do { d.name##Ring.alloc(d.device, (bytes)); \
                                     d.name = d.name##Ring.slot[d.frameSlot]; } while (0)
#define RING_ADVANCE(name)      do { d.name = d.name##Ring.slot[d.frameSlot]; } while (0)

// ─── Internal implementation struct ──────────────────────────────────────────
struct MetalRendererImpl {
    id<MTLDevice>              device          = nil;
    id<MTLCommandQueue>        commandQueue    = nil;
    id<MTLLibrary>             shaderLibrary   = nil;
    CAMetalLayer*              metalLayer      = nil;

    // ─── Frame-in-flight sync + per-frame buffer rings ───────────────────────
    dispatch_semaphore_t       frameSem        = nullptr;  // bounds CPU run-ahead
    uint32_t                   frameSlot       = 0;        // 0..kFramesInFlight-1
    FrameRing uniformBufRing, skyUniformBufRing, interactBufRing, shellCtrlBufRing,
              longDensityBufRing, grassUnifBufRing, instanceBufRing, propInstBufRing,
              pullInstBufRing, projInstBufRing, shadowInstBufRing,
              explosionInstBufRing, nodeInstBufRing, boneBufRing, charInstBufRing,
              dotInstBufRing, ringInstBufRing, trunkInstBufRing,
              auraVertBufRing, auraIdxBufRing, selRingVertBufRing, selRingIdxBufRing,
              cursorRingVertBufRing, cursorRingIdxBufRing, dbgRingVertBufRing, dbgRingIdxBufRing;

    // Pipelines
    id<MTLRenderPipelineState> psoUnit         = nil;
    id<MTLRenderPipelineState> psoTrunk        = nil;
    id<MTLRenderPipelineState> psoGround       = nil;
    id<MTLRenderPipelineState> psoGrass        = nil;
    id<MTLRenderPipelineState> psoShell        = nil;
    id<MTLBuffer>              grassUnifBuf    = nil; // two GpuGrassUniforms packed
    id<MTLRenderPipelineState> psoProjectile   = nil;
    id<MTLRenderPipelineState> psoDebugLine    = nil;
    id<MTLDepthStencilState>   dssDefault      = nil;
    id<MTLDepthStencilState>   dssNoWrite      = nil;
    id<MTLDepthStencilState>   dssAlways       = nil;  // always pass, no write — used for sky
    id<MTLRenderPipelineState> psoSky          = nil;
    id<MTLBuffer>              skyUniformBuf   = nil;

    // Depth texture
    id<MTLTexture>             depthTexture    = nil;

    // Mesh buffers
    id<MTLBuffer>              unitVertexBuf   = nil;
    id<MTLBuffer>              unitIndexBuf    = nil;
    uint32_t                   unitIndexCount  = 0;

    // Procedural tree trunks (scattered once; placed on terrain each frame).
    id<MTLBuffer>              trunkVertexBuf  = nil;
    id<MTLBuffer>              trunkIndexBuf   = nil;
    uint32_t                   trunkIndexCount = 0;
    id<MTLBuffer>              trunkInstBuf    = nil;
    struct TrunkInst { float x, z; simd_float4x4 model; simd_float3 tint; bool dead; };
    std::vector<TrunkInst>     trunks;
    RenderScene::TreeParams    lastTree {};    // last-scattered params (regen on change)

    id<MTLBuffer>              groundVertexBuf = nil;
    id<MTLBuffer>              groundIndexBuf  = nil;
    uint32_t                   groundIndexCount= 0;
    MTLIndexType               groundIndexType = MTLIndexTypeUInt16;
    id<MTLBuffer>              heightFieldBuf  = nil;  // GPU mirror of Terrain::gHeightField
    float                      terraceStepDrop = 0.0f; // world rise per band (0 = no terraces)

    // Grass interaction field (character footprint push & squish)
    static constexpr int   kIFDivs = 128;
    static constexpr float kIFSize = 90.0f;
    simd_float4            interactField[kIFDivs * kIFDivs] {};  // xy=push vec, z=squish, w=unused
    id<MTLBuffer>          interactBuf    = nil;
    id<MTLBuffer>          shellCtrlBuf   = nil;
    id<MTLBuffer>          longDensityBuf = nil;

    id<MTLBuffer>              sphereVertexBuf = nil;
    id<MTLBuffer>              sphereIndexBuf  = nil;
    uint32_t                   sphereIndexCount= 0;

    // Instance buffer (updated per frame). Units use instanceBuf; props, the
    // pull-node marker and projectiles get dedicated buffers so they don't
    // overwrite each other within a single (uncommitted) command buffer.
    static constexpr int kMaxInstances = 512;
    id<MTLBuffer>              instanceBuf     = nil;
    id<MTLBuffer>              propInstBuf     = nil;
    id<MTLBuffer>              pullInstBuf     = nil;
    id<MTLBuffer>              projInstBuf     = nil;

    // Frame uniforms
    id<MTLBuffer>              uniformBuf      = nil;

    // Timing
    id<MTLCommandBuffer>       lastCmdBuf      = nil;
    float                      lastGPUTimeMs   = 0.0f;
    uint32_t                   drawCallCount   = 0;
    float                      displayScale    = 1.0f;
    uint32_t                   viewportWidth   = 0;
    uint32_t                   viewportHeight  = 0;
    float                      time            = 0.0f;
    id<CAMetalDrawable>        currentDrawable = nil;
    id<MTLCommandBuffer>       currentCmdBuf   = nil;
    MTLRenderPassDescriptor*    currentRPD      = nil;

    // Selection ring line buffer (pre-built circle)
    id<MTLBuffer>              selRingBuf      = nil;
    uint32_t                   selRingVertCount= 0;

    // Cursor ground-indicator disc
    id<MTLBuffer>              discVertexBuf    = nil;
    id<MTLBuffer>              discIndexBuf     = nil;
    uint32_t                   discIndexCount   = 0;
    id<MTLRenderPipelineState> psoCursor        = nil;
    // Separate single-element instance buffer for cursor (never shared with units)
    id<MTLBuffer>              cursorInstBuf    = nil;
    // Per-unit shadow disc instances
    id<MTLBuffer>              shadowInstBuf    = nil;
    // Explosion disc (alpha-blended)
    id<MTLRenderPipelineState> psoExplosion     = nil;
    id<MTLBuffer>              explosionInstBuf = nil;

    // Skinned character (Soldier)
    GltfModel                  soldier;
    id<MTLRenderPipelineState> psoSkinned       = nil;
    id<MTLBuffer>              boneBuf          = nil;  // kMaxShadowDiscs * kMaxJoints bone matrices
    id<MTLBuffer>              charInstBuf      = nil;  // dedicated: avoids overwriting instData
    id<MTLBuffer>              dotInstBuf       = nil;  // dedicated: cooldown indicator spheres
    id<MTLBuffer>              ringInstBuf         = nil;  // dedicated: follow-radius ring segments
    id<MTLRenderPipelineState> psoSelectionRing    = nil;
    id<MTLBuffer>              selRingVertBuf      = nil;
    id<MTLBuffer>              selRingIdxBuf       = nil;
    static constexpr int kSelRingSegs    = 64;
    static constexpr int kSelRingMaxUnits= 32;  // max simultaneously-selected units

    // Cursor rings (3 spinning square-wave rings, built per-frame)
    id<MTLBuffer>              cursorRingVertBuf = nil;
    id<MTLBuffer>              cursorRingIdxBuf  = nil;
    float                      cursorRingAngle[3] = {};
    static constexpr int       kCursorRingSegs   = 64;

    // Light aura discs (soft gradient, drawn before units)
    id<MTLBuffer>              auraVertBuf      = nil;
    id<MTLBuffer>              auraIdxBuf       = nil;
    static constexpr int       kAuraSegs        = 48;
    static constexpr int       kMaxAurasBuf     = 32;

    // Debug radius overlay (dotted yellow rings — toggled with D)
    id<MTLBuffer>              dbgRingVertBuf   = nil;
    id<MTLBuffer>              dbgRingIdxBuf    = nil;
    static constexpr int kDbgRingMaxRings = 512;
    static constexpr int kDbgDotSegs      = 32;  // dots per ring (every other = gaps)
    int         idleClipIdx  = -1;
    int         walkClipIdx  = -1;
    float       charWalkTime[RenderScene::kMaxShadowDiscs]   = {};  // walk clip clock
    float       charIdleTime[RenderScene::kMaxShadowDiscs]   = {};  // idle clip clock (always ticking)
    float       charBlend[RenderScene::kMaxShadowDiscs]      = {};  // 0=walk, 1=idle
    float       charCurrentYaw[RenderScene::kMaxShadowDiscs] = {};  // smoothly interpolated facing angle
    float       charTargetYaw[RenderScene::kMaxShadowDiscs]  = {};  // commanded facing angle
    bool    charYawInited    = false;
    float   lastDt           = 0.0f;

    // ─── Terrain construction editor ──────────────────────────────────────────
    struct TerrainNode { float x, y, z; bool isCorner; bool isAuto; };
    static constexpr int kMaxTerrainNodes = 256;
    static constexpr int kCpDivs          = 40;  // mesh subdivisions per axis

    TerrainNode terrainNodes[kMaxTerrainNodes] {};
    int         terrainNodeCount = 0;
    int         draggingNodeIdx  = -1;
    bool        cpMeshDirty      = true;
    bool        prevAutoNode        = false;  // auto-node toggle state last frame
    float       prevAutoNodeDensity = -1.0f;  // auto-node density last regeneration

    // Smooth-height source for the terracing pipeline: construction nodes (IDW) by default, or
    // procedural fBm noise. worldScale enlarges the live ground plane (procedural preset).
    bool        heightSourceNoise = false;
    float       worldScale        = 1.0f;
    float       noiseFreq         = 0.012f;
    float       noiseAmp          = 14.0f;

    id<MTLRenderPipelineState> psoConstructionPlane = nil;
    id<MTLBuffer>              cpVertexBuf          = nil;
    id<MTLBuffer>              cpIndexBuf           = nil;
    uint32_t                   cpIndexCount         = 0;
    id<MTLBuffer>              nodeInstBuf          = nil;
};

// ─── Tree-trunk scatter ───────────────────────────────────────────────────────
// Jittered grid across the map, deterministic per cell. Precomputes each trunk's
// model matrix (yaw spin · tilt-lean · scale; translation y set per-frame from the
// terrain) and a varied wood tint. Re-run whenever T-panel params change.
static void ScatterTrunks(MetalRendererImpl& d, id<MTLDevice> device,
                          const RenderScene::TreeParams& tp) {
    d.trunks.clear();
    auto hash = [](uint32_t a){ a^=a>>16; a*=0x7feb352dU; a^=a>>15; a*=0x846ca68bU; a^=a>>16; return a; };
    auto rotY = [](float a){ float c=cosf(a), s=sinf(a);
        return (simd_float4x4){{ {c,0,-s,0}, {0,1,0,0}, {s,0,c,0}, {0,0,0,1} }}; };
    auto rotX = [](float a){ float c=cosf(a), s=sinf(a);
        return (simd_float4x4){{ {1,0,0,0}, {0,c,s,0}, {0,-s,c,0}, {0,0,0,1} }}; };

    const float kArea = 84.0f, kCell = 7.0f, kClear = 17.0f;
    const int   n = (int)(kArea * 2.0f / kCell);
    const float deg2rad = 0.01745329f;
    uint32_t seed = 0x1234abcdU;
    for (int gz = 0; gz < n; ++gz)
    for (int gx = 0; gx < n; ++gx) {
        uint32_t h = hash(seed + gx * 73856093U + gz * 19349663U);
        auto rnd = [&](int sh){ return ((h >> sh) & 0xFFFF) / 65535.0f; };
        if (rnd(0) > tp.density) continue;
        float cellX = -kArea + (gx + 0.5f) * kCell, cellZ = -kArea + (gz + 0.5f) * kCell;
        float x = cellX + (rnd(4) - 0.5f) * kCell * 0.85f;
        float z = cellZ + (rnd(8) - 0.5f) * kCell * 0.85f;
        if (fmaxf(fabsf(x), fabsf(z)) < kClear) continue;
        uint32_t h2 = hash(h);
        auto r2 = [&](int sh){ return ((h2 >> sh) & 0xFFFF) / 65535.0f; };
        uint32_t h3 = hash(h2);
        float pullRoll = (h3 & 0xFFFF) / 65535.0f;
        float deadRoll = ((h3 >> 16) & 0xFFFF) / 65535.0f;

        // Mark (don't add) a fraction of trees as dead — own lean bounds, skipped by
        // the future branch/leaf generators.
        bool  dead = deadRoll < tp.deadDensity;
        float lmin = dead ? tp.deadLeanMin : tp.leanMin;
        float lmax = dead ? tp.deadLeanMax : tp.leanMax;

        float spin = rnd(12) * 6.2831853f;
        // Lean direction: bias toward/away from the pull node, else random. Living and
        // dead trees use separate pulls; the magnitude is the likelihood and the sign
        // chooses direction (positive = toward the node, negative = away from it).
        float effPull = dead ? tp.deadPull : tp.pull;
        float az;
        if (tp.pullActive && pullRoll < fabsf(effPull)) {
            az = atan2f(tp.pullX - x, tp.pullZ - z);              // face the pull node
            if (effPull < 0.0f) az += 3.14159265f;               // negative → lean away
        } else {
            az = r2(2) * 6.2831853f;
        }
        float lean   = deg2rad * (lmin + r2(8) * fmaxf(0.f, lmax - lmin));
        float height = tp.heightMin + r2(0) * fmaxf(0.f, tp.heightMax - tp.heightMin);
        float thick  = (0.85f + r2(6) * 0.8f) * tp.thickness;

        simd_float4x4 R = simd_mul(rotY(az), simd_mul(rotX(lean), rotY(spin)));
        simd_float4x4 S = (simd_float4x4){{ {thick,0,0,0}, {0,height,0,0}, {0,0,thick,0}, {0,0,0,1} }};
        simd_float4x4 M = simd_mul(R, S);
        M.columns[3] = simd_make_float4(x, 0, z, 1);

        float var = 0.78f + r2(12) * 0.44f;                       // per-trunk brightness
        // Dead trees share the living wood color — they differ only in lean bounds,
        // pull, and (eventually) being skipped by the branch/leaf generators, not tint.
        simd_float3 col = simd_make_float3(tp.color.x * var, tp.color.y * var, tp.color.z * var);
        MetalRendererImpl::TrunkInst t;
        t.x = x; t.z = z; t.model = M; t.tint = col; t.dead = dead;
        d.trunks.push_back(t);
    }
    RING_ALLOC(trunkInstBuf, d.trunks.empty() ? 0 : d.trunks.size() * sizeof(GpuInstanceData));
    d.lastTree = tp;
}

static bool TreeParamsChanged(const RenderScene::TreeParams& a, const RenderScene::TreeParams& b) {
    return a.density != b.density || a.leanMax != b.leanMax || a.leanMin != b.leanMin ||
           a.heightMin != b.heightMin || a.heightMax != b.heightMax ||
           a.thickness != b.thickness ||
           a.color.x != b.color.x || a.color.y != b.color.y || a.color.z != b.color.z ||
           a.pullActive != b.pullActive || a.pull != b.pull || a.deadPull != b.deadPull ||
           a.pullX != b.pullX || a.pullZ != b.pullZ ||
           a.deadDensity != b.deadDensity ||
           a.deadLeanMin != b.deadLeanMin || a.deadLeanMax != b.deadLeanMax;
}

// ─── Grass uniform block (C++ side — must match GrassUniforms in MSL) ─────────
struct GpuGrassUniforms {
    float        spacing;      // grid spacing between blades
    float        halfExt;      // half grid extent (blades placed in ±halfExt)
    int          bladeVerts;   // 3 = short spike, 15 = long bent blade
    float        bladeHeight;
    float        bladeBend;    // horizontal bend distance
    float        bladeWidth;
    int          sideVerts;    // fin verts per blade (same shape, rotated 90°)
    float        worldScale;   // ground-plane enlargement (procedural preset); 1 = normal
    int          hfDivs;       // active heightfield grid divisions (scales with the plane)
    int          mode;
    int          optMode;
    simd_float3  colorBase;  float _pad2;
    simd_float3  colorTip;   float _pad3;
};

// ─── Terrain editor helpers ────────────────────────────────────────────────────

static float IDWHeight(float x, float z,
                        const MetalRendererImpl::TerrainNode* nodes, int n) {
    if (n == 0) return 0.0f;
    float sumW = 0.0f, sumWY = 0.0f;
    for (int i = 0; i < n; ++i) {
        float dx = x - nodes[i].x, dz = z - nodes[i].z;
        // Power-1 IDW (1/distance): interpolation is linear along the line between two
        // nodes, so paths between nodes stay mostly straight instead of bulging.
        float w  = 1.0f / sqrtf(dx*dx + dz*dz + 0.0001f);
        sumW += w; sumWY += w * nodes[i].y;
    }
    return sumWY / sumW;
}

// ─── Procedural fBm value noise (CPU) — smooth-height source for the procedural preset ──────
static inline float PresetHash(int x, int z) {
    uint32_t h = (uint32_t)(x * 374761393) ^ (uint32_t)(z * 668265263);
    h = (h ^ (h >> 13)) * 1274126177u;
    return (float)((h ^ (h >> 16)) & 0xFFFFFF) / (float)0xFFFFFF;   // [0,1]
}
static float PresetValueNoise(float x, float z) {
    int xi = (int)floorf(x), zi = (int)floorf(z);
    float fx = x - xi, fz = z - zi;
    float u = fx*fx*(3.f-2.f*fx), v = fz*fz*(3.f-2.f*fz);   // smoothstep
    float a = PresetHash(xi,   zi),   b = PresetHash(xi+1, zi);
    float c = PresetHash(xi,   zi+1), e = PresetHash(xi+1, zi+1);
    return (a*(1-u)+b*u)*(1-v) + (c*(1-u)+e*u)*v;            // [0,1]
}
static float PresetFbm(float x, float z) {
    float sum = 0.f, amp = 0.5f, freq = 1.f;
    for (int o = 0; o < 5; ++o) { sum += amp * PresetValueNoise(x*freq, z*freq); freq *= 2.f; amp *= 0.5f; }
    return sum;   // ~[0,1]
}

// Smooth (pre-terrace) height at a world point: construction-node IDW, or procedural fBm noise
// when the procedural preset is active. The terracing pipeline samples this everywhere. The
// noise is sampled at full world-space frequency, so enlarging the plane (which scales the grid
// resolution to keep cell size constant) yields MORE terrain at the same detail.
static float SmoothHeight(MetalRendererImpl& d, float x, float z) {
    if (d.heightSourceNoise)
        return PresetFbm(x*d.noiseFreq + 100.f, z*d.noiseFreq + 100.f) * d.noiseAmp;
    return IDWHeight(x, z, d.terrainNodes, d.terrainNodeCount);
}

// Half-extent of the square construction plane (matches corner nodes and CP mesh).
static constexpr float kConstructionPlaneExt = 80.0f;

// Rebuilds the auto-generated node grid. Removes any previous auto nodes, then — when
// enabled — lays down an interior n×n lattice across the construction plane. Corner and
// manually placed nodes are preserved. Each grid node conforms to the existing terrain
// (Terrain::Height) so the plane snaps onto whatever surface has been generated; when no
// heightfield is active yet it falls back to the construction-plane IDW (corners/manual
// nodes), which is a no-op on the flat default. `density` is the interior nodes per axis.
static void RegenerateAutoNodes(MetalRendererImpl& d, bool enabled, float density) {
    // Drop all existing auto nodes (compact the array, keeping corners + manual nodes).
    int kept = 0;
    for (int i = 0; i < d.terrainNodeCount; ++i)
        if (!d.terrainNodes[i].isAuto) d.terrainNodes[kept++] = d.terrainNodes[i];
    d.terrainNodeCount = kept;
    d.draggingNodeIdx  = -1;  // indices shifted; cancel any in-progress drag

    if (enabled) {
        int n = (int)lroundf(density);
        if (n < 1)  n = 1;
        if (n > 15) n = 15;
        const float ext       = kConstructionPlaneExt;
        const bool  conform   = Terrain::gHeightFieldActive;  // snap to real terrain if present
        const int   baseCount = d.terrainNodeCount;  // pre-grid nodes, for the IDW fallback
        for (int zi = 0; zi < n && d.terrainNodeCount < MetalRendererImpl::kMaxTerrainNodes; ++zi) {
            for (int xi = 0; xi < n && d.terrainNodeCount < MetalRendererImpl::kMaxTerrainNodes; ++xi) {
                float fx = (float)(xi + 1) / (float)(n + 1);  // interior fraction (skip edges)
                float fz = (float)(zi + 1) / (float)(n + 1);
                float x  = -ext + 2.0f * ext * fx;
                float z  = -ext + 2.0f * ext * fz;
                auto& nd     = d.terrainNodes[d.terrainNodeCount++];
                nd.x         = x;
                nd.z         = z;
                nd.y         = conform ? Terrain::Height(x, z)
                                       : IDWHeight(x, z, d.terrainNodes, baseCount);
                nd.isCorner  = false;
                nd.isAuto    = true;
            }
        }
    }
    d.cpMeshDirty = true;
}

static void UpdateCPMesh(MetalRendererImpl& d) {
    constexpr float kExt   = kConstructionPlaneExt;
    constexpr int   kD     = MetalRendererImpl::kCpDivs;
    constexpr float kStep  = kExt * 2.0f / kD;
    constexpr int   stride = kD + 1;
    constexpr int   nVerts = stride * stride;

    std::vector<GpuVertex> verts(nVerts);
    std::vector<uint16_t>  idx;
    idx.reserve(kD * kD * 6);

    for (int zi = 0; zi <= kD; ++zi) {
        for (int xi = 0; xi <= kD; ++xi) {
            float x = -kExt + xi * kStep;
            float z = -kExt + zi * kStep;
            float y = IDWHeight(x, z, d.terrainNodes, d.terrainNodeCount);
            GpuVertex& v = verts[zi * stride + xi];
            v.position = { x, y + 0.08f, z };
            v.normal   = { 0, 1, 0 };
            v.uv       = { (float)xi / kD, (float)zi / kD };
        }
    }
    for (int zi = 0; zi < kD; ++zi) {
        for (int xi = 0; xi < kD; ++xi) {
            auto a  = (uint16_t)(zi * stride + xi);
            auto b  = (uint16_t)(a + 1);
            auto c  = (uint16_t)((zi+1) * stride + xi);
            auto dv = (uint16_t)(c + 1);
            idx.insert(idx.end(), {a, c, b, b, c, dv});
        }
    }
    d.cpIndexCount = (uint32_t)idx.size();

    size_t vSz = nVerts * sizeof(GpuVertex);
    size_t iSz = idx.size() * sizeof(uint16_t);
    if (!d.cpVertexBuf || [d.cpVertexBuf length] < vSz)
        d.cpVertexBuf = [d.device newBufferWithLength:vSz options:MTLResourceStorageModeShared];
    if (!d.cpIndexBuf  || [d.cpIndexBuf  length] < iSz)
        d.cpIndexBuf  = [d.device newBufferWithLength:iSz options:MTLResourceStorageModeShared];
    memcpy([d.cpVertexBuf contents], verts.data(), vSz);
    memcpy([d.cpIndexBuf  contents], idx.data(),   iSz);
    d.cpMeshDirty = false;
}

// Terrace parameters. `step` classifies which band a height falls in (band boundaries sit
// at (k+0.5)*step); `outH` is the world-space rise per band, letting you brute-force a
// specific step-down independent of how finely the plane is sliced. step<=0 → no terracing.
struct TerraceParams { float step; float outH; };
static inline TerraceParams MakeTerraceParams(float step, float height) {
    TerraceParams p;
    p.step = (step  > 0.01f) ? step : 0.0f;
    p.outH = (height > 0.01f) ? height : (p.step > 0.f ? p.step : 1.0f);
    return p;
}
static inline int TerraceBand(float h, float step) { return (int)std::lround(h / step); }

// |∇H| of the smooth height field at (x,z), via central differences.
static inline float IDWGradMag(MetalRendererImpl& d, float x, float z) {
    const float e = 0.5f;
    float dhx = SmoothHeight(d, x+e, z) - SmoothHeight(d, x-e, z);
    float dhz = SmoothHeight(d, x, z+e) - SmoothHeight(d, x, z-e);
    float gx = dhx / (2.f*e), gz = dhz / (2.f*e);
    return std::sqrt(gx*gx + gz*gz);
}

// Maps a smooth height H to its terraced world Y. tanTheta<=0 ⇒ vertical risers (pure
// quantization). Otherwise flat plateaus are joined by ramps inclined at the requested
// angle: the ramp's H-width W scales with the local gradient so the world angle is constant.
static inline float TerraceRemapY(float H, float gMag, TerraceParams p, float tanTheta) {
    if (p.step <= 0.f) return H;
    if (tanTheta <= 0.f) return TerraceBand(H, p.step) * p.outH;     // vertical

    float W = p.outH * gMag / tanTheta;          // ramp width in H units for this angle
    W = fminf(W, p.step * 0.95f);                // keep a sliver of plateau between ramps
    if (W < 1e-4f) return TerraceBand(H, p.step) * p.outH;

    int   b  = TerraceBand(H, p.step);           // nearest plateau (band) index
    float up = (b + 0.5f) * p.step;              // boundary toward band b+1
    float dn = (b - 0.5f) * p.step;              // boundary toward band b-1
    if (up - H < W * 0.5f) return (b     + (H - (up - W*0.5f)) / W) * p.outH;  // ramp up
    if (H - dn < W * 0.5f) return (b - 1 + (H - (dn - W*0.5f)) / W) * p.outH;  // ramp down
    return b * p.outH;                           // flat plateau
}

static inline float AngleTan(float angleDeg) {   // <=0 sentinel ⇒ vertical risers
    if (angleDeg <= 0.f || angleDeg >= 89.f) return -1.f;
    return std::tan(angleDeg * (float)M_PI / 180.f);
}

// Applies the construction plane to the real terrain heightfield. Physics/units read this
// via Terrain::Height (bilinear).
static void GenerateTerracedHeightfield(MetalRendererImpl& d, float step, float height,
                                        float angleDeg) {
    const int   N    = Terrain::gHFDivs;
    const int   strd = N + 1;
    const float size = Terrain::gHFExtent();              // grid spans the (scaled) world
    const float cell = 2.f * size / N;
    TerraceParams p  = MakeTerraceParams(step, height);
    float tanT       = AngleTan(angleDeg);

    for (int zi = 0; zi <= N; ++zi)
        for (int xi = 0; xi <= N; ++xi) {
            float x = -size + xi * cell, z = -size + zi * cell;
            float H = SmoothHeight(d, x, z);
            float g = (tanT > 0.f) ? IDWGradMag(d, x, z) : 0.f;
            Terrain::gHeightField[zi * strd + xi] = TerraceRemapY(H, g, p, tanT);
        }

    Terrain::gHeightFieldActive = true;
}

// Angled-terrace mesh: a standard grid whose vertices use the terrace remap, so plateaus
// stay flat and transitions become real inclined ramps. Used when angle < ~89° (the
// vertical case keeps the marching-squares walls for crisp 90° risers).
static void BuildRampedGroundMesh(MetalRendererImpl& d, float step, float height,
                                  float angleDeg,
                                  std::vector<GpuVertex>& verts,
                                  std::vector<uint32_t>& idx) {
    const float size = Terrain::gHFExtent();
    const int   N    = Terrain::gHFDivs;
    const int   strd = N + 1;
    const float cell = 2.f * size / N;
    TerraceParams p  = MakeTerraceParams(step, height);
    float tanT       = AngleTan(angleDeg);

    verts.resize((size_t)strd * strd);
    auto Y = [&](int xi, int zi) {
        float x = -size + xi * cell, z = -size + zi * cell;
        float H = SmoothHeight(d, x, z);
        float g = (tanT > 0.f) ? IDWGradMag(d, x, z) : 0.f;
        return TerraceRemapY(H, g, p, tanT);
    };
    for (int zi = 0; zi <= N; ++zi)
        for (int xi = 0; xi <= N; ++xi) {
            GpuVertex& v = verts[(size_t)zi * strd + xi];
            v.position = simd_make_float3(-size + xi*cell, Y(xi, zi), -size + zi*cell);
            v.normal   = simd_make_float3(0.f, 1.f, 0.f);
            v.uv       = simd_make_float2((float)xi / N, (float)zi / N);
        }
    for (int zi = 0; zi <= N; ++zi)
        for (int xi = 0; xi <= N; ++xi) {
            int x0 = (xi > 0) ? xi-1 : xi, x1 = (xi < N) ? xi+1 : xi;
            int z0 = (zi > 0) ? zi-1 : zi, z1 = (zi < N) ? zi+1 : zi;
            float hL = verts[(size_t)zi*strd + x0].position.y;
            float hR = verts[(size_t)zi*strd + x1].position.y;
            float hD = verts[(size_t)z0*strd + xi].position.y;
            float hU = verts[(size_t)z1*strd + xi].position.y;
            float dhdx = (hR - hL) / ((float)(x1 - x0) * cell);
            float dhdz = (hU - hD) / ((float)(z1 - z0) * cell);
            verts[(size_t)zi*strd + xi].normal =
                simd_normalize(simd_make_float3(-dhdx, 1.f, -dhdz));
        }
    idx.reserve((size_t)N*N*6);
    for (int zi = 0; zi < N; ++zi)
        for (int xi = 0; xi < N; ++xi) {
            uint32_t a = (uint32_t)(zi * strd + xi), b = a + 1;
            uint32_t c = (uint32_t)((zi+1) * strd + xi), e = c + 1;
            idx.insert(idx.end(), { a, c, b, b, c, e });
        }
}


// Builds a terraced ground mesh whose terrace edges follow the true iso-contours of the
// construction plane (marching-squares per cell), instead of snapping to axis-aligned cell
// boundaries. Each band region is a flat polygon; risers are vertical quads along the
// interpolated contour line. Strictly flat-or-vertical. 32-bit indices.
static void BuildTerracedGroundMesh(MetalRendererImpl& d, float step, float height,
                                    std::vector<GpuVertex>& verts,
                                    std::vector<uint32_t>& idx) {
    const float size = Terrain::gHFExtent();
    const int   N    = Terrain::gHFDivs;
    const float cell = 2.f * size / N;
    TerraceParams p  = MakeTerraceParams(step, height);
    auto wx = [&](int i){ return -size + cell * i; };

    verts.reserve((size_t)N*N*6 + 8192);
    idx.reserve((size_t)N*N*9 + 16384);

    struct PV { float x, z, h; };

    // Precompute the corner-height grid once (shared by the band math and the emit loop).
    const int stride = N + 1;
    std::vector<float> Hgrid((size_t)stride * stride);
    for (int zi = 0; zi <= N; ++zi)
        for (int xi = 0; xi <= N; ++xi)
            Hgrid[(size_t)zi*stride + xi] = SmoothHeight(d, wx(xi), wx(zi));

    auto emitFlat = [&](const std::vector<PV>& pg, float y) {
        if (pg.size() < 3) return;
        uint32_t base = (uint32_t)verts.size();
        GpuVertex v; v.normal = simd_make_float3(0.f,1.f,0.f); v.uv = simd_make_float2(0.f,0.f);
        for (const PV& q : pg) { v.position = simd_make_float3(q.x, y, q.z); verts.push_back(v); }
        for (size_t i = 1; i + 1 < pg.size(); ++i)
            idx.insert(idx.end(), { base, (uint32_t)(base+i), (uint32_t)(base+i+1) });
    };
    auto addQuad = [&](simd_float3 a, simd_float3 b2, simd_float3 c2, simd_float3 d2,
                       simd_float3 nrm) {
        uint32_t b = (uint32_t)verts.size();
        GpuVertex v; v.normal = nrm; v.uv = simd_make_float2(0.f,0.f);
        v.position = a;  verts.push_back(v);
        v.position = b2; verts.push_back(v);
        v.position = c2; verts.push_back(v);
        v.position = d2; verts.push_back(v);
        idx.insert(idx.end(), { b, b+1, b+2, b, b+2, b+3 });
    };
    auto wallSeg = [&](const PV& a, const PV& b2, float yLo, float yHi) {
        float dx = b2.x - a.x, dz = b2.z - a.z, len = std::sqrt(dx*dx + dz*dz);
        simd_float3 nrm = (len > 1e-6f) ? simd_make_float3(dz/len, 0.f, -dx/len)
                                        : simd_make_float3(0.f, 0.f, 1.f);
        addQuad(simd_make_float3(a.x, yLo, a.z),  simd_make_float3(b2.x, yLo, b2.z),
                simd_make_float3(b2.x, yHi, b2.z), simd_make_float3(a.x, yHi, a.z), nrm);
    };
    // Sutherland-Hodgman clip of convex polygon `in` against the iso-line h==L.
    // Keeps the below (or above) half; records the two contour crossing points.
    auto clip = [&](const std::vector<PV>& in, float L, bool below,
                    std::vector<PV>& out, std::vector<PV>& cross) {
        out.clear();
        int n = (int)in.size();
        for (int i = 0; i < n; ++i) {
            const PV& A = in[i];
            const PV& B = in[(i+1) % n];
            bool Ain = below ? (A.h <= L) : (A.h >= L);
            bool Bin = below ? (B.h <= L) : (B.h >= L);
            if (Ain) out.push_back(A);
            if (Ain != Bin) {
                float t = (L - A.h) / (B.h - A.h);
                PV c { A.x + (B.x - A.x) * t, A.z + (B.z - A.z) * t, L };
                out.push_back(c);
                cross.push_back(c);
            }
        }
    };

    std::vector<PV> poly, lo, hi, cross;
    poly.reserve(8); lo.reserve(8); hi.reserve(8); cross.reserve(4);

    for (int cj = 0; cj < N; ++cj) {
        for (int ci = 0; ci < N; ++ci) {
            float x0 = wx(ci), x1 = wx(ci+1), z0 = wx(cj), z1 = wx(cj+1);
            float h0 = Hgrid[(size_t)cj*stride+ci],       h1 = Hgrid[(size_t)cj*stride+ci+1];
            float h2 = Hgrid[(size_t)(cj+1)*stride+ci+1], h3 = Hgrid[(size_t)(cj+1)*stride+ci];

            if (p.step <= 0.f) {                          // terracing off → smooth quad
                addQuad(simd_make_float3(x0,h0,z0), simd_make_float3(x1,h1,z0),
                        simd_make_float3(x1,h2,z1), simd_make_float3(x0,h3,z1),
                        simd_make_float3(0.f,1.f,0.f));
                continue;
            }

            int bmin = TerraceBand(fminf(fminf(h0,h1), fminf(h2,h3)), p.step);
            int bmax = TerraceBand(fmaxf(fmaxf(h0,h1), fmaxf(h2,h3)), p.step);

            poly = { {x0,z0,h0}, {x1,z0,h1}, {x1,z1,h2}, {x0,z1,h3} };
            for (int b = bmin; b < bmax; ++b) {
                float L = (b + 0.5f) * p.step;
                cross.clear();
                clip(poly, L, true,  lo, cross);          // band b region
                emitFlat(lo, b * p.outH);
                for (size_t k = 0; k + 1 < cross.size(); k += 2)
                    wallSeg(cross[k], cross[k+1], b * p.outH, (b + 1) * p.outH);
                clip(poly, L, false, hi, cross);          // remainder (band > b)
                poly.swap(hi);
            }
            emitFlat(poly, bmax * p.outH);                // topmost band

            // Clean rectangular skirts down to 0 at the map borders.
            float ym = TerraceBand(SmoothHeight(d, (x0+x1)*0.5f, (z0+z1)*0.5f), p.step) * p.outH;
            PV a, e;
            if (ci == 0      && ym != 0.f) { a={x0,z0,0}; e={x0,z1,0}; wallSeg(a,e,0.f,ym); }
            if (ci == N-1    && ym != 0.f) { a={x1,z0,0}; e={x1,z1,0}; wallSeg(a,e,0.f,ym); }
            if (cj == 0      && ym != 0.f) { a={x0,z0,0}; e={x1,z0,0}; wallSeg(a,e,0.f,ym); }
            if (cj == N-1    && ym != 0.f) { a={x0,z1,0}; e={x1,z1,0}; wallSeg(a,e,0.f,ym); }
        }
    }
}


// Bakes the construction plane into the terrain heightfield and rebuilds the ground mesh
// (crisp walls when vertical, ramps otherwise). Used by the GENERATE button.
static void GenerateTerrainMesh(MetalRendererImpl& d, float step, float height, float angle) {
    // Scale the grid divisions with the plane so cell size (terrace sharpness, grass detail)
    // stays ~constant; clamp to the heightfield's capacity.
    Terrain::gWorldScale = d.worldScale;
    int divs = (int)lroundf(Terrain::kHFBaseDivs * d.worldScale);
    Terrain::gHFDivs = (divs < Terrain::kHFBaseDivs) ? Terrain::kHFBaseDivs
                     : (divs > Terrain::kHFMaxDivs)  ? Terrain::kHFMaxDivs : divs;
    GenerateTerracedHeightfield(d, step, height, angle);                 // physics heightfield
    std::vector<GpuVertex> gv; std::vector<uint32_t> gi;
    bool vertical = (angle <= 0.f || angle >= 89.f);
    if (vertical) BuildTerracedGroundMesh(d, step, height, gv, gi);      // crisp 90° walls
    else          BuildRampedGroundMesh(d, step, height, angle, gv, gi); // inclined ramps

    d.groundVertexBuf = [d.device newBufferWithBytes:gv.data()
                                              length:gv.size() * sizeof(GpuVertex)
                                             options:MTLResourceStorageModeShared];
    d.groundIndexBuf  = [d.device newBufferWithBytes:gi.data()
                                              length:gi.size() * sizeof(uint32_t)
                                             options:MTLResourceStorageModeShared];
    d.groundIndexCount = (uint32_t)gi.size();
    d.groundIndexType  = MTLIndexTypeUInt32;

    if (d.heightFieldBuf)
        memcpy([d.heightFieldBuf contents], Terrain::gHeightField, sizeof(Terrain::gHeightField));
}

// Applies terrain preset `idx`: 0 Flat, 1 Hill, 2 Bowl, 3 Ridge, 4 Dunes, 5 Procedural.
// All presets run the same terracing pipeline (GenerateTerrainMesh); node presets set the
// construction nodes, procedural switches the height source to fBm noise and enlarges the
// live ground plane by `scale`.
static void ApplyTerrainPreset(MetalRendererImpl& d, int idx, float step, float height,
                               float angle, float scale) {
    if (idx == 5) {                                   // Procedural — terraced noise, scalable
        d.heightSourceNoise = true;
        d.worldScale        = fmaxf(scale, 0.1f);
        d.draggingNodeIdx   = -1;
        d.cpMeshDirty       = true;
        GenerateTerrainMesh(d, step, height, angle);
        return;
    }
    d.heightSourceNoise = false;
    d.worldScale        = 1.0f;

    const float E = kConstructionPlaneExt;
    auto setCorners = [&](float h){
        d.terrainNodes[0] = { -E, h, -E, true, false };
        d.terrainNodes[1] = {  E, h, -E, true, false };
        d.terrainNodes[2] = { -E, h,  E, true, false };
        d.terrainNodes[3] = {  E, h,  E, true, false };
        d.terrainNodeCount = 4;
    };
    auto addNode = [&](float x, float z, float y){
        if (d.terrainNodeCount < MetalRendererImpl::kMaxTerrainNodes)
            d.terrainNodes[d.terrainNodeCount++] = { x, y, z, false, false };
    };
    switch (idx) {
        case 1: setCorners(0.f);  addNode(0,0,14);                                   break;  // Hill
        case 2: setCorners(14.f); addNode(0,0,0);                                    break;  // Bowl
        case 3: setCorners(0.f);  addNode(0,-45,9); addNode(0,0,13); addNode(0,45,9);break;  // Ridge
        case 4: setCorners(0.f);  addNode(-45,-45,10); addNode(50,40,9);
                                  addNode(-40,50,6);   addNode(45,-45,7); addNode(0,0,4); break; // Dunes
        default: setCorners(0.f);                                                    break;  // Flat
    }
    d.draggingNodeIdx = -1;
    d.cpMeshDirty = true;
    GenerateTerrainMesh(d, step, height, angle);
}

// ─── MetalRenderer implementation ─────────────────────────────────────────────
MetalRenderer::MetalRenderer() : m_impl(std::make_unique<MetalRendererImpl>()) {}
MetalRenderer::~MetalRenderer() { Shutdown(); }

bool MetalRenderer::Init(void* nativeWindowHandle, u32 widthPx, u32 heightPx) {
    auto& d = *m_impl;

    d.device = MTLCreateSystemDefaultDevice();
    if (!d.device) {
        LOG_ERR("Renderer", "No Metal device found");
        return false;
    }
    LOG_INF("Renderer", "Metal device: %s", [d.device.name UTF8String]);

    d.commandQueue = [d.device newCommandQueue];

    // Attach to CAMetalLayer
    d.metalLayer = (__bridge CAMetalLayer*)nativeWindowHandle;
    d.metalLayer.device            = d.device;
    d.metalLayer.pixelFormat       = MTLPixelFormatBGRA8Unorm_sRGB;
    d.metalLayer.framebufferOnly   = YES;
    d.metalLayer.displaySyncEnabled= YES;
    d.viewportWidth  = widthPx;
    d.viewportHeight = heightPx;

    // ─── Build inline shader source ────────────────────────────────────────
    NSString* shaderSrc = @R"MSL(
#include <metal_stdlib>
using namespace metal;

struct VertIn {
    float3 position [[attribute(0)]];
    float3 normal   [[attribute(1)]];
    float2 uv       [[attribute(2)]];
};

struct VertOut {
    float4 position [[position]];
    float3 worldPos;
    float3 normal;
    float2 uv;
    float3 tint;
    float  selected;
    float  shellHeight;  // shell layer height; only written by shellVS, read by shellFS
};

struct FrameUniforms {
    float4x4 viewProj;
    float3   cameraPos;
    float    time;
    float3   lightDir;
    float    _p0;
    float3   lightColor;
    float    _p1;
    float3   ambientColor;
    float    _p2;
    float4   auraData[8]; // xy = XZ center, z = radius, w = unused
    int      auraCount;
};

struct InstanceData {
    float4x4 model;
    float3   tint;
    float    selected;
};

// ─── Unit / Prop instanced vertex shader ─────────────────────────────────────
vertex VertOut unitVS(VertIn in [[stage_in]],
                      constant FrameUniforms& u [[buffer(1)]],
                      constant InstanceData*  inst [[buffer(2)]],
                      uint iid [[instance_id]])
{
    float4x4 model = inst[iid].model;
    float4 worldPos4 = model * float4(in.position, 1.0);
    float3 normal    = normalize((model * float4(in.normal, 0.0)).xyz);

    VertOut out;
    out.position    = u.viewProj * worldPos4;
    out.worldPos    = worldPos4.xyz;
    out.normal      = normal;
    out.uv          = in.uv;
    out.tint        = inst[iid].tint;
    out.selected    = inst[iid].selected;
    out.shellHeight = 0.0;
    return out;
}

// ─── Stylized-PBR fragment ────────────────────────────────────────────────────
fragment float4 unitFS(VertOut in [[stage_in]],
                       constant FrameUniforms& u [[buffer(1)]])
{
    // Negative selected = enemy fade alpha (packed by CPU); positive = selection flag.
    float alpha = in.selected < 0.0 ? -in.selected : 1.0;

    float NdotL = saturate(dot(in.normal, -normalize(u.lightDir)));
    // Toon-stepped diffuse for stylized look
    float diffuse = NdotL > 0.6 ? 1.0 : (NdotL > 0.3 ? 0.6 : 0.3);
    float3 color  = in.tint * (u.ambientColor + u.lightColor * diffuse);
    // Selection rim glow (only for positive selected)
    if (in.selected > 0.5) {
        float rim = 1.0 - saturate(dot(normalize(u.cameraPos - in.worldPos), in.normal));
        color += float3(1.0, 0.9, 0.2) * pow(rim, 3.0) * 0.8;
    }
    // Fog-of-war darkness outside friendly auras
    float auraBright = 0.0;
    for (int i = 0; i < u.auraCount; ++i) {
        float2 ac = u.auraData[i].xy;
        float  ar = u.auraData[i].z;
        float  d  = length(float2(in.worldPos.x, in.worldPos.z) - ac) / ar;
        auraBright = max(auraBright, 1.0 - d);
    }
    color *= mix(0.18, 1.0, smoothstep(0.0, 0.2, auraBright));
    return float4(color, alpha);
}

// ─── Procedural noise helpers (used by ground shader) ─────────────────────────

// Low-quality but cheap hash: float2 → [0,1)
static float ghash(float2 p) {
    p = fract(p * float2(127.1f, 311.7f));
    p += dot(p, p + 19.19f);
    return fract(p.x * p.y);
}

// Integer-based hash for cell IDs — no periodic repetition over the terrain scale.
// Takes a float2 whose components are integer-valued (floor'd cell coordinates).
static float shash(float2 p) {
    int2 q = int2(p);
    uint x = uint(q.x) * 1664525u  + 1013904223u;
    uint y = uint(q.y) * 1664525u  + 1013904223u;
    x ^= y;
    x *= 0xbf324c81u;
    x ^= x >> 16u;
    x *= 0x45d9f3bu;
    x ^= x >> 16u;
    return float(x) * (1.0f / 4294967295.0f);
}

// Smooth value noise over a 2D grid
static float gnoise(float2 p) {
    float2 i = floor(p), f = fract(p);
    float2 u = f * f * (3.0f - 2.0f * f);
    float a = ghash(i),              b = ghash(i + float2(1,0));
    float c = ghash(i + float2(0,1)),d = ghash(i + float2(1,1));
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// 4-octave fBm
static float gfbm(float2 p) {
    float v = 0.0f, a = 0.5f;
    for (int i = 0; i < 4; ++i) { v += gnoise(p) * a; p *= 2.1f; a *= 0.5f; }
    return v;  // range roughly [0, 1)
}

// ─── Procedural bark fragment (tree trunks) ──────────────────────────────────
// Layers vertical fibre grain + plate cracks over the solid wood tint, then the
// same toon-diffuse + aura lighting as unitFS.
fragment float4 trunkFS(VertOut in [[stage_in]],
                        constant FrameUniforms& u [[buffer(1)]])
{
    float ang = in.uv.x;          // around the trunk (0..1)
    float h   = in.worldPos.y;    // world height

    float wob   = (gnoise(float2(ang * 18.0, h * 0.15)) - 0.5) * 0.06;
    float strip = ang + wob;                                  // wobbling grain axis
    float fibre = gfbm(float2(strip * 40.0, h * 0.6));        // vertical streaks
    float fine  = gnoise(float2(strip * 130.0, h * 3.0));     // fine grain

    float plate = fract(strip * 16.0 + 0.1 * sin(h * 0.7));
    float crack = 1.0 - smoothstep(0.0, 0.10, abs(plate - 0.5));
    crack *= smoothstep(0.2, 0.6, gnoise(float2(strip * 9.0, h * 0.4)));

    float bark  = 0.78 + 0.34 * fibre - 0.18 * (1.0 - fine);
    bark *= (1.0 - 0.55 * crack);                             // darken in cracks
    float3 base = in.tint * clamp(bark, 0.30, 1.20);

    float NdotL   = saturate(dot(in.normal, -normalize(u.lightDir)));
    float diffuse = NdotL > 0.6 ? 1.0 : (NdotL > 0.3 ? 0.6 : 0.3);
    float3 color  = base * (u.ambientColor + u.lightColor * diffuse);
    float auraBright = 0.0;
    for (int i = 0; i < u.auraCount; ++i) {
        float2 ac = u.auraData[i].xy; float ar = u.auraData[i].z;
        float d = length(float2(in.worldPos.x, in.worldPos.z) - ac) / ar;
        auraBright = max(auraBright, 1.0 - d);
    }
    color *= mix(0.18, 1.0, smoothstep(0.0, 0.2, auraBright));
    return float4(color, 1.0);
}

// Voronoi: returns (min-distance, cell-random-value)
static float2 gvoronoi(float2 p) {
    float2 i = floor(p);
    float  minD = 9.0f;
    float2 minCell;
    for (int dx = -1; dx <= 1; ++dx) {
        for (int dz = -1; dz <= 1; ++dz) {
            float2 cell = i + float2(dx, dz);
            float2 pt   = cell + 0.5f + (float2(ghash(cell + 0.1f),
                                                 ghash(cell + 0.2f)) - 0.5f) * 0.8f;
            float  d    = length(p - pt);
            if (d < minD) { minD = d; minCell = cell; }
        }
    }
    return float2(minD, ghash(minCell + 7.3f));
}

// ─── Ground vertex / fragment ─────────────────────────────────────────────────
vertex VertOut groundVS(VertIn in [[stage_in]],
                        constant FrameUniforms& u [[buffer(1)]])
{
    VertOut out;
    out.position    = u.viewProj * float4(in.position, 1.0);
    out.worldPos    = in.position;
    out.normal      = in.normal;
    out.uv          = in.uv;
    out.tint        = float3(1.0);
    out.selected    = 0.0;
    out.shellHeight = 0.0;
    return out;
}

fragment float4 groundFS(VertOut      in          [[stage_in]],
                         constant FrameUniforms& u  [[buffer(1)]],
                         constant float2&        terraceNoise [[buffer(2)]])
{
    float2 wp = float2(in.worldPos.x, in.worldPos.z);

    // ── Layered soil colour ──────────────────────────────────────────────────
    // Large patches of darker / lighter earth
    float macroNoise = gfbm(wp * 0.08f + float2(3.1f, 7.4f));
    // Mid-scale grain
    float midNoise   = gfbm(wp * 0.35f + float2(1.7f, 5.2f));
    // Fine surface grit
    float microNoise = gnoise(wp * 1.8f + float2(9.3f, 2.6f));

    float soilT = macroNoise * 0.55f + midNoise * 0.30f + microNoise * 0.15f;

    float3 darkBrown  = float3(0.02f, 0.008f, 0.004f);
    float3 midBrown   = float3(0.05f, 0.028f, 0.010f);
    float3 lightBrown = float3(0.088f, 0.042f, 0.012f);

    float3 baseCol = mix(darkBrown,  midBrown,   smoothstep(0.25f, 0.60f, soilT));
           baseCol = mix(baseCol,    lightBrown, smoothstep(0.58f, 0.85f, soilT) * 0.55f);

    // ── Scattered rocks (Voronoi) ────────────────────────────────────────────
    float2 voro     = gvoronoi(wp * 1.6f);
    float  rockDist = voro.x;   // distance to nearest cell centre
    float  cellRnd  = voro.y;   // per-cell random: presence + colour jitter

    // Rocks present in ~10 % of cells
    float rockHere  = step(0.90f, cellRnd);
    float rockMask  = (1.0f - smoothstep(0.018f, 0.055f, rockDist)) * rockHere;

    // Rock colour: grey-brown, varied per cell
    float3 rockCol  = float3(0.21f + cellRnd * 0.10f,
                             0.17f + cellRnd * 0.07f,
                             0.13f + cellRnd * 0.04f);

    float3 color    = mix(baseCol, rockCol, rockMask);

    // Soft contact shadow at rock edges
    color *= mix(0.72f, 1.0f, smoothstep(0.0f, 0.035f, rockDist));

    // ── Terrace-face roughness ───────────────────────────────────────────────
    // Only applied where normal.y < ~0.9 (the near-vertical step risers).
    float3 N = in.normal;
    float faceMask = (1.0f - smoothstep(0.70f, 0.90f, N.y)) * terraceNoise.x;
    if (faceMask > 0.001f) {
        float2 uv0 = float2(in.worldPos.x + in.worldPos.y * 0.3f,
                            in.worldPos.z + in.worldPos.y * 0.3f) * terraceNoise.y;
        float pertX  = gfbm(uv0)                          * 2.0f - 1.0f;
        float pertZ  = gfbm(uv0 + float2(17.3f, 31.7f))  * 2.0f - 1.0f;
        float cavity = gfbm(uv0 + float2( 5.1f,  9.3f));
        N = normalize(N + float3(pertX, 0.0f, pertZ) * faceMask);
        color *= 1.0f - cavity * faceMask * 0.40f;  // darken crevices
    }

    // ── Directional lighting ─────────────────────────────────────────────────
    float NdotL = saturate(dot(N, -normalize(u.lightDir)));
    color *= u.ambientColor + u.lightColor * (NdotL * 0.5f + 0.5f);

    // ── Wet-ground gloss (dark areas only) ───────────────────────────────────
    // Blinn-Phong specular, tight highlight (shininess 96) to simulate standing water
    float3 viewDir  = normalize(u.cameraPos - in.worldPos);
    float3 halfVec  = normalize(-normalize(u.lightDir) + viewDir);
    float  spec     = pow(saturate(dot(N, halfVec)), 96.0f);
    // Gloss fades to zero as soil lightens toward midBrown
    float  glossMask = 1.0f - smoothstep(0.20f, 0.50f, soilT);
    // Slightly cool-white sheen (like sky reflected in wet mud)
    color += float3(0.55f, 0.58f, 0.65f) * spec * glossMask * 1.25f;


    // ── Fog-of-war darkness outside friendly auras ───────────────────────────
    float auraBright = 0.0f;
    for (int i = 0; i < u.auraCount; ++i) {
        float2 ac = u.auraData[i].xy;
        float  ar = u.auraData[i].z;
        float  d  = length(wp - ac) / ar;
        auraBright = max(auraBright, 1.0f - d);
    }
    color *= mix(0.18f, 1.0f, smoothstep(0.0f, 0.2f, auraBright));

    return float4(color, 1.0f);
}

// ─── Construction plane (translucent yellow grid) ─────────────────────────────
fragment float4 constructionPlaneFS(VertOut in [[stage_in]],
                                    constant FrameUniforms& u [[buffer(1)]])
{
    float2 gridPos = float2(in.worldPos.x, in.worldPos.z);
    float2 grid    = fract(gridPos * 0.2f);  // grid line every 5 world units
    float2 edge    = min(grid, 1.0f - grid);
    float  line    = min(edge.x, edge.y);
    float  gridAlpha = 1.0f - smoothstep(0.02f, 0.07f, line);

    float3 col  = float3(0.95f, 0.82f, 0.08f);
    float alpha = mix(0.10f, 0.70f, gridAlpha);
    return float4(col, alpha);
}

// ─── Debug line vertex / fragment ────────────────────────────────────────────
struct LineVert {
    float3 position [[attribute(0)]];
    float3 color    [[attribute(1)]];
};
struct LineOut {
    float4 position [[position]];
    float3 color;
};
vertex LineOut debugLineVS(LineVert in [[stage_in]],
                           constant FrameUniforms& u [[buffer(1)]])
{
    LineOut out;
    out.position = u.viewProj * float4(in.position, 1.0);
    out.color    = in.color;
    return out;
}
fragment float4 debugLineFS(LineOut in [[stage_in]])
{
    return float4(in.color, 1.0);
}

// ─── Flat unlit (cursor ground indicator) ────────────────────────────────────
vertex VertOut flatVS(VertIn in [[stage_in]],
                      constant FrameUniforms& u [[buffer(1)]],
                      constant InstanceData*  inst [[buffer(2)]],
                      uint iid [[instance_id]])
{
    float4 worldPos4 = inst[iid].model * float4(in.position, 1.0);
    VertOut out;
    out.position    = u.viewProj * worldPos4;
    out.worldPos    = worldPos4.xyz;
    out.normal      = float3(0, 1, 0);
    out.uv          = in.uv;
    out.tint        = inst[iid].tint;
    out.selected    = 0.0;
    out.shellHeight = 0.0;
    return out;
}
fragment float4 flatFS(VertOut in [[stage_in]])
{
    return float4(in.tint, 1.0);
}

// ─── Skinned character vertex shader ─────────────────────────────────────────
struct SkinnedVert {
    float3  position [[attribute(0)]];
    float3  normal   [[attribute(1)]];
    float2  uv       [[attribute(2)]];
    ushort4 joints   [[attribute(3)]];
    float4  weights  [[attribute(4)]];
};

// bones buffer: kMaxShadowDiscs * 64 matrices, indexed [iid * 64 + jointIndex]
vertex VertOut skinnedVS(SkinnedVert     in   [[stage_in]],
                         constant FrameUniforms& u    [[buffer(1)]],
                         constant InstanceData*  inst [[buffer(2)]],
                         constant float4x4*      bones[[buffer(3)]],
                         uint iid [[instance_id]])
{
    uint base = iid * 64u;
    float4x4 skin = in.weights.x * bones[base + in.joints.x]
                  + in.weights.y * bones[base + in.joints.y]
                  + in.weights.z * bones[base + in.joints.z]
                  + in.weights.w * bones[base + in.joints.w];

    float4x4 model  = inst[iid].model;
    float4 worldPos4 = model * (skin * float4(in.position, 1.0));
    float3 normal    = normalize((model * (skin * float4(in.normal, 0.0))).xyz);

    VertOut out;
    out.position    = u.viewProj * worldPos4;
    out.worldPos    = worldPos4.xyz;
    out.normal      = normal;
    out.uv          = in.uv;
    out.tint        = inst[iid].tint;
    out.selected    = inst[iid].selected;
    out.shellHeight = 0.0;
    return out;
}

// ─── Explosion disc (alpha-blended; selected carries alpha) ──────────────────
vertex VertOut explosionVS(VertIn in [[stage_in]],
                           constant FrameUniforms& u [[buffer(1)]],
                           constant InstanceData*  inst [[buffer(2)]],
                           uint iid [[instance_id]])
{
    float4 worldPos4 = inst[iid].model * float4(in.position, 1.0);
    VertOut out;
    out.position    = u.viewProj * worldPos4;
    out.worldPos    = worldPos4.xyz;
    out.normal      = float3(0, 1, 0);
    out.uv          = in.uv;
    out.tint        = inst[iid].tint;
    out.selected    = inst[iid].selected;
    out.shellHeight = 0.0;
    return out;
}
fragment float4 explosionFS(VertOut in [[stage_in]])
{
    return float4(in.tint, in.selected);
}

// ─── Selection ring (alpha-blended wavy rings, vertex-colored) ───────────────
struct RingVIn {
    float3 position [[attribute(0)]];
    float4 color    [[attribute(1)]];
};
struct RingVOut {
    float4 position [[position]];
    float4 color;
};
vertex RingVOut selectionRingVS(RingVIn in [[stage_in]],
                                constant FrameUniforms& u [[buffer(1)]])
{
    RingVOut out;
    out.position = u.viewProj * float4(in.position, 1.0);
    out.color    = in.color;
    return out;
}
fragment float4 selectionRingFS(RingVOut in [[stage_in]])
{
    return in.color;
}

// ─── Grass ────────────────────────────────────────────────────────────────────

// Bilinearly samples the terrain heightfield mirror. The grid divisions (divs) and half-extent
// scale with the enlarged plane, so they're passed in (not constant).
constant float kGrHFSize = 90.0f;   // base half-extent (×worldScale gives the active extent)
static float grTerrH(float x, float z, device const float* hf, float worldScale, int divs) {
    float ext   = kGrHFSize * worldScale;
    int   strd  = divs + 1;
    float fx = clamp((x + ext) / (2.0f*ext) * float(divs), 0.0f, float(divs));
    float fz = clamp((z + ext) / (2.0f*ext) * float(divs), 0.0f, float(divs));
    int   x0 = int(fx), z0 = int(fz);
    int   x1 = min(x0+1, divs), z1 = min(z0+1, divs);
    float tx = fx - float(x0), tz = fz - float(z0);
    float h00 = hf[z0*strd + x0], h10 = hf[z0*strd + x1];
    float h01 = hf[z1*strd + x0], h11 = hf[z1*strd + x1];
    return mix(mix(h00, h10, tx), mix(h01, h11, tx), tz);
}

// Bilinearly samples the character interaction field (128×128 over ±90).
// xy = push vector (direction × strength 0..1), z = squish (0..1)
constant int   kGFDivs = 128;
constant float kGFSize = 90.0f;
static float4 grInteract(float x, float z, device const float4* gf) {
    float fx = clamp((x + kGFSize) / (2.0f * kGFSize) * float(kGFDivs), 0.0f, float(kGFDivs - 1));
    float fz = clamp((z + kGFSize) / (2.0f * kGFSize) * float(kGFDivs), 0.0f, float(kGFDivs - 1));
    int x0 = int(fx), z0 = int(fz);
    int x1 = min(x0 + 1, kGFDivs - 1), z1 = min(z0 + 1, kGFDivs - 1);
    float tx = fx - float(x0), tz = fz - float(z0);
    float4 v00 = gf[z0*kGFDivs + x0], v10 = gf[z0*kGFDivs + x1];
    float4 v01 = gf[z1*kGFDivs + x0], v11 = gf[z1*kGFDivs + x1];
    return mix(mix(v00, v10, tx), mix(v01, v11, tx), tz);
}

struct ShellCtrl {
    float3 colorBase;
    float  density;
    float3 colorTip;
    float  _pad;
};

struct GrassUniforms {
    float  spacing;
    float  halfExt;
    int    bladeVerts;
    float  bladeHeight;
    float  bladeBend;
    float  bladeWidth;
    int    sideVerts;
    float  worldScale;   // ground-plane enlargement (procedural preset); 1 = normal
    int    hfDivs;       // active heightfield grid divisions (scales with the plane)
    int    mode;
    int    optMode;
    float3 colorBase; float _pad2;
    float3 colorTip;  float _pad3;
};

struct GrassOut {
    float4 position [[position]];
    float3 color;
    float2 worldXZ;
};

vertex GrassOut grassVS(uint             vid [[vertex_id]],
                        constant FrameUniforms& u [[buffer(1)]],
                        constant GrassUniforms& g [[buffer(2)]],
                        device const float*     hf [[buffer(3)]],
                        constant float&         terraceStepDrop [[buffer(4)]],
                        device const float4*    gf [[buffer(5)]],
                        constant float2&        grassDensityParams [[buffer(6)]])
{
    GrassOut out;

    int bv            = g.bladeVerts;
    int totalPerBlade = bv + g.sideVerts;
    int bladeIdx      = int(vid) / totalPerBlade;
    int cornerIdx     = int(vid) % totalPerBlade;
    bool isFin        = (cornerIdx >= bv);
    int  effCorner    = isFin ? (cornerIdx - bv) : cornerIdx;

    // Grid position — a world-fixed, origin-centred scatter. Positions are objective: they depend
    // only on the blade index and the (frame-constant) spacing/extent, never on the camera, so the
    // grass never shifts or ripples as the view moves. The spacing widens with the plane so the
    // blade count stays constant as the ground is enlarged — grass thins out rather than multiplying.
    int gridW = int(round(2.0f * g.halfExt / g.spacing));
    int ci = bladeIdx % gridW, ri = bladeIdx / gridW;

    float wx0 = float(ci) * g.spacing - g.halfExt + g.spacing * 0.5f;
    float wz0 = float(ri) * g.spacing - g.halfExt + g.spacing * 0.5f;
    float jx = (ghash(float2(float(ci) * 13.7f + 3.1f, float(ri) * 11.3f))        - 0.5f) * g.spacing * 0.9f;
    float jz = (ghash(float2(float(ci) *  9.1f + 7.7f, float(ri) * 17.3f + 1.5f)) - 0.5f) * g.spacing * 0.9f;
    float wx = wx0 + jx, wz = wz0 + jz;

    // Terrain height + normal (finite differences). eps is a fixed world distance (~half a grid
    // cell) — the dynamic grid keeps cell size constant as the plane enlarges, so terrain detail
    // (and hence the sampling distance) does not scale with the plane.
    float ws  = g.worldScale;   // still needed: grTerrH maps world→grid over the scaled extent
    int   hd  = g.hfDivs;
    float eps = 0.4f;
    float hC  = grTerrH(wx, wz, hf, ws, hd);
    float3 norm = normalize(float3(
        grTerrH(wx - eps, wz, hf, ws, hd) - grTerrH(wx + eps, wz, hf, ws, hd),
        2.0f * eps,
        grTerrH(wx, wz - eps, hf, ws, hd) - grTerrH(wx, wz + eps, hf, ws, hd)
    ));

    float slopeDot   = norm.y;
    float eastFacing = max(0.0f, norm.x);

    // Per-blade stable random — keyed off blade index (a fixed world cell), stable across frames.
    float br = ghash(float2(float(bladeIdx) * 7.31f, float(bladeIdx) * 3.73f));
    int mode = g.mode;
    int optMode = g.optMode;
    float distCam = distance(float2(u.cameraPos.x, u.cameraPos.z), float2(wx, wz));
    float chunkHash = shash(floor(float2(wx, wz) / 12.0f));

    // Culling. Risers stay ~1 grid cell wide at any plane scale (constant cell size), so the
    // slope test below catches them without a separate per-blade riser probe.
    bool cull = false;
    if (abs(wx) > g.halfExt || abs(wz) > g.halfExt) cull = true;
    else if (bv == 9) {
        // Short sticks: cover all terrain; only exclude true cliff faces (slopeDot < 0.55)
        if (slopeDot < 0.55f) cull = true;
    } else {
        // Long blades: slope-aware with east-facing bias
        if      (slopeDot < 0.80f) cull = true;
        else if (slopeDot < 0.95f) {
            float prob = eastFacing * 0.75f + br * 0.12f;
            if (prob < 0.40f) cull = true;
        }
    }

    // Downward-step proximity (long blades only). Terrace features are constant world-size under
    // the constant-detail grid, so the grass-free border radii are fixed world distances.
    float edgeT = 0.0f;
    if (!cull && bv == 15) {
        constexpr float kDropThr  = 0.4f;
        float kRadii[3] = { 1.5f, 3.0f, 5.0f };
        float stepDist = 1e9f;
        for (int ri = 0; ri < 3; ++ri) {
            float r   = kRadii[ri];
            bool  hit = false;
            // +X, -X, +Z, -Z
            hit = (grTerrH(wx + r, wz,     hf, ws, hd) <= hC - kDropThr) ||
                  (grTerrH(wx - r, wz,     hf, ws, hd) <= hC - kDropThr) ||
                  (grTerrH(wx,     wz + r, hf, ws, hd) <= hC - kDropThr) ||
                  (grTerrH(wx,     wz - r, hf, ws, hd) <= hC - kDropThr);
            if (hit) { stepDist = r - 0.5f; break; }
        }
        float dN       = clamp(stepDist / 5.0f, 0.0f, 1.0f);
        float edgeDens = clamp(grassDensityParams.y, 0.0f, 1.0f);
        float keepProb = clamp(mix(edgeDens, 0.5f, dN), 0.0f, 1.0f);
        if (br > keepProb) cull = true;
        else edgeT = clamp((4.0f - stepDist) / 3.5f, 0.0f, 1.0f);
    }

    // Density: independent per-blade cull, uncorrelated with appearance randoms.
    // shash used here because ghash's fract(u*v) product distribution is skewed
    // toward 0, making the cull threshold barely fire for density < 0.5.
    if (!cull) {
        float densR = shash(float2(float(bladeIdx), 73.0f));
        float modeDensity = grassDensityParams.x;
        if (mode == 2) modeDensity *= 0.34f;                  // CPU instanced clumps/cards
        else if (mode == 3) modeDensity *= (chunkHash > 0.34f ? 0.85f : 0.04f); // chunks
        else if (mode == 4) modeDensity *= 0.52f;             // alpha cards
        else if (mode == 5) modeDensity *= mix(0.95f, 0.22f, smoothstep(20.0f, 70.0f, distCam));
        else if (mode == 6) modeDensity *= 0.78f;             // wind demo
        else if (mode == 8) modeDensity *= 1.35f;             // GPU generated dense
        else if (mode == 9) modeDensity *= mix(1.0f, 0.18f, smoothstep(18.0f, 62.0f, distCam));
        else if (mode == 10) modeDensity *= 0.20f;            // billboard-only

        if (optMode == 0) modeDensity *= 1.0f - smoothstep(46.0f, 58.0f, distCam);
        else if (optMode == 2) modeDensity *= mix(1.0f, 0.25f, smoothstep(18.0f, 70.0f, distCam));
        else if (optMode == 13) modeDensity *= 0.55f;
        else if (optMode == 22) modeDensity *= 0.72f;

        if (densR >= clamp(modeDensity, 0.0f, 1.0f)) cull = true;
    }

    if (cull) {
        out.position = float4(10, 10, 10, 1);
        out.color    = float3(0);
        out.worldXZ  = float2(wx, wz);
        return out;
    }

    // Per-blade orientation + scale variation
    // Wave-dominated facing: overlapping sine fields produce large coherent swaths
    // of similarly-leaning blades. br adds per-blade jitter inside each wave.
    float waveAngle = sin(wx * 0.055f + wz * 0.038f) * 2.8f
                    + sin(wx * 0.095f - wz * 0.072f) * 1.4f
                    + cos(wx * 0.035f + wz * 0.098f) * 0.9f;
    float facing = waveAngle + br * 1.2f;
    float2 fwd   = float2(cos(facing), sin(facing));
    float2 perp  = float2(-fwd.y, fwd.x);
    float hScale = 0.75f + br * 0.5f;
    float bH = g.bladeHeight * hScale;
    float bB = g.bladeBend   * hScale;
    float bW = g.bladeWidth  * (0.6f + br * 0.8f);
    if (mode == 2) { bH *= 0.62f; bB *= 0.35f; bW *= 2.4f; }       // clump/card patch
    else if (mode == 3) { bH *= 0.82f; bB *= 0.55f; bW *= 1.8f; }  // chunked patches
    else if (mode == 4) { bH *= 0.72f; bB *= 0.22f; bW *= 3.8f; }  // alpha-cutout cards
    else if (mode == 5) { float lod = smoothstep(18.0f, 70.0f, distCam); bH *= mix(1.0f, 0.45f, lod); bW *= mix(1.0f, 2.1f, lod); }
    else if (mode == 6) { bH *= 1.05f; bB *= 1.85f; }
    else if (mode == 8) { bH *= 0.88f; bB *= 0.75f; bW *= 0.75f; }
    else if (mode == 9) { float lod = smoothstep(14.0f, 62.0f, distCam); bH *= mix(1.0f, 0.38f, lod); bW *= mix(0.9f, 2.8f, lod); }
    else if (mode == 10) { bH *= 0.92f; bB *= 0.05f; bW *= 5.2f; }
    if (optMode == 16) bW *= mix(1.0f, 2.0f, smoothstep(20.0f, 64.0f, distCam));

    // ── Grass interaction: footprint squish + lateral push ────────────────────
    float4 interact = grInteract(wx, wz, gf);
    float2 push   = interact.xy;   // world-XZ push vector, magnitude 0..1
    float  squish = interact.z;    // 0 = upright, 1 = fully flat
    bH *= (1.0f - squish * 0.88f);
    bB *= (1.0f - squish * 0.88f);
    float windStrength = (mode == 6) ? 0.55f : 0.12f;
    if (optMode == 8) windStrength *= 1.0f - smoothstep(22.0f, 55.0f, distCam);
    float wind = sin(u.time * (mode == 6 ? 2.2f : 0.7f) + wx * 0.12f + wz * 0.07f + br * 6.28f);
    bB += wind * windStrength * bH;

    // Fin: same shape rotated 90°, narrower — catches viewpoints along the main blade's face
    float2 gfwd  = isFin ? perp        : fwd;
    float2 gperp = isFin ? (-fwd)      : perp;
    float  gW    = isFin ? (bW * 0.4f) : bW;

    float3 vOff;
    float  tParam;

    if (bv == 9) {
        // ── Short stick: thin stem (2 tris) + small hook cap (1 tri) ─────────
        // Stem runs from ground to 76% of bH; hook caps to full bH.
        float thin   = gW * 0.22f;
        float stemH  = bH * 0.76f;
        float hookLen = bH * 0.22f;
        // Unindexed quad: BL,BR,TR | BL,TR,TL  then hook: TL,TR,tip
        float2 hookXZ;
        float  y;
        if      (effCorner == 0) { hookXZ = gperp * (-thin); y = 0.f;    }
        else if (effCorner == 1) { hookXZ = gperp * ( thin); y = 0.f;    }
        else if (effCorner == 2) { hookXZ = gperp * ( thin); y = stemH;  }
        else if (effCorner == 3) { hookXZ = gperp * (-thin); y = 0.f;    }
        else if (effCorner == 4) { hookXZ = gperp * ( thin); y = stemH;  }
        else if (effCorner == 5) { hookXZ = gperp * (-thin); y = stemH;  }
        else if (effCorner == 6) { hookXZ = gperp * (-thin); y = stemH;  }
        else if (effCorner == 7) { hookXZ = gperp * ( thin); y = stemH;  }
        else                     { hookXZ = gfwd   * hookLen; y = bH;    }
        tParam = y / bH;
        vOff   = float3(hookXZ.x, y, hookXZ.y);

    } else if (bv == 15) {
        // ── Long bent blade: 5 triangles (3 rings + tip) ─────────────────────
        const int lvl[15] = {0,0,1, 0,1,1, 1,1,2, 1,2,2, 2,2,3};
        const int sid[15] = {0,1,0, 1,1,0, 0,1,0, 1,1,0, 0,1,0};
        int lv = lvl[effCorner], sd = sid[effCorner];

        const float tAtLv[4] = {0.0f, 0.40f, 0.75f, 1.0f};
        tParam = tAtLv[lv];

        float2 P0 = float2(0,          0);
        float2 P1 = float2(bB * 0.20f, bH * 1.20f);
        float2 P2 = float2(bB,         bH * 0.20f);
        float mt = 1.0f - tParam;
        float2 pt = mt*mt*P0 + 2.0f*mt*tParam*P1 + tParam*tParam*P2;

        float w  = (lv < 3) ? gW * pow(1.0f - tParam, 0.55f) : 0.0f;
        float ss = (sd == 0) ? -1.0f : 1.0f;
        vOff = float3(gfwd.x * pt.x + gperp.x * w * ss,
                      pt.y,
                      gfwd.y * pt.x + gperp.y * w * ss);
    } else {
        vOff = float3(0); tParam = 0.0f;
    }

    float3 worldPos = float3(wx, hC, wz) + vOff;
    // Push: tip follows push direction, base stays rooted (tParam^1.5 weighting)
    float pushScale = pow(tParam, 1.5f) * 2.2f;
    worldPos.x += push.x * pushScale;
    worldPos.z += push.y * pushScale;
    // Long blades: dramatic tip lightening concentrated near tip end
    float tMix = (bv == 15) ? pow(tParam, 0.4f) : tParam;
    float3 col = mix(g.colorBase, g.colorTip, tMix);
    if (mode == 1) col = mix(float3(0.025f, 0.075f, 0.025f), float3(0.10f, 0.18f, 0.065f), br);
    else if (mode == 2) col = mix(float3(0.035f, 0.095f, 0.030f), float3(0.18f, 0.26f, 0.08f), tMix);
    else if (mode == 3) col = mix(float3(0.020f, 0.070f, 0.025f), float3(0.11f, 0.20f, 0.06f), tMix) * (chunkHash > 0.34f ? 1.0f : 0.45f);
    else if (mode == 4) col = mix(float3(0.050f, 0.105f, 0.040f), float3(0.24f, 0.32f, 0.10f), tMix);
    else if (mode == 5) col *= mix(1.06f, 0.62f, smoothstep(24.0f, 76.0f, distCam));
    else if (mode == 6) col = mix(float3(0.025f, 0.085f, 0.035f), float3(0.16f, 0.26f, 0.08f), tMix);
    else if (mode == 8) col = mix(float3(0.018f, 0.075f, 0.028f), float3(0.13f, 0.24f, 0.07f), tMix);
    else if (mode == 9) col = mix(float3(0.028f, 0.085f, 0.030f), float3(0.20f, 0.30f, 0.09f), tMix);
    else if (mode == 10) col = mix(float3(0.025f, 0.070f, 0.026f), float3(0.16f, 0.22f, 0.07f), tMix);
    col += (br - 0.5f) * 0.012f;

    // Tips lighten toward dead/dry straw the closer the blade is to a downward step;
    // blades on/at the edge (edgeT≈1) get fully dead tips. Confined to the upper blade.
    if (edgeT > 0.0f) {
        float3 deadTip = float3(0.42f, 0.36f, 0.15f);
        col = mix(col, deadTip, edgeT * smoothstep(0.25f, 1.0f, tParam));
    }

    out.position = u.viewProj * float4(worldPos, 1.0f);
    out.color    = col;
    out.worldXZ  = float2(wx, wz);
    return out;
}

fragment float4 grassFS(GrassOut         in [[stage_in]],
                        constant FrameUniforms& u [[buffer(1)]])
{
    float3 color = in.color;
    float auraBright = 0.0f;
    for (int i = 0; i < u.auraCount; ++i) {
        float2 ac = u.auraData[i].xy;
        float  ar = u.auraData[i].z;
        float  d  = length(in.worldXZ - ac) / ar;
        auraBright = max(auraBright, 1.0f - d);
    }
    color *= mix(0.18f, 1.0f, smoothstep(0.0f, 0.2f, auraBright));
    return float4(color, 1.0f);
}

// ─── X-Card grass ─────────────────────────────────────────────────────────────
// Two crossed vertical quads per blade position (12 verts).
// Fragment shader discards outside the blade silhouette — zero extra geometry cost.

// ─── Shell grass ──────────────────────────────────────────────────────────────
// The terrain mesh is drawn N times, each shell lifted by shellH.
// Fragment shader checks whether a blade at this XZ reaches this height;
// if not it discards, leaving the shell transparent at that pixel.

// shellParams.x = kShells (float), shellParams.y = kMaxShellH
vertex VertOut shellVS(VertIn                  in  [[stage_in]],
                       uint                    iid [[instance_id]],
                       constant FrameUniforms& u   [[buffer(1)]],
                       constant float2&        shellParams [[buffer(2)]])
{
    float shellH = (float(iid) + 0.5f) / shellParams.x * shellParams.y;
    VertOut out;
    float3 pos = in.position;
    pos.y += shellH;
    out.worldPos    = pos;
    out.normal      = in.normal;
    out.position    = u.viewProj * float4(pos, 1.0f);
    out.shellHeight = shellH;
    return out;
}

fragment float4 shellFS(VertOut                 in   [[stage_in]],
                        constant FrameUniforms& u    [[buffer(1)]],
                        device const float4*    gf   [[buffer(4)]],
                        constant ShellCtrl&     ctrl [[buffer(5)]])
{
    float shellH = in.shellHeight;
    float2 wp = float2(in.worldPos.x, in.worldPos.z);

    // Shell grass only grows on flat tops — discard any fragment on a ramp or step face.
    if (in.normal.y < 0.98f) discard_fragment();
    constexpr float slopeFade = 1.0f;

    const float gScale = 11.0f;
    float2 shellOff = float2(ghash(float2(shellH * 293.7f, 47.3f)),
                             ghash(float2(shellH * 179.1f, 83.7f))) * (2.5f / gScale);
    float2 cellID = floor((wp + shellOff) * gScale);
    float2 cellFr = fract((wp + shellOff) * gScale) - 0.5f;

    // Density: cull a fraction of cells before any blade height test
    if (shash(cellID + float2(31.0f, 37.0f)) >= ctrl.density) discard_fragment();

    float  rnd    = shash(cellID + float2(3.0f,  9.0f));
    float2 jitter = float2(shash(cellID + float2(2.0f,  5.0f)),
                           shash(cellID + float2(8.0f,  1.0f))) - 0.5f;
    float2 center = cellFr - jitter * 0.18f;

    // Sample interaction field: push (xy) shifts the blade center, squish (z) reduces max height
    float4 interact  = grInteract(wp.x, wp.y, gf);
    float2 push      = interact.xy;
    float  squish    = interact.z;

    // Push: shift sample center within the cell away from character (cell-fraction units)
    center += push * 0.48f;

    // rnd drives both blade height and disc radius (Acerola / TOTK-style).
    constexpr float kMaxShellH = 0.14f;
    float vHeight = shellH / kMaxShellH;
    if (vHeight > rnd * slopeFade * (1.0f - squish * 0.88f)) discard_fragment();

    float discRadius = 3.5f * (rnd - vHeight);
    if (length(center) > discRadius) discard_fragment();

    float t = vHeight / rnd;  // 0 at base, 1 at tip

    float colRnd  = shash(cellID + float2(17.0f,  5.0f));
    float colRnd2 = shash(cellID + float2(23.0f, 11.0f));
    float toneVar = 0.78f + shash(cellID + float2(4.0f,  2.0f)) * 0.44f;

    float3 gCol;
    if (colRnd < 0.002f) {                          // ~0.2% special
        if      (colRnd2 < 0.333f) gCol = float3(0.11f, 0.054f, 0.15f);
        else if (colRnd2 < 0.667f) gCol = float3(0.13f, 0.015f, 0.015f);
        else                       gCol = float3(0.021f, 0.090f, 0.165f);
    } else if (colRnd < 0.03f) {                    // ~2.8% dead
        gCol = mix(float3(0.040f,0.026f,0.008f), float3(0.066f,0.045f,0.015f), t) * toneVar;
    } else {                                         // ~97% live
        gCol = mix(ctrl.colorBase, ctrl.colorTip, pow(t, 0.4f)) * toneVar;
    }

    float NdotL = saturate(dot(in.normal, -normalize(u.lightDir)));
    gCol *= u.ambientColor + u.lightColor * (NdotL * 0.5f + 0.5f);

    float auraBright = 0.0f;
    for (int i = 0; i < u.auraCount; ++i) {
        float d = length(wp - u.auraData[i].xy) / u.auraData[i].z;
        auraBright = max(auraBright, 1.0f - d);
    }
    gCol *= mix(0.18f, 1.0f, smoothstep(0.0f, 0.2f, auraBright));
    return float4(gCol, 1.0f);
}

// ─── Procedural sky ──────────────────────────────────────────────────────────

struct SkyUniforms {
    float4x4 invViewProj;
    float3   sunDir;
    float    time;
};

struct SkyVert {
    float4 position [[position]];
    float2 ndc;
};

vertex SkyVert skyVS(uint vid [[vertex_id]]) {
    // Fullscreen triangle covering entire NDC space with 3 vertices
    float2 pos = float2((vid == 1) ? 3.0f : -1.0f,
                        (vid == 2) ? 3.0f : -1.0f);
    SkyVert out;
    out.position = float4(pos, 1.0f, 1.0f);  // depth irrelevant: sky uses always-pass, no-write
    out.ndc = pos;
    return out;
}

fragment float4 skyFS(SkyVert in [[stage_in]],
                      constant SkyUniforms& sky [[buffer(0)]])
{
    // Unproject NDC position to a world-space view ray. Reversed-Z: ndc z=1 is the
    // near plane and z=0 is infinity (w→0, unstable), so step from near to a finite
    // mid-depth (z=0.5) and point the ray outward into the scene.
    float4 wNear = sky.invViewProj * float4(in.ndc, 1.0f, 1.0f);
    float4 wMid  = sky.invViewProj * float4(in.ndc, 0.5f, 1.0f);
    float3 rayDir = normalize(wMid.xyz / wMid.w - wNear.xyz / wNear.w);

    float3 sun = normalize(sky.sunDir);
    float  mu  = dot(rayDir, sun);  // -1..1, 1 = staring at sun

    // ── Base sky gradient (zenith → mid → horizon) ────────────────────────────
    float  elev     = rayDir.y;
    float  skyBlend = saturate(elev * 1.8f + 0.15f);
    float3 zenith   = float3(0.19f, 0.42f, 0.80f);
    float3 midSky   = float3(0.42f, 0.62f, 0.88f);
    float3 skyCol   = mix(midSky, zenith, skyBlend * skyBlend);

    // ── Horizon haze with sun-side warmth ─────────────────────────────────────
    float horzT   = pow(saturate(1.0f - abs(elev) * 3.0f), 2.0f);
    float sunSide = saturate(dot(normalize(float2(rayDir.x, rayDir.z)),
                                  normalize(float2(sun.x, sun.z))) * 0.5f + 0.5f);
    float3 warmHaze = mix(float3(0.62f, 0.70f, 0.80f),
                           float3(0.86f, 0.72f, 0.48f), sunSide);
    skyCol = mix(skyCol, warmHaze, horzT * 0.55f);

    // ── Mie scattering (soft glow around sun) ─────────────────────────────────
    float mieG   = 0.78f;
    float mieD   = 1.0f + mieG*mieG - 2.0f*mieG*mu;
    float mieP   = (1.0f - mieG*mieG) / (4.0f * 3.14159f * pow(mieD, 1.5f));
    float mieStr = 0.065f * saturate(elev + 0.6f);
    skyCol += float3(1.0f, 0.88f, 0.60f) * mieP * mieStr * 12.0f;

    // ── Sun disc ──────────────────────────────────────────────────────────────
    float sunAngCos = 0.9996f;
    float sunDisc   = smoothstep(sunAngCos - 0.0002f, sunAngCos + 0.0002f, mu);
    skyCol = mix(skyCol, float3(1.5f, 1.3f, 0.90f), sunDisc);

    // ── Below-horizon ground bleed ────────────────────────────────────────────
    if (elev < 0.0f) {
        float belowT = saturate(-elev * 5.0f);
        float3 groundBleed = mix(float3(0.55f, 0.60f, 0.62f),
                                  float3(0.22f, 0.20f, 0.18f), belowT);
        skyCol = mix(skyCol, groundBleed, belowT * 0.85f);
    }

    return float4(skyCol, 1.0f);
}
)MSL";

    NSError* err = nil;
    MTLCompileOptions* opts = [[MTLCompileOptions alloc] init];
    opts.languageVersion = MTLLanguageVersion2_4;
    d.shaderLibrary = [d.device newLibraryWithSource:shaderSrc options:opts error:&err];
    if (!d.shaderLibrary) {
        LOG_ERR("Renderer", "Shader compile failed: %s",
                [[err localizedDescription] UTF8String]);
        return false;
    }

    // ─── Vertex descriptor (position, normal, uv) ─────────────────────────
    MTLVertexDescriptor* vd = [MTLVertexDescriptor vertexDescriptor];
    vd.attributes[0].format      = MTLVertexFormatFloat3;
    vd.attributes[0].offset      = offsetof(GpuVertex, position);
    vd.attributes[0].bufferIndex = 0;
    vd.attributes[1].format      = MTLVertexFormatFloat3;
    vd.attributes[1].offset      = offsetof(GpuVertex, normal);
    vd.attributes[1].bufferIndex = 0;
    vd.attributes[2].format      = MTLVertexFormatFloat2;
    vd.attributes[2].offset      = offsetof(GpuVertex, uv);
    vd.attributes[2].bufferIndex = 0;
    vd.layouts[0].stride         = sizeof(GpuVertex);
    vd.layouts[0].stepFunction   = MTLVertexStepFunctionPerVertex;

    // ─── Unit PSO ─────────────────────────────────────────────────────────
    {
        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                               = @"Unit";
        desc.vertexFunction                      = [d.shaderLibrary newFunctionWithName:@"unitVS"];
        desc.fragmentFunction                    = [d.shaderLibrary newFunctionWithName:@"unitFS"];
        desc.vertexDescriptor                    = vd;
        desc.colorAttachments[0].pixelFormat     = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.depthAttachmentPixelFormat          = MTLPixelFormatDepth32Float;
        d.psoUnit = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!d.psoUnit) {
            LOG_ERR("Renderer", "Unit PSO failed: %s", [[err localizedDescription] UTF8String]);
            return false;
        }
    }

    // ─── Trunk PSO (unit VS + procedural bark FS) ─────────────────────────
    {
        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                               = @"Trunk";
        desc.vertexFunction                      = [d.shaderLibrary newFunctionWithName:@"unitVS"];
        desc.fragmentFunction                    = [d.shaderLibrary newFunctionWithName:@"trunkFS"];
        desc.vertexDescriptor                    = vd;
        desc.colorAttachments[0].pixelFormat     = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.depthAttachmentPixelFormat          = MTLPixelFormatDepth32Float;
        d.psoTrunk = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!d.psoTrunk)
            LOG_ERR("Renderer", "Trunk PSO failed: %s", [[err localizedDescription] UTF8String]);
    }

    // ─── Ground PSO ───────────────────────────────────────────────────────
    {
        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                               = @"Ground";
        desc.vertexFunction                      = [d.shaderLibrary newFunctionWithName:@"groundVS"];
        desc.fragmentFunction                    = [d.shaderLibrary newFunctionWithName:@"groundFS"];
        desc.vertexDescriptor                    = vd;
        desc.colorAttachments[0].pixelFormat     = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.depthAttachmentPixelFormat          = MTLPixelFormatDepth32Float;
        d.psoGround = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
    }

    // ─── Construction Plane PSO (translucent, alpha-blended) ─────────────────
    {
        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                               = @"ConstructionPlane";
        desc.vertexFunction                      = [d.shaderLibrary newFunctionWithName:@"groundVS"];
        desc.fragmentFunction                    = [d.shaderLibrary newFunctionWithName:@"constructionPlaneFS"];
        desc.vertexDescriptor                    = vd;
        desc.colorAttachments[0].pixelFormat                 = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.colorAttachments[0].blendingEnabled             = YES;
        desc.colorAttachments[0].rgbBlendOperation           = MTLBlendOperationAdd;
        desc.colorAttachments[0].alphaBlendOperation         = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
        desc.depthAttachmentPixelFormat                      = MTLPixelFormatDepth32Float;
        d.psoConstructionPlane = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!d.psoConstructionPlane)
            LOG_ERR("Renderer", "Construction plane PSO failed: %s", [[err localizedDescription] UTF8String]);
    }

    // ─── Grass PSO (fully procedural — no vertex descriptor) ─────────────────
    {
        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                           = @"Grass";
        desc.vertexFunction                  = [d.shaderLibrary newFunctionWithName:@"grassVS"];
        desc.fragmentFunction                = [d.shaderLibrary newFunctionWithName:@"grassFS"];
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
        d.psoGrass = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!d.psoGrass)
            LOG_ERR("Renderer", "Grass PSO failed: %s", [[err localizedDescription] UTF8String]);
    }

    // Grass uniform buffer: two GpuGrassUniforms (short pass + long pass)
    RING_ALLOC(grassUnifBuf, 2 * sizeof(GpuGrassUniforms));
    // Write static geometry params once at init — into every ring slot, since the
    // per-frame path only refreshes colors. (Each slot keeps its own static copy.)
    for (NSUInteger s = 0; s < kFramesInFlight; ++s) {
        auto* gp = (GpuGrassUniforms*)d.grassUnifBufRing.slot[s].contents;
        gp[0] = { .spacing=0.65f, .halfExt=87.0f, .bladeVerts=9,
                  .bladeHeight=0.14f, .bladeBend=0.0f, .bladeWidth=0.10f, .sideVerts=9,
                  .colorBase=simd_make_float3(0.022f,0.032f,0.008f),
                  .colorTip =simd_make_float3(0.028f,0.040f,0.010f) };
        gp[1] = { .spacing=0.32f, .halfExt=87.0f, .bladeVerts=15,
                  .bladeHeight=1.0f,  .bladeBend=1.7f,  .bladeWidth=0.16f, .sideVerts=15,
                  .colorBase=simd_make_float3(0.055f,0.075f,0.022f),
                  .colorTip =simd_make_float3(0.20f, 0.26f, 0.07f)  };
    }

    // ─── Shell PSO (ground mesh reused, per-shell height discard) ────────────
    {
        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                           = @"Shell";
        desc.vertexFunction                  = [d.shaderLibrary newFunctionWithName:@"shellVS"];
        desc.fragmentFunction                = [d.shaderLibrary newFunctionWithName:@"shellFS"];
        desc.vertexDescriptor                = vd;   // same layout as ground mesh
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
        d.psoShell = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!d.psoShell)
            LOG_ERR("Renderer", "Shell PSO failed: %s", [[err localizedDescription] UTF8String]);
    }

    // Projectile uses same PSO as unit (sphere mesh)
    d.psoProjectile = d.psoUnit;

    // ─── Depth stencil ────────────────────────────────────────────────────
    {
        auto* desc      = [[MTLDepthStencilDescriptor alloc] init];
        // Reversed-Z: nearer geometry has the LARGER depth value, so test Greater.
        desc.depthCompareFunction = MTLCompareFunctionGreater;
        desc.depthWriteEnabled    = YES;
        d.dssDefault = [d.device newDepthStencilStateWithDescriptor:desc];
        desc.depthWriteEnabled    = NO;
        d.dssNoWrite = [d.device newDepthStencilStateWithDescriptor:desc];
        desc.depthCompareFunction = MTLCompareFunctionAlways;
        d.dssAlways  = [d.device newDepthStencilStateWithDescriptor:desc];
    }

    // ─── Sky PSO (fullscreen triangle, no vertex buffer, always-pass depth) ───
    {
        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                               = @"Sky";
        desc.vertexFunction                      = [d.shaderLibrary newFunctionWithName:@"skyVS"];
        desc.fragmentFunction                    = [d.shaderLibrary newFunctionWithName:@"skyFS"];
        desc.vertexDescriptor                    = nil;
        desc.colorAttachments[0].pixelFormat     = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.depthAttachmentPixelFormat          = MTLPixelFormatDepth32Float;
        d.psoSky = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!d.psoSky) {
            LOG_ERR("Renderer", "Sky PSO failed: %s", [[err localizedDescription] UTF8String]);
            return false;
        }
    }
    RING_ALLOC(skyUniformBuf, sizeof(SkyGpuUniforms));

    // ─── Mesh buffers ─────────────────────────────────────────────────────
    auto uploadMesh = [&](std::vector<GpuVertex>& verts, std::vector<uint16_t>& indices,
                          id<MTLBuffer>& vBuf, id<MTLBuffer>& iBuf, uint32_t& iCount) {
        vBuf = [d.device newBufferWithBytes:verts.data()
                                     length:verts.size() * sizeof(GpuVertex)
                                    options:MTLResourceStorageModeShared];
        iBuf = [d.device newBufferWithBytes:indices.data()
                                     length:indices.size() * sizeof(uint16_t)
                                    options:MTLResourceStorageModeShared];
        iCount = (uint32_t)indices.size();
    };

    {
        std::vector<GpuVertex> v; std::vector<uint16_t> i;
        BuildUnitMesh(v, i);
        uploadMesh(v, i, d.unitVertexBuf, d.unitIndexBuf, d.unitIndexCount);
    }
    {
        std::vector<GpuVertex> v; std::vector<uint16_t> i;
        BuildGroundMesh(v, i);
        uploadMesh(v, i, d.groundVertexBuf, d.groundIndexBuf, d.groundIndexCount);
    }
    // ─── Procedural tree trunks: mesh + initial scatter ──────────────────────
    {
        std::vector<GpuVertex> v; std::vector<uint16_t> i;
        BuildTrunkMesh(v, i);
        uploadMesh(v, i, d.trunkVertexBuf, d.trunkIndexBuf, d.trunkIndexCount);
        ScatterTrunks(d, d.device, RenderScene::TreeParams{});   // defaults; T panel re-scatters
        LOG_INF("Renderer", "Scattered %zu tree trunks", d.trunks.size());
    }
    // GPU mirror of the terrain heightfield (zero-filled = flat) for procedural grass.
    d.heightFieldBuf = [d.device newBufferWithBytes:Terrain::gHeightField
                                             length:sizeof(Terrain::gHeightField)
                                            options:MTLResourceStorageModeShared];
    // Grass interaction field (push + squish from character movement)
    RING_ALLOC(interactBuf, sizeof(d.interactField));
    for (NSUInteger s = 0; s < kFramesInFlight; ++s)
        memset(d.interactBufRing.slot[s].contents, 0, sizeof(d.interactField));
    RING_ALLOC(shellCtrlBuf,   sizeof(ShellCtrlGpu));
    RING_ALLOC(longDensityBuf, sizeof(float) * 2);
    {
        std::vector<GpuVertex> v; std::vector<uint16_t> i;
        BuildSphereMesh(v, i);
        uploadMesh(v, i, d.sphereVertexBuf, d.sphereIndexBuf, d.sphereIndexCount);
    }
    {
        std::vector<GpuVertex> v; std::vector<uint16_t> i;
        BuildDiscMesh(v, i);
        uploadMesh(v, i, d.discVertexBuf, d.discIndexBuf, d.discIndexCount);
    }
    // ─── Cursor PSO (flat/unlit) ──────────────────────────────────────────
    {
        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                           = @"Cursor";
        desc.vertexFunction                  = [d.shaderLibrary newFunctionWithName:@"flatVS"];
        desc.fragmentFunction                = [d.shaderLibrary newFunctionWithName:@"flatFS"];
        desc.vertexDescriptor                = vd;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.depthAttachmentPixelFormat      = MTLPixelFormatDepth32Float;
        d.psoCursor = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!d.psoCursor) {
            LOG_ERR("Renderer", "Cursor PSO failed: %s", [[err localizedDescription] UTF8String]);
            return false;
        }
    }

    // ─── Explosion PSO (alpha-blended disc) ──────────────────────────────────
    {
        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                           = @"Explosion";
        desc.vertexFunction                  = [d.shaderLibrary newFunctionWithName:@"explosionVS"];
        desc.fragmentFunction                = [d.shaderLibrary newFunctionWithName:@"explosionFS"];
        desc.vertexDescriptor                = vd;
        desc.colorAttachments[0].pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.colorAttachments[0].blendingEnabled             = YES;
        desc.colorAttachments[0].rgbBlendOperation           = MTLBlendOperationAdd;
        desc.colorAttachments[0].alphaBlendOperation         = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
        desc.depthAttachmentPixelFormat                      = MTLPixelFormatDepth32Float;
        d.psoExplosion = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!d.psoExplosion) {
            LOG_ERR("Renderer", "Explosion PSO failed: %s", [[err localizedDescription] UTF8String]);
            return false;
        }
    }

    // ─── Selection ring PSO (alpha-blended, vertex-colored ground mesh) ──────
    {
        MTLVertexDescriptor* rvd = [MTLVertexDescriptor vertexDescriptor];
        rvd.attributes[0].format      = MTLVertexFormatFloat3;
        rvd.attributes[0].offset      = 0;
        rvd.attributes[0].bufferIndex = 0;
        rvd.attributes[1].format      = MTLVertexFormatFloat4;
        rvd.attributes[1].offset      = 12;  // after float3 (no simd padding — plain struct)
        rvd.attributes[1].bufferIndex = 0;
        rvd.layouts[0].stride         = sizeof(RingGpuVertex);  // 28 bytes
        rvd.layouts[0].stepFunction   = MTLVertexStepFunctionPerVertex;

        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                                           = @"SelectionRing";
        desc.vertexFunction                                  = [d.shaderLibrary newFunctionWithName:@"selectionRingVS"];
        desc.fragmentFunction                                = [d.shaderLibrary newFunctionWithName:@"selectionRingFS"];
        desc.vertexDescriptor                                = rvd;
        desc.colorAttachments[0].pixelFormat                 = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.colorAttachments[0].blendingEnabled             = YES;
        desc.colorAttachments[0].rgbBlendOperation           = MTLBlendOperationAdd;
        desc.colorAttachments[0].alphaBlendOperation         = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceRGBBlendFactor        = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor   = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].sourceAlphaBlendFactor      = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor = MTLBlendFactorZero;
        desc.depthAttachmentPixelFormat                      = MTLPixelFormatDepth32Float;
        d.psoSelectionRing = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!d.psoSelectionRing) {
            LOG_ERR("Renderer", "Selection ring PSO failed: %s", [[err localizedDescription] UTF8String]);
            return false;
        }
    }
    {
        // 3 rings × 2 edges × kSegs verts × kMaxUnits
        constexpr size_t vSize = 3 * 2 * MetalRendererImpl::kSelRingSegs
                               * MetalRendererImpl::kSelRingMaxUnits * sizeof(RingGpuVertex);
        // 3 rings × kSegs quads × 6 indices × kMaxUnits
        constexpr size_t iSize = 3 * MetalRendererImpl::kSelRingSegs
                               * MetalRendererImpl::kSelRingMaxUnits * 6 * sizeof(uint16_t);
        RING_ALLOC(selRingVertBuf, vSize);
        RING_ALLOC(selRingIdxBuf,  iSize);
    }
    {
        // 3 rings × 2 edges × kCursorRingSegs verts (single cursor)
        constexpr size_t vSize = 3 * 2 * MetalRendererImpl::kCursorRingSegs * sizeof(RingGpuVertex);
        constexpr size_t iSize = 3 * MetalRendererImpl::kCursorRingSegs * 6 * sizeof(uint16_t);
        RING_ALLOC(cursorRingVertBuf, vSize);
        RING_ALLOC(cursorRingIdxBuf,  iSize);
    }

    {
        // Each debug ring: kDbgDotSegs dots, each a small flat quad (4 verts, 6 idx)
        constexpr size_t vSize = MetalRendererImpl::kDbgRingMaxRings
                               * MetalRendererImpl::kDbgDotSegs * 4 * sizeof(RingGpuVertex);
        constexpr size_t iSize = MetalRendererImpl::kDbgRingMaxRings
                               * MetalRendererImpl::kDbgDotSegs * 6 * sizeof(uint16_t);
        RING_ALLOC(dbgRingVertBuf, vSize);
        RING_ALLOC(dbgRingIdxBuf,  iSize);
    }
    {
        // Light aura discs: (kAuraSegs+1) verts × kMaxAuras, kAuraSegs×3 idx × kMaxAuras
        constexpr size_t vSize = (size_t)MetalRendererImpl::kMaxAurasBuf
                               * (MetalRendererImpl::kAuraSegs + 1) * sizeof(RingGpuVertex);
        constexpr size_t iSize = (size_t)MetalRendererImpl::kMaxAurasBuf
                               * MetalRendererImpl::kAuraSegs * 3 * sizeof(uint16_t);
        RING_ALLOC(auraVertBuf, vSize);
        RING_ALLOC(auraIdxBuf,  iSize);
    }

    d.cursorInstBuf = [d.device newBufferWithLength:sizeof(GpuInstanceData)
                                             options:MTLResourceStorageModeShared];
    RING_ALLOC(shadowInstBuf,    sizeof(GpuInstanceData) * MetalRendererImpl::kMaxInstances);
    RING_ALLOC(explosionInstBuf, sizeof(GpuInstanceData) * MetalRendererImpl::kMaxInstances);

    // ─── Skinned character PSO ────────────────────────────────────────────────
    {
        MTLVertexDescriptor* svd = [MTLVertexDescriptor vertexDescriptor];
        svd.attributes[0].format      = MTLVertexFormatFloat3;
        svd.attributes[0].offset      = offsetof(SkinnedGpuVertex, position);
        svd.attributes[0].bufferIndex = 0;
        svd.attributes[1].format      = MTLVertexFormatFloat3;
        svd.attributes[1].offset      = offsetof(SkinnedGpuVertex, normal);
        svd.attributes[1].bufferIndex = 0;
        svd.attributes[2].format      = MTLVertexFormatFloat2;
        svd.attributes[2].offset      = offsetof(SkinnedGpuVertex, uv);
        svd.attributes[2].bufferIndex = 0;
        svd.attributes[3].format      = MTLVertexFormatUShort4;
        svd.attributes[3].offset      = offsetof(SkinnedGpuVertex, joints);
        svd.attributes[3].bufferIndex = 0;
        svd.attributes[4].format      = MTLVertexFormatFloat4;
        svd.attributes[4].offset      = offsetof(SkinnedGpuVertex, weights);
        svd.attributes[4].bufferIndex = 0;
        svd.layouts[0].stride         = sizeof(SkinnedGpuVertex);
        svd.layouts[0].stepFunction   = MTLVertexStepFunctionPerVertex;

        auto* desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.label                           = @"Skinned";
        desc.vertexFunction                  = [d.shaderLibrary newFunctionWithName:@"skinnedVS"];
        desc.fragmentFunction                = [d.shaderLibrary newFunctionWithName:@"unitFS"];
        desc.vertexDescriptor                = svd;
        desc.colorAttachments[0].pixelFormat                = MTLPixelFormatBGRA8Unorm_sRGB;
        desc.colorAttachments[0].blendingEnabled            = YES;
        desc.colorAttachments[0].rgbBlendOperation          = MTLBlendOperationAdd;
        desc.colorAttachments[0].alphaBlendOperation        = MTLBlendOperationAdd;
        desc.colorAttachments[0].sourceRGBBlendFactor       = MTLBlendFactorSourceAlpha;
        desc.colorAttachments[0].destinationRGBBlendFactor  = MTLBlendFactorOneMinusSourceAlpha;
        desc.colorAttachments[0].sourceAlphaBlendFactor     = MTLBlendFactorOne;
        desc.colorAttachments[0].destinationAlphaBlendFactor= MTLBlendFactorZero;
        desc.depthAttachmentPixelFormat                     = MTLPixelFormatDepth32Float;
        d.psoSkinned = [d.device newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!d.psoSkinned)
            LOG_ERR("Renderer", "Skinned PSO failed: %s", [[err localizedDescription] UTF8String]);
    }

    // ─── Terrain construction editor init ─────────────────────────────────────
    {
        constexpr float kCornerExt = kConstructionPlaneExt;
        d.terrainNodes[0] = { -kCornerExt, 0.f, -kCornerExt, true, false };
        d.terrainNodes[1] = {  kCornerExt, 0.f, -kCornerExt, true, false };
        d.terrainNodes[2] = { -kCornerExt, 0.f,  kCornerExt, true, false };
        d.terrainNodes[3] = {  kCornerExt, 0.f,  kCornerExt, true, false };
        d.terrainNodeCount = 4;
        RING_ALLOC(nodeInstBuf, sizeof(GpuInstanceData) * MetalRendererImpl::kMaxTerrainNodes);
        UpdateCPMesh(d);
    }

    // ─── Load Soldier + bone buffer ───────────────────────────────────────────
    {
        NSString* modelPath = [[NSBundle mainBundle] pathForResource:@"Soldier" ofType:@"glb"];
        if (modelPath) {
            LoadGltfModel(d.device, [modelPath UTF8String], d.soldier);
            d.idleClipIdx = d.soldier.FindClip("Idle");
            d.walkClipIdx = d.soldier.FindClip("Walk");
            if (d.idleClipIdx < 0) LOG_ERR("Renderer", "Soldier.glb: no 'Idle' clip found");
            if (d.walkClipIdx < 0) LOG_ERR("Renderer", "Soldier.glb: no 'Walk' clip found");
            // Procedural retarget shelved — see disabled block in the skinned render loop.
            // if (d.soldier.loaded) BuildRetargetMap(d.soldier);
        } else {
            LOG_ERR("Renderer", "Soldier.glb not found in bundle");
        }

        // Bone matrix buffer: kMaxShadowDiscs instances × kMaxJoints matrices each
        constexpr size_t boneBufSize = RenderScene::kMaxShadowDiscs * kMaxJoints * sizeof(simd_float4x4);
        RING_ALLOC(boneBuf,     boneBufSize);
        RING_ALLOC(charInstBuf, RenderScene::kMaxShadowDiscs * sizeof(GpuInstanceData));
        RING_ALLOC(dotInstBuf,  RenderScene::kMaxShadowDiscs * sizeof(GpuInstanceData));
        constexpr int kRingSegs = 64;
        RING_ALLOC(ringInstBuf, kRingSegs * RenderScene::kMaxFollowRings * sizeof(GpuInstanceData));

        // Stagger idle start phases so discs aren't in lockstep
        for (int i = 0; i < (int)RenderScene::kMaxShadowDiscs; ++i)
            d.charIdleTime[i] = (float)i * 0.37f;
    }

    // ─── Instance + uniform buffers ───────────────────────────────────────
    RING_ALLOC(instanceBuf, sizeof(GpuInstanceData) * MetalRendererImpl::kMaxInstances);
    RING_ALLOC(propInstBuf, sizeof(GpuInstanceData) * MetalRendererImpl::kMaxInstances);
    RING_ALLOC(pullInstBuf, sizeof(GpuInstanceData));
    RING_ALLOC(projInstBuf, sizeof(GpuInstanceData) * MetalRendererImpl::kMaxInstances);
    RING_ALLOC(uniformBuf,  sizeof(GpuFrameUniforms));

    // ─── Frame-in-flight semaphore (bounds CPU run-ahead to kFramesInFlight) ──
    d.frameSem = dispatch_semaphore_create(kFramesInFlight);

    // ─── Depth texture ────────────────────────────────────────────────────
    Resize(widthPx, heightPx);

    LOG_INF("Renderer", "MetalRenderer initialised (%ux%u)", widthPx, heightPx);
    return true;
}

void MetalRenderer::Shutdown() {
    m_impl->device = nil;
}

void MetalRenderer::Resize(u32 widthPx, u32 heightPx) {
    auto& d = *m_impl;
    if (widthPx == 0 || heightPx == 0) return;
    d.viewportWidth  = widthPx;
    d.viewportHeight = heightPx;

    MTLTextureDescriptor* td = [[MTLTextureDescriptor alloc] init];
    td.pixelFormat   = MTLPixelFormatDepth32Float;
    td.width         = widthPx;
    td.height        = heightPx;
    td.usage         = MTLTextureUsageRenderTarget;
    td.storageMode   = MTLStorageModePrivate;
    d.depthTexture   = [d.device newTextureWithDescriptor:td];
}

void MetalRenderer::SetDisplayScale(f32 scale) {
    m_impl->displayScale = scale;
    if (m_impl->metalLayer)
        m_impl->metalLayer.contentsScale = scale;
}

void MetalRenderer::BeginFrame(f32 dt) {
    auto& d = *m_impl;
    d.time   += dt;
    d.lastDt  = dt;
    d.drawCallCount = 0;

    // Block until the GPU has finished a frame ≥ kFramesInFlight ago, so the
    // slot we are about to write/bind is guaranteed no longer in flight.
    dispatch_semaphore_wait(d.frameSem, DISPATCH_TIME_FOREVER);

    d.currentDrawable = [d.metalLayer nextDrawable];
    if (!d.currentDrawable) {
        dispatch_semaphore_signal(d.frameSem);  // nothing committed — give the slot back
        return;
    }

    // Rotate to this frame's buffer slot and point every dynamic buffer at it.
    d.frameSlot = (d.frameSlot + 1) % kFramesInFlight;
    RING_ADVANCE(uniformBuf);       RING_ADVANCE(skyUniformBuf);    RING_ADVANCE(interactBuf);
    RING_ADVANCE(shellCtrlBuf);     RING_ADVANCE(longDensityBuf);   RING_ADVANCE(grassUnifBuf);
    RING_ADVANCE(instanceBuf);      RING_ADVANCE(propInstBuf);      RING_ADVANCE(pullInstBuf);
    RING_ADVANCE(projInstBuf);      RING_ADVANCE(shadowInstBuf);    RING_ADVANCE(explosionInstBuf);
    RING_ADVANCE(nodeInstBuf);      RING_ADVANCE(boneBuf);          RING_ADVANCE(charInstBuf);
    RING_ADVANCE(dotInstBuf);       RING_ADVANCE(ringInstBuf);      RING_ADVANCE(trunkInstBuf);
    RING_ADVANCE(auraVertBuf);      RING_ADVANCE(auraIdxBuf);       RING_ADVANCE(selRingVertBuf);
    RING_ADVANCE(selRingIdxBuf);    RING_ADVANCE(cursorRingVertBuf);RING_ADVANCE(cursorRingIdxBuf);
    RING_ADVANCE(dbgRingVertBuf);   RING_ADVANCE(dbgRingIdxBuf);

    d.currentCmdBuf = [d.commandQueue commandBuffer];
    d.currentCmdBuf.label = @"FrameCmdBuf";

    auto* rpd = [[MTLRenderPassDescriptor alloc] init];
    rpd.colorAttachments[0].texture     = d.currentDrawable.texture;
    rpd.colorAttachments[0].loadAction  = MTLLoadActionClear;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
    rpd.colorAttachments[0].clearColor  = MTLClearColorMake(0.08, 0.09, 0.11, 1.0);
    rpd.depthAttachment.texture         = d.depthTexture;
    rpd.depthAttachment.loadAction      = MTLLoadActionClear;
    rpd.depthAttachment.storeAction     = MTLStoreActionDontCare;
    rpd.depthAttachment.clearDepth      = 0.0;  // reversed-Z: far plane = 0
    d.currentRPD = rpd;
}

void MetalRenderer::RenderScene(const ::RenderScene& scene) {
    auto& d = *m_impl;
    if (!d.currentCmdBuf || !d.currentDrawable) return;

    // ─── Update frame uniforms ─────────────────────────────────────────────
    {
        GpuFrameUniforms uf;
        f32 aspect = (float)d.viewportWidth / (float)d.viewportHeight;

        // Camera lookAt
        auto cp = scene.cameraPos;
        auto ct = scene.cameraTarget;
        simd_float3 eye    = simd_make_float3(cp.x, cp.y, cp.z);
        simd_float3 center = simd_make_float3(ct.x, ct.y, ct.z);
        simd_float3 up     = simd_make_float3(0, 1, 0);
        simd_float3 z      = simd_normalize(eye - center);
        simd_float3 x      = simd_normalize(simd_cross(up, z));
        simd_float3 y      = simd_cross(z, x);

        simd_float4x4 viewMat = {{
            simd_make_float4(x.x, y.x, z.x, 0),
            simd_make_float4(x.y, y.y, z.y, 0),
            simd_make_float4(x.z, y.z, z.z, 0),
            simd_make_float4(-simd_dot(x,eye), -simd_dot(y,eye), -simd_dot(z,eye), 1)
        }};

        f32 fovY = scene.cameraFovY;
        f32 near = scene.cameraNear;
        f32 ys   = 1.0f / tanf(fovY * 0.5f);
        f32 xs   = ys / aspect;
        // Reversed-Z with an infinite far plane: maps near→depth 1, infinity→depth 0.
        // Paired with a Depth32Float buffer (cleared to 0, Greater compare) this gives
        // effectively unlimited draw distance with no z-fighting. scene.cameraFar is
        // intentionally ignored here — restore a finite far when reinstating draw clamp.
        simd_float4x4 proj = {{
            simd_make_float4(xs,  0,    0,  0),
            simd_make_float4( 0, ys,    0,  0),
            simd_make_float4( 0,  0,    0, -1),
            simd_make_float4( 0,  0, near,  0)
        }};
        uf.viewProj    = simd_mul(proj, viewMat);
        uf.cameraPos   = eye;
        uf.time        = d.time;
        uf.lightDir    = simd_normalize(simd_make_float3(-0.5f, -1.0f, -0.3f));
        uf.lightColor  = simd_make_float3(1.0f, 0.95f, 0.85f);
        uf.ambientColor= simd_make_float3(0.15f, 0.17f, 0.22f);
        uf.auraCount = (int32_t)scene.auraCount;
        for (int a = 0; a < (int)scene.auraCount && a < 8; ++a)
            uf.auraData[a] = simd_make_float4(
                scene.auras[a].center.x, scene.auras[a].center.z,
                scene.auras[a].radius, 0.f);

        memcpy(d.uniformBuf.contents, &uf, sizeof(uf));

        // Populate sky uniforms (invViewProj + sun direction)
        SkyGpuUniforms su;
        su.invViewProj = simd_inverse(uf.viewProj);
        su.sunDir      = -uf.lightDir;  // lightDir points toward scene; sun is opposite
        su.time        = d.time;
        memcpy(d.skyUniformBuf.contents, &su, sizeof(su));
    }

    // ─── Grass interaction field update ──────────────────────────────────────
    if (d.interactBuf) {
        const float dt = d.lastDt;
        const int   N  = MetalRendererImpl::kIFDivs;
        const float kIFSize = MetalRendererImpl::kIFSize;

        // Decay: squish recovers in ~120 s, push springs back in ~0.12 s
        const float squishFade = expf(-dt / 120.0f);
        const float pushFade   = expf(-dt / 0.12f);
        for (int i = 0; i < N * N; ++i) {
            d.interactField[i].x *= pushFade;
            d.interactField[i].y *= pushFade;
            d.interactField[i].z *= squishFade;
        }

        // Stamp from each visible shadow disc (characters)
        for (uint32_t si = 0; si < scene.shadowDiscCount; ++si) {
            const auto& sd      = scene.shadowDiscs[si];
            float cx = sd.position.x, cz = sd.position.z;
            float speed = sqrtf(sd.velocity.x * sd.velocity.x +
                                sd.velocity.z * sd.velocity.z);
            float sqRad   = sd.radius + 0.6f;  // squish footprint
            float pushRad = sd.radius + 1.8f;  // push reaches further out

            // World-space bounding box → cell range
            float maxRad = fmaxf(sqRad, pushRad);
            int x0 = (int)((cx - maxRad + kIFSize) / (2.0f * kIFSize) * N) - 1;
            int z0 = (int)((cz - maxRad + kIFSize) / (2.0f * kIFSize) * N) - 1;
            int x1 = (int)((cx + maxRad + kIFSize) / (2.0f * kIFSize) * N) + 1;
            int z1 = (int)((cz + maxRad + kIFSize) / (2.0f * kIFSize) * N) + 1;
            x0 = std::max(0, x0); x1 = std::min(N - 1, x1);
            z0 = std::max(0, z0); z1 = std::min(N - 1, z1);

            const float sqRad2   = sqRad   * sqRad;
            const float pushRad2 = pushRad * pushRad;
            const bool  canPush  = (speed > 0.05f);
            const float speedCap = fminf(speed * 1.2f, 1.0f);
            for (int zi = z0; zi <= z1; ++zi) {
                for (int xi = x0; xi <= x1; ++xi) {
                    float wx  = (xi + 0.5f) / N * (2.0f * kIFSize) - kIFSize;
                    float wz  = (zi + 0.5f) / N * (2.0f * kIFSize) - kIFSize;
                    float dx  = wx - cx, dz = wz - cz;
                    float d2  = dx * dx + dz * dz;
                    if (d2 >= pushRad2) continue;  // outside both radii — skip entirely
                    auto& cell = d.interactField[zi * N + xi];

                    float dist = sqrtf(d2);  // one sqrt, shared by both effects

                    // Squish: smooth stamp within foot radius
                    if (d2 < sqRad2) {
                        float s = 1.0f - dist / sqRad;
                        cell.z = fmaxf(cell.z, s * s);
                    }

                    // Push: displaced away from character, proportional to speed
                    if (canPush && dist > 0.01f) {
                        float str  = (1.0f - dist / pushRad) * speedCap;
                        float invD = 1.0f / dist;
                        float px   = dx * invD * str;
                        float pz   = dz * invD * str;
                        // Compare squared magnitudes to avoid a second sqrt
                        if (str * str > cell.x * cell.x + cell.y * cell.y) {
                            cell.x = px; cell.y = pz;
                        }
                    }
                }
            }
        }

        memcpy(d.interactBuf.contents, d.interactField, sizeof(d.interactField));
    }

    id<MTLRenderCommandEncoder> enc =
        [d.currentCmdBuf renderCommandEncoderWithDescriptor:d.currentRPD];
    enc.label = @"MainPass";

    MTLViewport vp { 0, 0, (double)d.viewportWidth, (double)d.viewportHeight, 0, 1 };
    [enc setViewport:vp];

    // ─── Sky (fullscreen, always-pass depth, drawn first as background) ───
    if (d.psoSky && d.skyUniformBuf) {
        [enc setDepthStencilState:d.dssAlways];
        [enc setRenderPipelineState:d.psoSky];
        [enc setFragmentBuffer:d.skyUniformBuf offset:0 atIndex:0];
        [enc drawPrimitives:MTLPrimitiveTypeTriangle vertexStart:0 vertexCount:3];
        d.drawCallCount++;
    }

    [enc setDepthStencilState:d.dssDefault];

    // ─── Ground ───────────────────────────────────────────────────────────
    [enc setRenderPipelineState:d.psoGround];
    [enc setVertexBuffer:d.groundVertexBuf offset:0 atIndex:0];
    [enc setVertexBuffer:d.uniformBuf      offset:0 atIndex:1];
    [enc setFragmentBuffer:d.uniformBuf    offset:0 atIndex:1];
    {
        float terraceNoise[2] = { scene.terraceNoiseStrength, scene.terraceNoiseScale };
        [enc setFragmentBytes:terraceNoise length:sizeof(terraceNoise) atIndex:2];
    }
    [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                    indexCount:d.groundIndexCount
                     indexType:d.groundIndexType
                   indexBuffer:d.groundIndexBuf
             indexBufferOffset:0];
    d.drawCallCount++;

    // ─── Grass (mode-switched) ────────────────────────────────────────────────
    if (d.grassUnifBuf) {
        auto* gp = (GpuGrassUniforms*)d.grassUnifBuf.contents;
        // Grass scatter is unscaled and world-fixed: a constant ±87 patch at native density,
        // independent of the procedural ground multiplier. (Scale-aware grass optimisation is
        // prototyped separately in the Ironclad-OH project.) worldScale/hfDivs are still passed so
        // blades sample the dynamic-resolution heightfield correctly.
        const float kBaseHalfExt = 87.0f;
        const float kBaseSpacing[2] = { 0.65f, 0.32f };   // short sticks, tall blades
        for (int gi2 = 0; gi2 < 2; ++gi2) {
            gp[gi2].worldScale = d.worldScale;
            gp[gi2].hfDivs     = Terrain::gHFDivs;
            gp[gi2].halfExt    = kBaseHalfExt;
            gp[gi2].spacing    = kBaseSpacing[gi2];
            gp[gi2].mode       = scene.grassGenerationMode;
            gp[gi2].optMode    = scene.grassOptimizationMode;
        }
        const int grassMode = scene.grassGenerationMode;

        // ── Small blade pass — shell grass (terrain mesh redrawn N times) ────
        bool drawShellGrass = scene.shellGrassVisible && (grassMode == 0 || grassMode == 7);
        bool drawLongGrass  = scene.longGrassVisible  && grassMode != 1 && grassMode != 7;
        if (d.psoShell && drawShellGrass) {
            // Upload shell ctrl (colors + density)
            ShellCtrlGpu sc;
            sc.colorBase = simd_make_float3(scene.shellGrassColorBase.x,
                                            scene.shellGrassColorBase.y,
                                            scene.shellGrassColorBase.z);
            sc.colorTip  = simd_make_float3(scene.shellGrassColorTip.x,
                                            scene.shellGrassColorTip.y,
                                            scene.shellGrassColorTip.z);
            sc.density   = scene.shellGrassDensity * (grassMode == 1 ? 0.55f : grassMode == 7 ? 1.7f : 1.0f);
            sc._pad      = 0.0f;
            memcpy(d.shellCtrlBuf.contents, &sc, sizeof(sc));

            int   kShells    = grassMode == 7 ? 18 : grassMode == 1 ? 6 : 12;
            float kMaxShellH = grassMode == 7 ? 0.22f : grassMode == 1 ? 0.06f : 0.14f;
            float shellParams[2] = { float(kShells), kMaxShellH };
            [enc setRenderPipelineState:d.psoShell];
            [enc setDepthStencilState:d.dssDefault];
            [enc setCullMode:MTLCullModeNone];
            [enc setVertexBuffer:d.groundVertexBuf offset:0 atIndex:0];
            [enc setVertexBuffer:d.uniformBuf      offset:0 atIndex:1];
            [enc setVertexBytes:shellParams length:sizeof(shellParams) atIndex:2];
            [enc setFragmentBuffer:d.uniformBuf    offset:0 atIndex:1];
            [enc setFragmentBuffer:d.interactBuf   offset:0           atIndex:4];
            [enc setFragmentBuffer:d.shellCtrlBuf  offset:0           atIndex:5];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:d.groundIndexCount
                             indexType:d.groundIndexType
                           indexBuffer:d.groundIndexBuf
                     indexBufferOffset:0
                         instanceCount:kShells];
            d.drawCallCount++;
        }

        // ── Tall blade pass — Bézier blades ──────────────────────────────────
        if (d.psoGrass && drawLongGrass) {
            // Apply G-panel color overrides to gp[1]
            gp[1].colorBase = simd_make_float3(scene.longGrassColorBase.x,
                                               scene.longGrassColorBase.y,
                                               scene.longGrassColorBase.z);
            gp[1].colorTip  = simd_make_float3(scene.longGrassColorTip.x,
                                               scene.longGrassColorTip.y,
                                               scene.longGrassColorTip.z);
            float modeDensityScale = 1.0f;
            if (grassMode == 2) modeDensityScale = 0.55f;
            else if (grassMode == 3) modeDensityScale = 1.0f;
            else if (grassMode == 4) modeDensityScale = 0.75f;
            else if (grassMode == 5) modeDensityScale = 0.95f;
            else if (grassMode == 6) modeDensityScale = 0.85f;
            else if (grassMode == 8) modeDensityScale = 1.0f;
            else if (grassMode == 9) modeDensityScale = 0.85f;
            else if (grassMode == 10) modeDensityScale = 0.38f;
            float longDensParams[2] = { scene.longGrassDensity * modeDensityScale, scene.longStepEdgeDensity };
            memcpy(d.longDensityBuf.contents, longDensParams, sizeof(longDensParams));

            GpuGrassUniforms& pg = gp[1];
            int gridW      = (int)roundf(2.0f * pg.halfExt / pg.spacing);
            int bladeCount = gridW * gridW;
            int vertCount  = bladeCount * (pg.bladeVerts + pg.sideVerts);
            [enc setRenderPipelineState:d.psoGrass];
            [enc setDepthStencilState:d.dssDefault];
            [enc setCullMode:MTLCullModeNone];
            [enc setVertexBuffer:d.uniformBuf     offset:0                            atIndex:1];
            [enc setVertexBuffer:d.grassUnifBuf   offset:sizeof(GpuGrassUniforms)     atIndex:2];
            [enc setVertexBuffer:d.heightFieldBuf offset:0                            atIndex:3];
            [enc setVertexBytes:&d.terraceStepDrop length:sizeof(float)               atIndex:4];
            [enc setVertexBuffer:d.interactBuf    offset:0                            atIndex:5];
            [enc setVertexBuffer:d.longDensityBuf offset:0                            atIndex:6];
            [enc setFragmentBuffer:d.uniformBuf   offset:0                            atIndex:1];
            [enc setFragmentBuffer:d.grassUnifBuf offset:sizeof(GpuGrassUniforms)     atIndex:2];
            [enc drawPrimitives:MTLPrimitiveTypeTriangle
                    vertexStart:0
                    vertexCount:(NSUInteger)vertCount];
            d.drawCallCount++;
        }
    }

    // ─── Light aura discs (drawn on terrain surface, before opaque geometry) ─
    if (scene.auraCount > 0 && d.psoSelectionRing && d.auraVertBuf && d.auraIdxBuf) {
        constexpr int   kSegs        = MetalRendererImpl::kAuraSegs;
        constexpr float kCR          = 1.00f, kCG = 0.97f, kCB = 0.82f; // warm candlelight
        constexpr float kCenterAlpha = 0.18f;
        constexpr float kOffY        = 0.025f;

        auto* av       = (RingGpuVertex*)d.auraVertBuf.contents;
        auto* ai       = (uint16_t*)d.auraIdxBuf.contents;
        uint32_t totalVerts = 0, totalIdx = 0;

        for (int a = 0; a < scene.auraCount; ++a) {
            const auto& aura = scene.auras[a];
            float cx = aura.center.x, cz = aura.center.z, R = aura.radius;
            uint32_t vBase = totalVerts;

            av[totalVerts++] = { cx, Terrain::Height(cx, cz) + kOffY, cz,
                                 kCR, kCG, kCB, kCenterAlpha };
            for (int s = 0; s < kSegs; ++s) {
                float theta = 2.f * (float)M_PI * s / (float)kSegs;
                float ex = cx + R * cosf(theta), ez = cz + R * sinf(theta);
                av[totalVerts++] = { ex, Terrain::Height(ex, ez) + kOffY, ez,
                                     kCR, kCG, kCB, 0.f };
            }
            for (int s = 0; s < kSegs; ++s) {
                ai[totalIdx++] = (uint16_t)vBase;
                ai[totalIdx++] = (uint16_t)(vBase + 1 + s);
                ai[totalIdx++] = (uint16_t)(vBase + 1 + (s + 1) % kSegs);
            }
        }

        if (totalIdx > 0) {
            [enc setDepthStencilState:d.dssNoWrite];
            [enc setCullMode:MTLCullModeNone];
            [enc setRenderPipelineState:d.psoSelectionRing];
            [enc setVertexBuffer:d.auraVertBuf  offset:0 atIndex:0];
            [enc setVertexBuffer:d.uniformBuf   offset:0 atIndex:1];
            [enc setFragmentBuffer:d.uniformBuf offset:0 atIndex:1];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:(NSUInteger)totalIdx
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:d.auraIdxBuf
                     indexBufferOffset:0];
            d.drawCallCount++;
            [enc setDepthStencilState:d.dssDefault];
        }
    }

    auto* instData = (GpuInstanceData*)d.instanceBuf.contents;

    // ─── Unit ground shadows (grey discs, drawn before selection rings and cursor) ──
    if ((scene.unitCount > 0 || scene.shadowDiscCount > 0) && d.shadowInstBuf) {
        auto* sd = (GpuInstanceData*)d.shadowInstBuf.contents;
        uint32_t shadowCount = 0;

        // Build a disc instance matrix tilted to match local terrain normal.
        // The disc mesh lies flat in local XZ; col0/col2 are scaled tangent/bitangent, col1 is normal.
        auto tiltedDisc = [](float cx, float cy, float cz, float r) -> simd_float4x4 {
            constexpr float eps = 0.2f;
            float hL = Terrain::Height(cx-eps,cz), hR = Terrain::Height(cx+eps,cz);
            float hD = Terrain::Height(cx,cz-eps), hU = Terrain::Height(cx,cz+eps);
            simd_float3 N = simd_normalize(simd_make_float3((hL-hR)/(2*eps), 1.f, (hD-hU)/(2*eps)));
            // Gram-Schmidt tangent: start from world X (or Z if N is near X)
            simd_float3 ref = (fabsf(N.x) < 0.9f) ? simd_make_float3(1,0,0) : simd_make_float3(0,0,1);
            simd_float3 T   = simd_normalize(ref - N * simd_dot(ref, N));
            simd_float3 B   = simd_cross(N, T);
            return (simd_float4x4){{
                simd_make_float4(T.x*r, T.y*r, T.z*r, 0),
                simd_make_float4(N.x,   N.y,   N.z,   0),
                simd_make_float4(B.x*r, B.y*r, B.z*r, 0),
                simd_make_float4(cx, cy, cz, 1)
            }};
        };

        for (uint32_t i = 0; i < scene.unitCount && shadowCount < (uint32_t)MetalRendererImpl::kMaxInstances; ++i) {
            const auto& u = scene.units[i];
            auto& inst = sd[shadowCount++];
            inst.model    = tiltedDisc(u.position.x, u.position.y + 0.02f, u.position.z, u.shadowRadius);
            inst.tint     = simd_make_float3(0.15f, 0.15f, 0.15f);
            inst.selected = 0.0f;
        }
        for (uint32_t i = 0; i < scene.shadowDiscCount && shadowCount < (uint32_t)MetalRendererImpl::kMaxInstances; ++i) {
            const auto& disc = scene.shadowDiscs[i];
            auto& inst = sd[shadowCount++];
            inst.model    = tiltedDisc(disc.position.x, disc.position.y + 0.02f, disc.position.z, disc.radius);
            float g       = 0.15f * disc.visibility; // fades toward black for enemies exiting aura
            inst.tint     = simd_make_float3(g, g, g);
            inst.selected = 0.0f;
        }
        if (shadowCount > 0) {
            [enc setDepthStencilState:d.dssNoWrite];
            [enc setRenderPipelineState:d.psoCursor];
            [enc setVertexBuffer:d.discVertexBuf offset:0 atIndex:0];
            [enc setVertexBuffer:d.uniformBuf    offset:0 atIndex:1];
            [enc setVertexBuffer:d.shadowInstBuf offset:0 atIndex:2];
            [enc setFragmentBuffer:d.uniformBuf  offset:0 atIndex:1];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:d.discIndexCount
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:d.discIndexBuf
                     indexBufferOffset:0
                         instanceCount:shadowCount];
            d.drawCallCount++;
            [enc setDepthStencilState:d.dssDefault];
        }
    }

    // ─── Selection rings (alpha-blended, drawn on top of shadows) ────────────
    if (scene.selectionRingCount > 0 && d.psoSelectionRing && d.selRingVertBuf && d.selRingIdxBuf) {
        constexpr int   kSegs       = MetalRendererImpl::kSelRingSegs;
        constexpr float kOuterR[3]  = { 0.25f, 0.43f, 0.63f };
        constexpr float kInnerR[3]  = { 0.13f, 0.31f, 0.49f };
        constexpr float kAlphaIn[3] = { 0.00f, 0.15f, 0.30f };
        constexpr float kAlphaOut[3]= { 0.30f, 0.60f, 1.00f };
        constexpr float kRingY      = 0.030f;  // slightly above shadow (0.02f)

        auto* rv  = (RingGpuVertex*)d.selRingVertBuf.contents;
        auto* ri  = (uint16_t*)d.selRingIdxBuf.contents;
        uint32_t totalVerts = 0, totalIdx = 0;

        for (uint32_t u = 0; u < scene.selectionRingCount; ++u) {
            const auto& rd = scene.selectionRings[u];
            float cr = rd.color.x, cg = rd.color.y, cb = rd.color.z;
            for (int r = 0; r < 3; ++r) {
                uint32_t vBase = totalVerts;
                for (int s = 0; s < kSegs; ++s) {
                    float theta  = 2.0f * (float)M_PI * s / kSegs;
                    float localT = theta - rd.rotAngle[r];  // wave rotates with ring
                    float innerR = kInnerR[r];
                    for (int h = 0; h < 4; ++h)
                        innerR += rd.waves[r][h].amp * sinf(rd.waves[r][h].freq * localT + rd.waves[r][h].phase);
                    innerR = fmaxf(0.04f, innerR);  // clamp: never inverted

                    float cosT = cosf(theta), sinT = sinf(theta);
                    float ox = rd.center.x + kOuterR[r] * cosT, oz = rd.center.z + kOuterR[r] * sinT;
                    float ix = rd.center.x + innerR     * cosT, iz = rd.center.z + innerR     * sinT;
                    rv[vBase + s] = { ox, Terrain::Height(ox, oz) + kRingY, oz,
                                      cr, cg, cb, kAlphaOut[r] };
                    rv[vBase + kSegs + s] = { ix, Terrain::Height(ix, iz) + kRingY, iz,
                                              cr, cg, cb, kAlphaIn[r] };
                }
                totalVerts += kSegs * 2;

                for (int s = 0; s < kSegs; ++s) {
                    int s1 = (s + 1) % kSegs;
                    auto out0 = (uint16_t)(vBase + s),        out1 = (uint16_t)(vBase + s1);
                    auto in0  = (uint16_t)(vBase + kSegs + s),in1  = (uint16_t)(vBase + kSegs + s1);
                    ri[totalIdx++] = out0; ri[totalIdx++] = in0;  ri[totalIdx++] = out1;
                    ri[totalIdx++] = out1; ri[totalIdx++] = in0;  ri[totalIdx++] = in1;
                }
            }
        }

        if (totalIdx > 0) {
            // dssAlways (no depth test): ground indicators must show through tall
            // grass, which writes depth. Units are drawn after, so they still occlude.
            [enc setDepthStencilState:d.dssAlways];
            [enc setCullMode:MTLCullModeNone];
            [enc setRenderPipelineState:d.psoSelectionRing];
            [enc setVertexBuffer:d.selRingVertBuf offset:0 atIndex:0];
            [enc setVertexBuffer:d.uniformBuf     offset:0 atIndex:1];
            [enc setFragmentBuffer:d.uniformBuf   offset:0 atIndex:1];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:totalIdx
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:d.selRingIdxBuf
                     indexBufferOffset:0];
            d.drawCallCount++;
            [enc setCullMode:MTLCullModeBack];
            [enc setDepthStencilState:d.dssDefault];
        }
    }

    // ─── Debug radius rings (yellow dotted outlines, toggled with D) ─────────
    if (scene.debugRingCount > 0 && d.psoSelectionRing && d.dbgRingVertBuf && d.dbgRingIdxBuf) {
        constexpr int   kDots  = MetalRendererImpl::kDbgDotSegs;
        constexpr float kDotW  = 0.040f;   // tangential half-width of each dot
        constexpr float kDotH  = 0.018f;   // radial half-height of each dot
        constexpr float kY     = 0.032f;
        constexpr float kYR = 1.0f, kYG = 0.9f, kYB = 0.0f, kYA = 0.75f; // yellow

        auto* dv = (RingGpuVertex*)d.dbgRingVertBuf.contents;
        auto* di = (uint16_t*)d.dbgRingIdxBuf.contents;
        uint32_t tv = 0, ti = 0;

        for (uint32_t ri = 0; ri < scene.debugRingCount; ++ri) {
            const auto& dr = scene.debugRings[ri];
            float cx = dr.center.x + dr.offset.x;
            float cz = dr.center.z + dr.offset.z;
            for (int s = 0; s < kDots; ++s) {
                // Skip every other segment to create dotted appearance
                if (s & 1) continue;
                float theta  = 2.0f * (float)M_PI * s / kDots;
                float thetaH = 2.0f * (float)M_PI * (s + 0.45f) / kDots; // half-step for width
                float cosT = cosf(theta), sinT = sinf(theta);
                // Tangent direction at this angle
                float tanX = -sinT, tanZ = cosT;
                float vBase = tv;
                // Four corners of the dot (a flat quad on the ground plane)
                float r0 = dr.radius - kDotH, r1 = dr.radius + kDotH;
                // Sample terrain Y at each corner of the dot quad
                auto dY = [&](float vx, float vz){ return Terrain::Height(vx, vz) + kY; };
                float vx0i = cx + cosT*r0 - tanX*kDotW, vz0i = cz + sinT*r0 - tanZ*kDotW;
                float vx1i = cx + cosT*r1 - tanX*kDotW, vz1i = cz + sinT*r1 - tanZ*kDotW;
                float vx1o = cx + cosT*r1 + tanX*kDotW, vz1o = cz + sinT*r1 + tanZ*kDotW;
                float vx0o = cx + cosT*r0 + tanX*kDotW, vz0o = cz + sinT*r0 + tanZ*kDotW;
                dv[tv++] = { vx0i, dY(vx0i,vz0i), vz0i, kYR,kYG,kYB,kYA };
                dv[tv++] = { vx1i, dY(vx1i,vz1i), vz1i, kYR,kYG,kYB,kYA };
                dv[tv++] = { vx1o, dY(vx1o,vz1o), vz1o, kYR,kYG,kYB,kYA };
                dv[tv++] = { vx0o, dY(vx0o,vz0o), vz0o, kYR,kYG,kYB,kYA };
                auto b = (uint16_t)vBase;
                di[ti++]=b; di[ti++]=b+1; di[ti++]=b+2;
                di[ti++]=b; di[ti++]=b+2; di[ti++]=b+3;
                (void)thetaH;
            }
        }

        if (ti > 0) {
            [enc setDepthStencilState:d.dssAlways];  // show through tall grass (see selection rings)
            [enc setCullMode:MTLCullModeNone];
            [enc setRenderPipelineState:d.psoSelectionRing];  // reuse same alpha-blended ring PSO
            [enc setVertexBuffer:d.dbgRingVertBuf offset:0 atIndex:0];
            [enc setVertexBuffer:d.uniformBuf     offset:0 atIndex:1];
            [enc setFragmentBuffer:d.uniformBuf   offset:0 atIndex:1];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:ti
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:d.dbgRingIdxBuf
                     indexBufferOffset:0];
            d.drawCallCount++;
            [enc setCullMode:MTLCullModeBack];
            [enc setDepthStencilState:d.dssDefault];
        }
    }

    // ─── Cursor rings (3 spinning square-wave rings projected onto terrain) ───
    if (scene.cursor.visible && d.psoSelectionRing && d.cursorRingVertBuf && d.cursorRingIdxBuf) {
        // Advance rotation
        d.cursorRingAngle[0] += 0.90f * d.lastDt;
        d.cursorRingAngle[1] -= 0.65f * d.lastDt;
        d.cursorRingAngle[2] += 0.40f * d.lastDt;

        // Ring geometry constants — 3× the original cursor disc radius (0.25 → 0.75 outer)
        constexpr float kCOuterR[3]  = { 0.35f, 0.55f, 0.75f };
        constexpr float kCInnerR[3]  = { 0.20f, 0.38f, 0.56f };
        constexpr float kAlphaIn[3]  = { 0.00f, 0.15f, 0.30f };
        constexpr float kAlphaOut[3] = { 0.30f, 0.60f, 1.00f };
        constexpr float kRingY       = 0.032f;
        const int kSegs = MetalRendererImpl::kCursorRingSegs;

        // Square-wave harmonic parameters per ring [ring][harmonic]
        struct CWave { float amp, freq, phase; };
        static constexpr CWave kWaves[3][4] = {
            {{ 0.025f, 4.f, 0.00f }, { 0.012f,  8.f, 1.10f }, { 0.008f, 12.f, 2.30f }, { 0.005f, 16.f, 0.70f }},
            {{ 0.030f, 3.f, 0.50f }, { 0.015f,  6.f, 2.10f }, { 0.010f,  9.f, 3.30f }, { 0.007f, 12.f, 1.40f }},
            {{ 0.035f, 5.f, 1.20f }, { 0.018f, 10.f, 0.80f }, { 0.012f, 15.f, 2.70f }, { 0.008f, 20.f, 3.90f }},
        };

        const float cx    = scene.cursor.worldPos.x;
        const float cz    = scene.cursor.worldPos.z;
        const float cr    = scene.cursor.color.x;
        const float cg    = scene.cursor.color.y;
        const float cb    = scene.cursor.color.z;
        const float growR = scene.cursor.selectorRadius;

        auto* rv  = (RingGpuVertex*)d.cursorRingVertBuf.contents;
        auto* ri  = (uint16_t*)d.cursorRingIdxBuf.contents;
        uint32_t totalVerts = 0, totalIdx = 0;

        for (int r = 0; r < 3; ++r) {
            uint32_t vBase = totalVerts;
            for (int s = 0; s < kSegs; ++s) {
                float theta  = 2.0f * (float)M_PI * s / kSegs;
                float localT = theta - d.cursorRingAngle[r];
                float innerR = kCInnerR[r] + growR;
                for (int h = 0; h < 4; ++h) {
                    // Square wave: sign(sin(freq*t + phase)) * amp
                    float sq = (sinf(kWaves[r][h].freq * localT + kWaves[r][h].phase) >= 0.f) ? 1.f : -1.f;
                    innerR += kWaves[r][h].amp * sq;
                }
                innerR = fmaxf(0.04f, innerR);

                float outerR = kCOuterR[r] + growR;
                float cosT = cosf(theta), sinT = sinf(theta);
                float ox = cx + outerR * cosT, oz = cz + outerR * sinT;
                float ix = cx + innerR * cosT, iz = cz + innerR * sinT;
                rv[vBase + s]         = { ox, Terrain::Height(ox, oz) + kRingY, oz, cr, cg, cb, kAlphaOut[r] };
                rv[vBase + kSegs + s] = { ix, Terrain::Height(ix, iz) + kRingY, iz, cr, cg, cb, kAlphaIn[r]  };
            }
            totalVerts += kSegs * 2;

            for (int s = 0; s < kSegs; ++s) {
                int s1 = (s + 1) % kSegs;
                auto out0 = (uint16_t)(vBase + s),         out1 = (uint16_t)(vBase + s1);
                auto in0  = (uint16_t)(vBase + kSegs + s), in1  = (uint16_t)(vBase + kSegs + s1);
                ri[totalIdx++] = out0; ri[totalIdx++] = in0;  ri[totalIdx++] = out1;
                ri[totalIdx++] = out1; ri[totalIdx++] = in0;  ri[totalIdx++] = in1;
            }
        }

        [enc setDepthStencilState:d.dssAlways];  // show through tall grass (see selection rings)
        [enc setCullMode:MTLCullModeNone];
        [enc setRenderPipelineState:d.psoSelectionRing];
        [enc setVertexBuffer:d.cursorRingVertBuf offset:0 atIndex:0];
        [enc setVertexBuffer:d.uniformBuf        offset:0 atIndex:1];
        [enc setFragmentBuffer:d.uniformBuf      offset:0 atIndex:1];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:(NSUInteger)totalIdx
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:d.cursorRingIdxBuf
                 indexBufferOffset:0];
        d.drawCallCount++;
        [enc setDepthStencilState:d.dssDefault];
    }

    // ─── Units (instanced) ────────────────────────────────────────────────
    [enc setRenderPipelineState:d.psoUnit];
    [enc setVertexBuffer:d.unitVertexBuf  offset:0 atIndex:0];
    [enc setVertexBuffer:d.uniformBuf     offset:0 atIndex:1];
    [enc setFragmentBuffer:d.uniformBuf   offset:0 atIndex:1];

    const float kHoverHeight = 1.5f;
    uint32_t unitInstCount = 0;
    for (uint32_t i = 0; i < scene.unitCount && unitInstCount < (uint32_t)MetalRendererImpl::kMaxInstances; ++i) {
        const auto& u = scene.units[i];
        auto& inst = instData[unitInstCount++];
        float s = u.scale;
        inst.model = {{
            simd_make_float4(s, 0, 0, 0),
            simd_make_float4(0, s, 0, 0),
            simd_make_float4(0, 0, s, 0),
            simd_make_float4(u.position.x, u.position.y + kHoverHeight, u.position.z, 1)
        }};
        inst.tint     = simd_make_float3(u.tint.x, u.tint.y, u.tint.z);
        inst.selected = u.selected ? 1.0f : 0.0f;
    }
    if (unitInstCount > 0) {
        [enc setVertexBuffer:d.instanceBuf offset:0 atIndex:2];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:d.unitIndexCount
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:d.unitIndexBuf
                 indexBufferOffset:0
                     instanceCount:unitInstCount];
        d.drawCallCount++;
    }

    // ─── Props (instanced, same mesh) ─────────────────────────────────────
    auto* propData = (GpuInstanceData*)d.propInstBuf.contents;
    uint32_t propInstCount = 0;
    for (uint32_t i = 0; i < scene.propCount && propInstCount < (uint32_t)MetalRendererImpl::kMaxInstances; ++i) {
        const auto& p = scene.props[i];
        auto& inst = propData[propInstCount++];
        float s = p.scale;
        inst.model = {{
            simd_make_float4(s, 0, 0, 0),
            simd_make_float4(0, s, 0, 0),
            simd_make_float4(0, 0, s, 0),
            simd_make_float4(p.position.x, p.position.y, p.position.z, 1)
        }};
        inst.tint     = simd_make_float3(p.tint.x, p.tint.y, p.tint.z);
        inst.selected = 0.0f;
    }
    if (propInstCount > 0) {
        [enc setVertexBuffer:d.propInstBuf offset:0 atIndex:2];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:d.unitIndexCount
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:d.unitIndexBuf
                 indexBufferOffset:0
                     instanceCount:propInstCount];
        d.drawCallCount++;
    }

    // ─── Tree trunks (procedural bark; regenerated on T-panel change) ─────
    if (TreeParamsChanged(scene.tree, d.lastTree))
        ScatterTrunks(d, d.device, scene.tree);
    if (scene.tree.visible && d.trunkInstBuf && !d.trunks.empty()) {
        auto* td = (GpuInstanceData*)d.trunkInstBuf.contents;
        for (size_t t = 0; t < d.trunks.size(); ++t) {
            const auto& tr = d.trunks[t];
            simd_float4x4 m = tr.model;                 // precomputed rot·scale, xz baked
            m.columns[3].y  = Terrain::Height(tr.x, tr.z);  // sit on the terrain
            td[t].model     = m;
            td[t].tint      = tr.tint;
            td[t].selected  = 0.0f;
        }
        [enc setRenderPipelineState:d.psoTrunk];
        [enc setCullMode:MTLCullModeNone];          // trunk shell is single-sided
        [enc setVertexBuffer:d.trunkVertexBuf offset:0 atIndex:0];
        [enc setVertexBuffer:d.trunkInstBuf   offset:0 atIndex:2];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:d.trunkIndexCount
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:d.trunkIndexBuf
                 indexBufferOffset:0
                     instanceCount:(uint32_t)d.trunks.size()];
        [enc setCullMode:MTLCullModeBack];
        [enc setRenderPipelineState:d.psoUnit];     // restore for following passes
        d.drawCallCount++;
    }

    // ─── Pull-node marker (green sphere) ──────────────────────────────────
    if (scene.tree.pullActive) {
        auto* md = (GpuInstanceData*)d.pullInstBuf.contents;
        float y = Terrain::Height(scene.tree.pullX, scene.tree.pullZ) + 0.5f;
        float s = 0.5f;
        md[0].model = {{
            simd_make_float4(s, 0, 0, 0), simd_make_float4(0, s, 0, 0),
            simd_make_float4(0, 0, s, 0),
            simd_make_float4(scene.tree.pullX, y, scene.tree.pullZ, 1)
        }};
        md[0].tint     = simd_make_float3(0.1f, 1.0f, 0.25f);   // bright green
        md[0].selected = 0.0f;
        [enc setVertexBuffer:d.sphereVertexBuf offset:0 atIndex:0];
        [enc setVertexBuffer:d.pullInstBuf     offset:0 atIndex:2];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:d.sphereIndexCount
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:d.sphereIndexBuf
                 indexBufferOffset:0
                     instanceCount:1];
        d.drawCallCount++;
    }

    // ─── Projectiles (sphere mesh, instanced) ─────────────────────────────
    [enc setVertexBuffer:d.sphereVertexBuf offset:0 atIndex:0];
    auto* projData = (GpuInstanceData*)d.projInstBuf.contents;
    uint32_t projInstCount = 0;
    for (uint32_t i = 0; i < scene.projectileCount && projInstCount < (uint32_t)MetalRendererImpl::kMaxInstances; ++i) {
        const auto& p = scene.projectiles[i];
        auto& inst = projData[projInstCount++];
        float s = p.radius;
        inst.model = {{
            simd_make_float4(s, 0, 0, 0),
            simd_make_float4(0, s, 0, 0),
            simd_make_float4(0, 0, s, 0),
            simd_make_float4(p.position.x, p.position.y, p.position.z, 1)
        }};
        inst.tint     = simd_make_float3(p.tint.x, p.tint.y, p.tint.z);
        inst.selected = 0.0f;
    }
    if (projInstCount > 0) {
        [enc setVertexBuffer:d.projInstBuf offset:0 atIndex:2];
        [enc setFragmentBuffer:d.uniformBuf offset:0 atIndex:1];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:d.sphereIndexCount
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:d.sphereIndexBuf
                 indexBufferOffset:0
                     instanceCount:projInstCount];
        d.drawCallCount++;
    }

    // ─── Skinned characters on shadow discs ──────────────────────────────────
    if (d.soldier.loaded && d.psoSkinned && d.boneBuf &&
        d.idleClipIdx >= 0 && d.walkClipIdx >= 0 && scene.shadowDiscCount > 0) {
        const auto& m          = d.soldier;
        const auto& idleClip   = m.clips[(size_t)d.idleClipIdx];
        const auto& walkClip   = m.clips[(size_t)d.walkClipIdx];
        auto* boneData         = (simd_float4x4*)d.boneBuf.contents;
        auto* charInstData     = (GpuInstanceData*)d.charInstBuf.contents;
        uint32_t discCount     = std::min(scene.shadowDiscCount, RenderScene::kMaxShadowDiscs);
        float dt               = d.lastDt;

        // On first frame, seed facing toward origin (matches the old static behaviour).
        if (!d.charYawInited) {
            for (uint32_t j = 0; j < discCount; ++j) {
                float initYaw = atan2f(scene.shadowDiscs[j].position.x,
                                       scene.shadowDiscs[j].position.z) + (float)M_PI;
                d.charCurrentYaw[j] = initYaw;
                d.charTargetYaw[j]  = initYaw;
            }
            d.charYawInited = true;
        }

        for (uint32_t i = 0; i < discCount; ++i) {
            const auto& disc = scene.shadowDiscs[i];

            // Update commanded facing target the instant a move order is issued.
            if (disc.hasFacing)
                d.charTargetYaw[i] = disc.facingYaw;

            // Smooth-rotate current yaw toward target at ~5 rad/sec (~286 deg/sec).
            float yawErr = d.charTargetYaw[i] - d.charCurrentYaw[i];
            while (yawErr >  (float)M_PI) yawErr -= 2.0f * (float)M_PI;
            while (yawErr < -(float)M_PI) yawErr += 2.0f * (float)M_PI;
            float maxTurn = 5.0f * dt;
            if (fabsf(yawErr) <= maxTurn)
                d.charCurrentYaw[i] = d.charTargetYaw[i];
            else
                d.charCurrentYaw[i] += (yawErr > 0.0f ? maxTurn : -maxTurn);

            // Speed from kinematic velocity (accurate; no position-delta noise).
            float vx = disc.velocity.x, vz = disc.velocity.z;
            float speed = sqrtf(vx*vx + vz*vz);
            constexpr float kFullWalkSpeed = 4.0f;
            float animScale = fminf(speed / kFullWalkSpeed, 1.0f);

            // Gate walk animation on facing alignment: only walk once the character
            // is roughly pointing in the direction it is moving (cosine gate).
            if (animScale > 0.001f) {
                // Model faces local -Z; matrix yaw controls +Z, so visual facing = charCurrentYaw + π.
                float velYaw    = atan2f(vx, vz);
                float facingErr = velYaw - d.charCurrentYaw[i] - (float)M_PI;
                while (facingErr >  (float)M_PI) facingErr -= 2.0f * (float)M_PI;
                while (facingErr < -(float)M_PI) facingErr += 2.0f * (float)M_PI;
                animScale *= fmaxf(0.0f, cosf(facingErr));
            }

            // Walk clock only advances while facing the movement direction.
            d.charWalkTime[i] += dt * animScale;
            // Idle clock always ticks so the idle animation plays continuously.
            d.charIdleTime[i] += dt;

            // Blend 0=walk, 1=idle; cross-fade at 6x/sec.
            float blendTarget = (animScale < 0.02f) ? 1.0f : 0.0f;
            d.charBlend[i] += (blendTarget - d.charBlend[i]) * fminf(dt * 6.0f, 1.0f);
            float blend = d.charBlend[i];

            // Bone matrices from the glTF Idle/Walk clips, cross-faded by `blend`.
            // (Procedural retarget shelved 2026-06-24 — the branch that consumed
            // scene.skinnedBoneRot via ComputeRetargetedBoneMatrices is disabled below;
            // re-enable it together with the EngineHost procedural block to bring it back.)
            simd_float4x4* outBones = boneData + i * kMaxJoints;
#if 0       // procedural retarget path — disabled
            if (scene.skinnedBoneRot && i < scene.skinnedUnitCount &&
                m.retargetMappedCount >= 6) {
                const simd_quatf* deltas =
                    (const simd_quatf*)scene.skinnedBoneRot + scene.skinnedUnits[i].boneOffset;
                ComputeRetargetedBoneMatrices(m, deltas, outBones);
            } else
#endif
            if (blend < 0.001f) {
                ComputeBoneMatrices(m, walkClip, d.charWalkTime[i], outBones);
            } else if (blend > 0.999f) {
                ComputeBoneMatrices(m, idleClip, d.charIdleTime[i], outBones);
            } else {
                simd_float4x4 walkBones[kMaxJoints];
                ComputeBoneMatrices(m, walkClip, d.charWalkTime[i], walkBones);
                ComputeBoneMatrices(m, idleClip, d.charIdleTime[i], outBones);
                for (uint32_t j = 0; j < m.jointCount; ++j)
                    outBones[j] = LerpMat4x4(walkBones[j], outBones[j], blend);
            }

            float yaw = d.charCurrentYaw[i];
            float C = cosf(yaw), S = sinf(yaw), s = m.scale;
            auto& inst = charInstData[i];
            inst.model = {{
                simd_make_float4( C*s, 0, -S*s, 0),
                simd_make_float4( 0,   s,  0,   0),
                simd_make_float4( S*s, 0,  C*s, 0),
                simd_make_float4(disc.position.x, disc.position.y, disc.position.z, 1)
            }};
            inst.tint     = disc.hasColorOverride
                          ? simd_make_float3(disc.colorOverride.x, disc.colorOverride.y, disc.colorOverride.z)
                          : (disc.playerSlot == 0)
                              ? simd_make_float3(1.0f, 0.15f, 0.15f)   // enemy — red
                              : simd_make_float3(0.3f, 0.55f, 1.0f);   // ally  — blue
            // Enemies: pack visibility as negative selected so unitFS can use it as alpha.
            // Friendlies: normal selected flag (enemies are never selectable).
            inst.selected = (disc.playerSlot == 0)
                          ? -disc.visibility
                          : (disc.selected ? 1.0f : 0.0f);
        }

        [enc setRenderPipelineState:d.psoSkinned];
        [enc setVertexBuffer:d.soldier.vertexBuf offset:0 atIndex:0];
        [enc setVertexBuffer:d.uniformBuf        offset:0 atIndex:1];
        [enc setVertexBuffer:d.charInstBuf       offset:0 atIndex:2];
        [enc setVertexBuffer:d.boneBuf           offset:0 atIndex:3];
        [enc setFragmentBuffer:d.uniformBuf      offset:0 atIndex:1];
        MTLIndexType idxType = d.soldier.indexU32
            ? MTLIndexTypeUInt32 : MTLIndexTypeUInt16;
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:d.soldier.indexCount
                         indexType:idxType
                       indexBuffer:d.soldier.indexBuf
                 indexBufferOffset:0
                     instanceCount:discCount];
        d.drawCallCount++;
    }

    // ─── Throw-cooldown indicator (red sphere above soldier's head) ──────────
    {
        uint32_t dotCount = 0;
        auto* dotInstData = (GpuInstanceData*)d.dotInstBuf.contents;
        for (uint32_t i = 0; i < std::min(scene.shadowDiscCount, RenderScene::kMaxShadowDiscs); ++i) {
            const auto& disc = scene.shadowDiscs[i];
            if (!disc.onThrowCooldown) continue;
            if (dotCount >= RenderScene::kMaxShadowDiscs) break;
            auto& inst = dotInstData[dotCount++];
            constexpr float kDotRadius = 0.12f;
            constexpr float kDotHeight = 2.25f;
            inst.model = {{
                simd_make_float4(kDotRadius, 0, 0, 0),
                simd_make_float4(0, kDotRadius, 0, 0),
                simd_make_float4(0, 0, kDotRadius, 0),
                simd_make_float4(disc.position.x, kDotHeight, disc.position.z, 1)
            }};
            inst.tint     = simd_make_float3(1.0f, 0.08f, 0.08f);
            inst.selected = 0.0f;
        }
        if (dotCount > 0) {
            [enc setRenderPipelineState:d.psoProjectile];
            [enc setVertexBuffer:d.sphereVertexBuf offset:0 atIndex:0];
            [enc setVertexBuffer:d.dotInstBuf      offset:0 atIndex:2];
            [enc setFragmentBuffer:d.uniformBuf    offset:0 atIndex:1];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:d.sphereIndexCount
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:d.sphereIndexBuf
                     indexBufferOffset:0
                         instanceCount:dotCount];
            d.drawCallCount++;
        }
    }

    // ─── Follow-radius ring ───────────────────────────────────────────────────
    if (scene.followRingCount > 0 && d.ringInstBuf) {
        constexpr int   kRingSegs = 64;
        constexpr float kRadScale = 0.055f;
        constexpr float kYScale   = 0.025f;

        auto* rd = (GpuInstanceData*)d.ringInstBuf.contents;
        int totalBeads = 0;
        for (int ri = 0; ri < scene.followRingCount; ++ri) {
            const auto& fr = scene.followRings[ri];
            const float R  = fr.radius;
            const float cx = fr.center.x, cz = fr.center.z;
            const float tScale = fmaxf(0.15f, (float)M_PI * R / kRingSegs * 1.1f);
            for (int i = 0; i < kRingSegs; ++i) {
                float theta = 2.0f * (float)M_PI * i / kRingSegs;
                float cosT  = cosf(theta), sinT = sinf(theta);
                float bx = cx + cosT * R, bz = cz + sinT * R;
                float by = Terrain::Height(bx, bz) + 0.015f;
                auto& inst = rd[totalBeads++];
                inst.model = {{
                    simd_make_float4( cosT * kRadScale, 0, sinT * kRadScale, 0),
                    simd_make_float4( 0,                kYScale, 0,          0),
                    simd_make_float4(-sinT * tScale,    0, cosT * tScale,    0),
                    simd_make_float4(bx, by, bz, 1)
                }};
                inst.tint     = simd_make_float3(0.0f, 0.85f, 1.0f);  // cyan
                inst.selected = 0.0f;
            }
        }
        [enc setDepthStencilState:d.dssAlways];  // standoff beads must show through tall grass
        [enc setRenderPipelineState:d.psoProjectile];
        [enc setVertexBuffer:d.sphereVertexBuf offset:0 atIndex:0];
        [enc setVertexBuffer:d.uniformBuf      offset:0 atIndex:1];
        [enc setVertexBuffer:d.ringInstBuf     offset:0 atIndex:2];
        [enc setFragmentBuffer:d.uniformBuf    offset:0 atIndex:1];
        [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                        indexCount:d.sphereIndexCount
                         indexType:MTLIndexTypeUInt16
                       indexBuffer:d.sphereIndexBuf
                 indexBufferOffset:0
                     instanceCount:(NSUInteger)totalBeads];
        d.drawCallCount++;
        [enc setDepthStencilState:d.dssDefault];
    }

    // ─── Explosions (alpha-blended expanding disc) ────────────────────────────
    if (scene.explosionCount > 0 && d.psoExplosion && d.explosionInstBuf) {
        auto* exData = (GpuInstanceData*)d.explosionInstBuf.contents;
        uint32_t exCount = 0;
        for (uint32_t i = 0; i < scene.explosionCount && exCount < (uint32_t)MetalRendererImpl::kMaxInstances; ++i) {
            const auto& ex = scene.explosions[i];
            auto& inst = exData[exCount++];
            float r = ex.radius;
            inst.model = {{
                simd_make_float4(r, 0, 0, 0),
                simd_make_float4(0, r, 0, 0),
                simd_make_float4(0, 0, r, 0),
                simd_make_float4(ex.position.x, ex.position.y, ex.position.z, 1)
            }};
            inst.tint     = simd_make_float3(1.0f, 0.45f, 0.05f); // orange-red
            inst.selected = ex.alpha;  // passed as alpha in explosionFS
        }
        if (exCount > 0) {
            [enc setDepthStencilState:d.dssNoWrite];
            [enc setRenderPipelineState:d.psoExplosion];
            [enc setVertexBuffer:d.sphereVertexBuf   offset:0 atIndex:0];
            [enc setVertexBuffer:d.uniformBuf        offset:0 atIndex:1];
            [enc setVertexBuffer:d.explosionInstBuf  offset:0 atIndex:2];
            [enc setFragmentBuffer:d.uniformBuf      offset:0 atIndex:1];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:d.sphereIndexCount
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:d.sphereIndexBuf
                     indexBufferOffset:0
                         instanceCount:exCount];
            d.drawCallCount++;
            [enc setDepthStencilState:d.dssDefault];
        }
    }

    // ─── Mesh rebuild from saved heightfield (load path, runs outside D-mode) ───
    // Builds a smooth grid over the active (possibly enlarged) extent sampling Terrain::Height;
    // 32-bit indices since the grid may exceed 65k verts when the plane is enlarged.
    if (scene.requestMeshRebuild) {
        if (d.heightFieldBuf)
            memcpy([d.heightFieldBuf contents], Terrain::gHeightField,
                   sizeof(Terrain::gHeightField));
        d.worldScale = Terrain::gWorldScale;
        const int   N    = Terrain::gHFDivs, strd = N + 1;
        const float ext  = Terrain::gHFExtent(), cell = 2.f * ext / N;
        std::vector<GpuVertex> gv((size_t)strd*strd);
        for (int zi = 0; zi <= N; ++zi)
            for (int xi = 0; xi <= N; ++xi) {
                float x = -ext + xi*cell, z = -ext + zi*cell;
                GpuVertex& v = gv[(size_t)zi*strd+xi];
                v.position = simd_make_float3(x, Terrain::Height(x, z), z);
                v.normal   = simd_make_float3(0,1,0);
                v.uv       = simd_make_float2((float)xi/N, (float)zi/N);
            }
        for (int zi = 0; zi <= N; ++zi)
            for (int xi = 0; xi <= N; ++xi) {
                int x0=(xi>0)?xi-1:xi, x1=(xi<N)?xi+1:xi, z0=(zi>0)?zi-1:zi, z1=(zi<N)?zi+1:zi;
                float hL=gv[(size_t)zi*strd+x0].position.y, hR=gv[(size_t)zi*strd+x1].position.y;
                float hD=gv[(size_t)z0*strd+xi].position.y, hU=gv[(size_t)z1*strd+xi].position.y;
                float dhdx=(hR-hL)/((float)(x1-x0)*cell), dhdz=(hU-hD)/((float)(z1-z0)*cell);
                gv[(size_t)zi*strd+xi].normal = simd_normalize(simd_make_float3(-dhdx,1.f,-dhdz));
            }
        std::vector<uint32_t> gi; gi.reserve((size_t)N*N*6);
        for (int zi = 0; zi < N; ++zi)
            for (int xi = 0; xi < N; ++xi) {
                uint32_t a=(uint32_t)(zi*strd+xi), b=a+1, c=(uint32_t)((zi+1)*strd+xi), e=c+1;
                gi.insert(gi.end(), { a, c, b, b, c, e });
            }
        d.groundVertexBuf = [d.device newBufferWithBytes:gv.data()
                                                  length:gv.size() * sizeof(GpuVertex)
                                                 options:MTLResourceStorageModeShared];
        d.groundIndexBuf  = [d.device newBufferWithBytes:gi.data()
                                                  length:gi.size() * sizeof(uint32_t)
                                                 options:MTLResourceStorageModeShared];
        d.groundIndexCount = (uint32_t)gi.size();
        d.groundIndexType  = MTLIndexTypeUInt32;
    }

    // ─── Terrain construction editor (visible in D mode) ─────────────────────
    if (scene.dModeActive) {
        // GENERATE: apply construction plane to the real terrain heightfield, then
        // rebuild the ground mesh (which samples Terrain::Height) to reflect it.
        if (scene.requestGenerate) {
            d.heightSourceNoise = false;   // node-based: clear any procedural state
            d.worldScale        = 1.0f;
            GenerateTerrainMesh(d, scene.erosionStep, scene.erosionHeight, scene.erosionAngle);
        }

        // PRESET: apply a terrain preset (sets nodes / procedural noise, then generates).
        if (scene.requestPreset >= 0) {
            ApplyTerrainPreset(d, scene.requestPreset, scene.erosionStep, scene.erosionHeight,
                               scene.erosionAngle, scene.groundScale);
        }

        // Auto-node grid: regenerate when the toggle flips, or when density changes
        // while enabled. Removing the toggle clears the auto nodes again.
        if (scene.autoNode != d.prevAutoNode ||
            (scene.autoNode && scene.autoNodeDensity != d.prevAutoNodeDensity)) {
            RegenerateAutoNodes(d, scene.autoNode, scene.autoNodeDensity);
            d.prevAutoNode        = scene.autoNode;
            d.prevAutoNodeDensity = scene.autoNodeDensity;
        }

        // Drag start: a left click grabs the nearest construction node under the cursor.
        bool startedDrag = false;
        if (scene.leftMouseJustDown && d.draggingNodeIdx < 0) {
            float ox = scene.cameraPos.x, oy = scene.cameraPos.y, oz = scene.cameraPos.z;
            float rdx = scene.cursorRayDirX, rdy = scene.cursorRayDirY, rdz = scene.cursorRayDirZ;
            float bestD2 = 1.0f;  // 1-unit miss-distance threshold around sphere center
            for (int i = 0; i < d.terrainNodeCount; ++i) {
                float sc  = d.terrainNodes[i].isCorner ? 0.55f : 0.42f;
                float px  = d.terrainNodes[i].x;
                float py  = d.terrainNodes[i].y + sc;
                float pz  = d.terrainNodes[i].z;
                float vx  = px - ox, vy = py - oy, vz = pz - oz;
                float t   = vx*rdx + vy*rdy + vz*rdz;
                float cx  = ox + t*rdx - px;
                float cy  = oy + t*rdy - py;
                float cz  = oz + t*rdz - pz;
                float d2  = cx*cx + cy*cy + cz*cz;
                if (d2 < bestD2) { bestD2 = d2; d.draggingNodeIdx = i; startedDrag = true; }
            }
        }

        // Place new node on request — skip if we started a drag on an existing node
        if (scene.requestNodePlace && !startedDrag && d.terrainNodeCount < MetalRendererImpl::kMaxTerrainNodes) {
            auto& n      = d.terrainNodes[d.terrainNodeCount++];
            n.x          = scene.terrainNodeX;
            n.y          = IDWHeight(scene.terrainNodeX, scene.terrainNodeZ,
                                     d.terrainNodes, d.terrainNodeCount - 1);
            n.z          = scene.terrainNodeZ;
            n.isCorner   = false;
            n.isAuto     = false;
            d.cpMeshDirty = true;
        }

        // Apply vertical drag (mouse up = raise) to the grabbed node.
        if (scene.leftMouseDown && d.draggingNodeIdx >= 0) {
            if (scene.mouseDeltaY != 0.0f) {
                d.terrainNodes[d.draggingNodeIdx].y -= scene.mouseDeltaY * 0.05f;
                d.cpMeshDirty = true;
            }
        } else if (!scene.leftMouseDown) {
            d.draggingNodeIdx = -1;
        }

        if (d.cpMeshDirty) UpdateCPMesh(d);

        // Render construction plane (translucent, depth-tested, no depth write)
        if (scene.constructionPlaneVisible &&
            d.psoConstructionPlane && d.cpVertexBuf && d.cpIndexCount > 0) {
            [enc setCullMode:MTLCullModeNone];
            [enc setDepthStencilState:d.dssNoWrite];
            [enc setRenderPipelineState:d.psoConstructionPlane];
            [enc setVertexBuffer:d.cpVertexBuf  offset:0 atIndex:0];
            [enc setVertexBuffer:d.uniformBuf   offset:0 atIndex:1];
            [enc setFragmentBuffer:d.uniformBuf offset:0 atIndex:1];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:d.cpIndexCount
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:d.cpIndexBuf
                     indexBufferOffset:0];
            d.drawCallCount++;
            [enc setCullMode:MTLCullModeBack];
            [enc setDepthStencilState:d.dssDefault];
        }

        // Render terrain nodes as yellow spheres
        if (d.terrainNodeCount > 0 && d.nodeInstBuf && d.psoUnit && d.sphereVertexBuf) {
            auto* instData = (GpuInstanceData*)d.nodeInstBuf.contents;
            for (int i = 0; i < d.terrainNodeCount; ++i) {
                auto& nd = d.terrainNodes[i];
                float sc = nd.isCorner ? 0.55f : 0.42f;
                instData[i].model = {{
                    simd_make_float4(sc, 0,  0,  0),
                    simd_make_float4(0,  sc, 0,  0),
                    simd_make_float4(0,  0,  sc, 0),
                    simd_make_float4(nd.x, nd.y + sc, nd.z, 1)
                }};
                instData[i].tint     = (i == d.draggingNodeIdx)
                                       ? simd_make_float3(1.0f, 1.0f, 0.35f)
                                       : simd_make_float3(0.88f, 0.70f, 0.04f);
                instData[i].selected = 0.0f;
            }
            [enc setDepthStencilState:d.dssDefault];
            [enc setRenderPipelineState:d.psoUnit];
            [enc setVertexBuffer:d.sphereVertexBuf offset:0 atIndex:0];
            [enc setVertexBuffer:d.uniformBuf      offset:0 atIndex:1];
            [enc setVertexBuffer:d.nodeInstBuf     offset:0 atIndex:2];
            [enc setFragmentBuffer:d.uniformBuf    offset:0 atIndex:1];
            [enc drawIndexedPrimitives:MTLPrimitiveTypeTriangle
                            indexCount:d.sphereIndexCount
                             indexType:MTLIndexTypeUInt16
                           indexBuffer:d.sphereIndexBuf
                     indexBufferOffset:0
                         instanceCount:(NSUInteger)d.terrainNodeCount];
            d.drawCallCount++;
        }
    }

    [enc endEncoding];
}

void MetalRenderer::EndFrame() {
    auto& d = *m_impl;
    if (!d.currentCmdBuf || !d.currentDrawable) return;

    dispatch_semaphore_t sem = d.frameSem;
    [d.currentCmdBuf addCompletedHandler:^(id<MTLCommandBuffer> cb) {
        if (@available(macOS 10.15, *)) {
            d.lastGPUTimeMs = (cb.GPUEndTime - cb.GPUStartTime) * 1000.0f;
        }
        // GPU is done with this frame's slot — let the CPU reuse it.
        dispatch_semaphore_signal(sem);
    }];

    [d.currentCmdBuf presentDrawable:d.currentDrawable];
    [d.currentCmdBuf commit];
    d.currentCmdBuf   = nil;
    d.currentDrawable = nil;
}

f32  MetalRenderer::LastGPUTimeMs() const { return m_impl->lastGPUTimeMs; }
u32  MetalRenderer::DrawCallCount()  const { return m_impl->drawCallCount; }

void* MetalRenderer::GetMTLDevice()       const { return (__bridge void*)m_impl->device; }
void* MetalRenderer::GetMTLCommandQueue() const { return (__bridge void*)m_impl->commandQueue; }
