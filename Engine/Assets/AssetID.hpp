#pragma once
#include "../Core/Types.hpp"
#include <cstring>

// 128-bit stable asset GUID (RFC 4122 style, but generated deterministically
// from content hash during offline cook, or randomly for new assets).
struct AssetID {
    u8 bytes[16] {};

    bool IsValid() const {
        for (u8 b : bytes) if (b != 0) return true;
        return false;
    }
    bool operator==(const AssetID& o) const { return memcmp(bytes, o.bytes, 16) == 0; }
    bool operator!=(const AssetID& o) const { return !(*this == o); }

    static AssetID Invalid() { return {}; }

    // Quick 64-bit hash for use in hash maps
    u64 Hash() const {
        u64 h = 14695981039346656037ULL;
        for (u8 b : bytes) h = (h ^ b) * 1099511628211ULL;
        return h;
    }
};

namespace std {
    template<> struct hash<AssetID> {
        size_t operator()(const AssetID& id) const noexcept { return id.Hash(); }
    };
}

// Asset type tags — used to generate typed handles
enum class AssetType : u16 {
    Unknown  = 0,
    Mesh     = 1,
    Texture  = 2,
    Material = 3,
    Sound    = 4,
    Map      = 5,
};
