#pragma once
#include "Types.hpp"
#include <memory>
#include <cstdlib>

// Linear arena allocator — alloc fast, reset free.
// Not thread-safe by design; use per-thread arenas.
class Arena : NonCopyable {
public:
    explicit Arena(usize capacityBytes) {
        m_base = static_cast<u8*>(std::malloc(capacityBytes));
        PFGE_ASSERT(m_base);
        m_capacity = capacityBytes;
    }
    ~Arena() { std::free(m_base); }

    void* Alloc(usize bytes, usize align = alignof(std::max_align_t)) {
        usize offset = AlignUp(m_offset, align);
        PFGE_ASSERT(offset + bytes <= m_capacity && "Arena overflow");
        m_offset = offset + bytes;
        return m_base + offset;
    }

    template<typename T, typename... Args>
    T* New(Args&&... args) {
        void* p = Alloc(sizeof(T), alignof(T));
        return new(p) T(std::forward<Args>(args)...);
    }

    void Reset() { m_offset = 0; }

    [[nodiscard]] usize Used()      const { return m_offset; }
    [[nodiscard]] usize Capacity()  const { return m_capacity; }
    [[nodiscard]] usize Remaining() const { return m_capacity - m_offset; }

private:
    u8*   m_base     { nullptr };
    usize m_offset   { 0 };
    usize m_capacity { 0 };
};
