#pragma once
#include <cstdint>
#include <cstddef>
#include <cassert>
#include <limits>
#include <type_traits>

// ─── Integer aliases ──────────────────────────────────────────────────────────
using u8  = uint8_t;
using u16 = uint16_t;
using u32 = uint32_t;
using u64 = uint64_t;
using i8  = int8_t;
using i16 = int16_t;
using i32 = int32_t;
using i64 = int64_t;
using f32 = float;
using f64 = double;
using usize = size_t;

static constexpr u32 kInvalidU32 = std::numeric_limits<u32>::max();

// ─── PFGE_ASSERT ─────────────────────────────────────────────────────────────
#if defined(NDEBUG)
#  define PFGE_ASSERT(expr) ((void)(expr))
#else
#  define PFGE_ASSERT(expr) assert(expr)
#endif

// ─── Non-copyable base ────────────────────────────────────────────────────────
struct NonCopyable {
    NonCopyable() = default;
    NonCopyable(const NonCopyable&) = delete;
    NonCopyable& operator=(const NonCopyable&) = delete;
    NonCopyable(NonCopyable&&) = default;
    NonCopyable& operator=(NonCopyable&&) = default;
};

// ─── Bit helpers ──────────────────────────────────────────────────────────────
template<typename T>
constexpr T AlignUp(T value, T alignment) {
    return (value + alignment - 1) & ~(alignment - 1);
}

template<typename T>
constexpr bool IsPow2(T v) { return v != 0 && (v & (v - 1)) == 0; }

// ─── Kilobyte / Megabyte literals ────────────────────────────────────────────
constexpr usize operator""_KiB(unsigned long long v) { return v * 1024ULL; }
constexpr usize operator""_MiB(unsigned long long v) { return v * 1024ULL * 1024ULL; }
constexpr usize operator""_GiB(unsigned long long v) { return v * 1024ULL * 1024ULL * 1024ULL; }
