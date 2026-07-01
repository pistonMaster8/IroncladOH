#pragma once
#include "../Core/Math.hpp"
#include "../Core/Types.hpp"

constexpr f32 kGravity = -9.81f;

// Minimal projectile physics — gravity, drag, bounce against ground plane.
// No full rigid-body dynamics; designed for thrown objects only.

struct TerrainSample {
    f32  height { 0.0f };   // ground height at XZ
    Vec3 normal { Vec3Make(0, 1, 0) };
};

class PhysicsSystem {
public:
    // Integrate one projectile step.
    // Returns true if still active (not dead/sleeping).
    struct ProjectileState {
        Vec3 position {};
        Vec3 velocity {};
        f32  radius   { 0.15f };
        f32  mass     { 1.0f };
        f32  restitution { 0.5f };
        f32  drag        { 0.02f };
        u32  bounceCount { 0 };
        bool active      { true };
    };

    bool Integrate(ProjectileState& state, f32 dt);

    // Ground query (flat terrain for now; override for heightmap)
    TerrainSample QueryGround(f32 x, f32 z) const;

    // Analytic raycast against ground plane
    bool Raycast(Vec3 origin, Vec3 dir, f32 maxDist, Vec3& outHit, Vec3& outNorm) const;

    // Sphere sweep against ground
    bool SweepSphere(Vec3 start, Vec3 end, f32 radius, Vec3& outHit, Vec3& outNorm) const;

    // Overlap check against AABB
    bool OverlapAABB(Vec3 center, Vec3 halfExtents, Vec3 aabbMin, Vec3 aabbMax) const;

    // Helpers (called by GameSim)
    void ResolveBounce(ProjectileState& state, Vec3 normal);

    static constexpr f32 kArenaBound   = 89.0f; // matches expanded ground mesh half-size

private:
    static constexpr f32 kGroundY      = 0.0f;
    static constexpr u32 kMaxBounces   = 50;   // effectively unlimited; lifetime handles cleanup
    static constexpr f32 kSleepSpeed   = 0.05f;
};
