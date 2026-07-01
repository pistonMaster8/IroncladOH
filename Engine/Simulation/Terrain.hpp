#pragma once
#include <cmath>

// Shared terrain height function — used by both GameSim and MetalRenderer.
// Returns world-space Y for a given XZ position.
//
// Zones (by Chebyshev distance from origin):
//   0..kClearSize          — flat play area
//   kClearSize..kInnerEdge — procedural splat mounds, fading to 0 near kInnerEdge
//   kInnerEdge..kOuterEdge — cliff / ramp expansion:
//       +Z face  → gentle walkable ramp (smoothstep, 0→kCliffH over 45 units)
//       -Z face  → steep back wall     (smoothstep, 0→kCliffH over kCliffFaceBack units)
//       ±X faces → shallower side walls (smoothstep, 0→kCliffH over kCliffFaceSide units)

namespace Terrain {

struct Splat { float cx, cz, r, h; };

inline constexpr Splat kSplats[] = {
    // large outer mounds
    {  28.f,  18.f, 7.0f, 3.2f }, { -25.f,  22.f, 6.5f, 2.8f },
    {  20.f, -28.f, 7.5f, 3.0f }, { -30.f, -20.f, 8.0f, 3.4f },
    {  35.f,   5.f, 6.0f, 2.5f }, { -38.f,   2.f, 7.0f, 3.1f },
    {   5.f,  38.f, 6.5f, 2.9f }, {   3.f, -40.f, 7.0f, 3.3f },
    { -18.f,  35.f, 5.5f, 2.6f }, {  22.f,  32.f, 5.0f, 2.4f },
    { -32.f,  28.f, 6.0f, 2.7f }, {  30.f, -30.f, 6.5f, 3.0f },
    { -28.f, -35.f, 7.5f, 3.2f }, {  38.f, -18.f, 5.5f, 2.5f },
    { -40.f, -10.f, 6.0f, 2.8f },
    // medium features
    {  18.f,  25.f, 4.0f, 2.2f }, { -22.f,  18.f, 4.5f, 2.0f },
    {  25.f, -18.f, 4.0f, 2.3f }, { -18.f, -25.f, 5.0f, 2.5f },
    {  16.f,  40.f, 4.5f, 2.1f }, { -38.f,  18.f, 4.0f, 2.4f },
    {  40.f,  25.f, 5.0f, 2.6f }, { -20.f, -40.f, 4.5f, 2.2f },
    // small detail bumps
    {  20.f,  20.f, 2.5f, 1.5f }, { -20.f,  20.f, 2.5f, 1.4f },
    {  20.f, -20.f, 2.5f, 1.6f }, { -20.f, -20.f, 3.0f, 1.5f },
    {  42.f,  10.f, 3.0f, 1.8f }, { -42.f, -12.f, 3.0f, 1.7f },
};
inline constexpr int kNSplats = (int)(sizeof(kSplats) / sizeof(kSplats[0]));

inline constexpr float kClearSize     = 15.0f;  // inner flat play area half-extent
inline constexpr float kBlend         =  2.5f;   // terrain fade-in width
inline constexpr float kInnerEdge     = 45.0f;   // boundary between inner terrain and cliff zone
inline constexpr float kOuterEdge     = 90.0f;   // outer map boundary
inline constexpr float kCliffH        =  5.0f;   // cliff height (plateau at this Y)
inline constexpr float kCliffFaceBack =  3.0f;   // -Z back wall: narrow = near-vertical
inline constexpr float kCliffFaceSide = 18.0f;   // ±X side walls: wide = gradual shoulder

// ─── Runtime heightfield ─────────────────────────────────────────────────────
// Populated by the in-game construction editor (D-mode → GENERATE). When active,
// Height() bilinearly samples this grid; when inactive the world is flat (0).
// Shared by renderer (ground mesh), physics, and sim via inline linkage.
inline constexpr float kHFSize     = 90.0f;   // base half-extent (world ±90 at scale 1)
inline constexpr int   kHFBaseDivs = 200;     // grid subdivisions at scale 1
inline constexpr int   kHFMaxDivs  = 800;     // cap — grid grows with the enlarged plane
inline constexpr int   kHFMaxStride= kHFMaxDivs + 1;

// Active grid: divisions and half-extent scale together with the plane so the cell size (hence
// terrace sharpness / grass detail) stays roughly constant as the ground plane is enlarged.
inline int   gHFDivs   = kHFBaseDivs;
inline float gWorldScale = 1.f;
inline int   gHFStride()  { return gHFDivs + 1; }
inline float gHFExtent()  { return kHFSize * gWorldScale; }   // active half-extent in world units

inline float gHeightField[kHFMaxStride * kHFMaxStride] = {};
inline bool  gHeightFieldActive = false;

inline float Height(float x, float z) {
    if (!gHeightFieldActive) return 0.f;

    const int   N    = gHFDivs;
    const int   strd = N + 1;
    const float ext  = gHFExtent();
    float fx = (x + ext) / (2.f * ext) * N;
    float fz = (z + ext) / (2.f * ext) * N;
    if (fx < 0.f) fx = 0.f; else if (fx > N) fx = (float)N;
    if (fz < 0.f) fz = 0.f; else if (fz > N) fz = (float)N;

    int   x0 = (int)fx, z0 = (int)fz;
    int   x1 = (x0 < N) ? x0 + 1 : x0;
    int   z1 = (z0 < N) ? z0 + 1 : z0;
    float tx = fx - (float)x0, tz = fz - (float)z0;

    float h00 = gHeightField[z0 * strd + x0];
    float h10 = gHeightField[z0 * strd + x1];
    float h01 = gHeightField[z1 * strd + x0];
    float h11 = gHeightField[z1 * strd + x1];
    float a   = h00 + (h10 - h00) * tx;
    float b   = h01 + (h11 - h01) * tx;
    return a + (b - a) * tz;
}

} // namespace Terrain
