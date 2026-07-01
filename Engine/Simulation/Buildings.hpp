#pragma once
#include "Terrain.hpp"
#include <cmath>

// Shared building data — generated once, used by both GameSim (collision) and MetalRenderer (rendering).
// Static locals in inline functions are shared across translation units (C++17 §9.7.1).

struct BuildingBox {
    float x, z;     // center XZ
    float hw, hd;   // half-extents in X and Z
    float hh;       // half-height (full height = hh*2)
    float baseY;    // terrain surface Y at center
};

inline constexpr int kBuildingMaxCount = 48;

inline int GetBuildings(const BuildingBox** out) {
    static BuildingBox s_buf[kBuildingMaxCount];
    static int s_count = -1;

    if (s_count < 0) {
        s_count = 0;
    }

    *out = s_buf;
    return s_count;
}
