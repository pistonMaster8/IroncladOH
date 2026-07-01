#include "PhysicsSystem.hpp"
#include "../Simulation/Terrain.hpp"
#include <cmath>
#include <algorithm>

bool PhysicsSystem::Integrate(ProjectileState& state, f32 dt) {
    if (!state.active) return false;

    // Gravity + drag
    Vec3 gravity = Vec3Make(0, kGravity, 0);
    Vec3 dragForce = Vec3Make(
        -state.drag * state.velocity.x,
        -state.drag * state.velocity.y,
        -state.drag * state.velocity.z
    );

    Vec3 accel = Vec3Make(
        (gravity.x + dragForce.x) / state.mass,
        (gravity.y + dragForce.y) / state.mass,
        (gravity.z + dragForce.z) / state.mass
    );

    // Semi-implicit Euler
    state.velocity.x += accel.x * dt;
    state.velocity.y += accel.y * dt;
    state.velocity.z += accel.z * dt;

    state.position.x += state.velocity.x * dt;
    state.position.y += state.velocity.y * dt;
    state.position.z += state.velocity.z * dt;

    // Ground collision
    TerrainSample ground = QueryGround(state.position.x, state.position.z);
    f32 groundY = ground.height + state.radius;
    if (state.position.y < groundY) {
        state.position.y = groundY;
        ResolveBounce(state, ground.normal);
        state.bounceCount++;
    }

    // Wall collisions (arena boundary matches ground mesh half-size)
    f32 bound = kArenaBound - state.radius;
    if (state.position.x >  bound) { state.position.x =  bound; if (state.velocity.x > 0) state.velocity.x = -state.velocity.x * state.restitution; }
    if (state.position.x < -bound) { state.position.x = -bound; if (state.velocity.x < 0) state.velocity.x = -state.velocity.x * state.restitution; }
    if (state.position.z >  bound) { state.position.z =  bound; if (state.velocity.z > 0) state.velocity.z = -state.velocity.z * state.restitution; }
    if (state.position.z < -bound) { state.position.z = -bound; if (state.velocity.z < 0) state.velocity.z = -state.velocity.z * state.restitution; }

    // Sleep when slow and resting on the ground
    f32 speed = Vec3Len(state.velocity);
    if (speed < kSleepSpeed && state.position.y <= groundY + 0.02f) {
        state.active = false;
        return false;
    }
    return true;
}

void PhysicsSystem::ResolveBounce(ProjectileState& state, Vec3 normal) {
    // Reflect velocity about surface normal with restitution
    f32 vDotN = Vec3Dot(state.velocity, normal);
    if (vDotN >= 0) return; // already separating

    state.velocity.x -= (1.0f + state.restitution) * vDotN * normal.x;
    state.velocity.y -= (1.0f + state.restitution) * vDotN * normal.y;
    state.velocity.z -= (1.0f + state.restitution) * vDotN * normal.z;

    // Friction on tangential component — use post-bounce dot product so the
    // normal direction is not incorrectly included in the tangent vector.
    constexpr f32 kFriction = 0.3f;
    f32 vDotN_post = Vec3Dot(state.velocity, normal);
    state.velocity.x -= kFriction * (state.velocity.x - vDotN_post * normal.x);
    state.velocity.y -= kFriction * (state.velocity.y - vDotN_post * normal.y);
    state.velocity.z -= kFriction * (state.velocity.z - vDotN_post * normal.z);
}

TerrainSample PhysicsSystem::QueryGround(f32 x, f32 z) const {
    constexpr f32 eps = 0.2f;
    f32 h  = Terrain::Height(x, z);
    f32 hL = Terrain::Height(x - eps, z), hR = Terrain::Height(x + eps, z);
    f32 hD = Terrain::Height(x, z - eps), hU = Terrain::Height(x, z + eps);
    f32 nx = (hL - hR) / (2.0f * eps);
    f32 nz = (hD - hU) / (2.0f * eps);
    f32 len = sqrtf(nx*nx + 1.0f + nz*nz);
    return { h, Vec3Make(nx/len, 1.0f/len, nz/len) };
}

bool PhysicsSystem::Raycast(Vec3 origin, Vec3 dir, f32 maxDist,
                            Vec3& outHit, Vec3& outNorm) const {
    if (fabsf(dir.y) < 1e-6f) return false;
    f32 t = (kGroundY - origin.y) / dir.y;
    if (t < 0 || t > maxDist) return false;
    outHit  = Vec3Make(origin.x + dir.x * t, kGroundY, origin.z + dir.z * t);
    outNorm = Vec3Make(0, 1, 0);
    return true;
}

bool PhysicsSystem::SweepSphere(Vec3 start, Vec3 end, f32 radius,
                                Vec3& outHit, Vec3& outNorm) const {
    Vec3 dir = Vec3Make(end.x - start.x, end.y - start.y, end.z - start.z);
    f32 len  = Vec3Len(dir);
    if (len < 1e-6f) return false;
    Vec3 ndir = Vec3Norm(dir);
    return Raycast(
        Vec3Make(start.x, start.y - radius, start.z),
        ndir, len, outHit, outNorm
    );
}

bool PhysicsSystem::OverlapAABB(Vec3 center, Vec3 halfExtents,
                                Vec3 aabbMin, Vec3 aabbMax) const {
    return (center.x - halfExtents.x <= aabbMax.x && center.x + halfExtents.x >= aabbMin.x)
        && (center.y - halfExtents.y <= aabbMax.y && center.y + halfExtents.y >= aabbMin.y)
        && (center.z - halfExtents.z <= aabbMax.z && center.z + halfExtents.z >= aabbMin.z);
}
