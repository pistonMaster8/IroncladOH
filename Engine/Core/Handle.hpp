#pragma once
#include "Types.hpp"

// TypedHandle: 32-bit typed index + 8-bit generation.
// Named TypedHandle (not Handle) to avoid collision with Apple MacTypes.h `Handle` typedef.
template<typename Tag>
struct TypedHandle {
    static constexpr u32 kInvalidIndex = 0xFFFFFF;

    u32 index : 24 { kInvalidIndex };
    u32 gen   : 8  { 0 };

    [[nodiscard]] bool IsValid() const { return index != kInvalidIndex; }
    bool operator==(TypedHandle o) const { return index == o.index && gen == o.gen; }
    bool operator!=(TypedHandle o) const { return !(*this == o); }
    static TypedHandle Invalid() { return {}; }
};

// Stable 64-bit entity ID: 32-bit index + 16-bit generation + 16-bit reserved
struct EntityID {
    static constexpr u32 kInvalidIndex = 0xFFFFFFFF;

    u32 index { kInvalidIndex };
    u16 gen   { 0 };
    u16 _pad  { 0 };

    [[nodiscard]] bool IsValid() const { return index != kInvalidIndex; }
    bool operator==(EntityID o) const { return index == o.index && gen == o.gen; }
    bool operator!=(EntityID o) const { return !(*this == o); }
    static EntityID Invalid() { return {}; }
};
static_assert(sizeof(EntityID) == 8);
