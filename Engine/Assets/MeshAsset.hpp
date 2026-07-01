#pragma once
#include "AssetID.hpp"
#include "../Core/Math.hpp"
#include <vector>
#include <string>

// Engine-native cooked mesh format.
// Imported from glTF 2.0 by AssetCooker; runtime code never reads glTF.

enum class VertexFormat : u8 {
    // Position + Normal + UV — baseline for all solid meshes
    PNU         = 0,
    // Position + Normal + UV + Tangent — for normal-mapped materials
    PNUT        = 1,
};

// Axis-aligned bounding box
struct AABB {
    Vec3 min { Vec3Make(0,0,0) };
    Vec3 max { Vec3Make(0,0,0) };

    Vec3 Center() const {
        return Vec3Make((min.x+max.x)*0.5f, (min.y+max.y)*0.5f, (min.z+max.z)*0.5f);
    }
    Vec3 HalfExtents() const {
        return Vec3Make((max.x-min.x)*0.5f, (max.y-min.y)*0.5f, (max.z-min.z)*0.5f);
    }
};

struct MeshLOD {
    u32 indexOffset  { 0 };
    u32 indexCount   { 0 };
    f32 switchDist   { 0.0f }; // world-space distance to switch to this LOD
};

struct CookedMesh {
    AssetID      id;
    std::string  name;
    VertexFormat format   { VertexFormat::PNU };
    AABB         bounds;
    f32          selectionRadius { 0.5f };

    // Interleaved vertex data; layout depends on format
    std::vector<u8>      vertexData;
    std::vector<u16>     indices16;     // used when indexCount <= 65535
    std::vector<u32>     indices32;     // used otherwise

    std::vector<MeshLOD> lods;          // lods[0] = full detail

    u32 VertexStride() const {
        switch (format) {
            case VertexFormat::PNU:  return 3*4 + 3*4 + 2*4; // 32 bytes
            case VertexFormat::PNUT: return 3*4 + 3*4 + 2*4 + 4*4; // 48 bytes
        }
        return 0;
    }
    u32 VertexCount() const {
        u32 stride = VertexStride();
        return stride > 0 ? (u32)(vertexData.size() / stride) : 0;
    }
};
