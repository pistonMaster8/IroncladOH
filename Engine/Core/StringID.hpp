#pragma once
#include "Types.hpp"
#include <string_view>

// FNV-1a compile-time hash for lightweight string IDs.
// Collisions are possible but acceptable for debug/category keys.
struct StringID {
    u64 hash { 0 };

    StringID() = default;
    explicit constexpr StringID(u64 h) : hash(h) {}
    explicit StringID(std::string_view s) : hash(Compute(s)) {}

    bool operator==(StringID o) const { return hash == o.hash; }
    bool operator!=(StringID o) const { return hash != o.hash; }
    bool operator< (StringID o) const { return hash <  o.hash; }
    [[nodiscard]] bool IsValid() const { return hash != 0; }

    static constexpr u64 Compute(std::string_view s) {
        u64 h = 14695981039346656037ULL;
        for (char c : s) h = (h ^ static_cast<u8>(c)) * 1099511628211ULL;
        return h;
    }
};

constexpr StringID operator""_sid(const char* s, size_t len) {
    return StringID{ StringID::Compute({s, len}) };
}

namespace std {
    template<> struct hash<StringID> {
        size_t operator()(StringID id) const noexcept { return id.hash; }
    };
}
