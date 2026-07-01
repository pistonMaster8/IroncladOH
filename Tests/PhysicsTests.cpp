// PhysicsTests.cpp — headless physics unit tests. No framework dependency.

#include "../Engine/Physics/PhysicsSystem.hpp"
#include "../Engine/Core/Log.hpp"
#include <cstdio>
#include <cmath>
#include <cassert>

static int gTests = 0;
static int gPassed = 0;

#define CHECK(expr) \
    do { gTests++; \
         if (expr) { gPassed++; } \
         else { fprintf(stderr, "FAIL: %s (line %d)\n", #expr, __LINE__); } \
    } while(0)

static void TestGravityIntegrate() {
    PhysicsSystem phys;
    PhysicsSystem::ProjectileState s;
    s.position  = Vec3Make(0, 5, 0);
    s.velocity  = Vec3Make(0, 0, 0);
    s.active    = true;

    // Integrate 0.5 seconds — expect to fall toward ground
    for (int i = 0; i < 30; ++i)
        phys.Integrate(s, 1.0f/60.0f);

    CHECK(s.position.y < 5.0f);    // should have fallen
    CHECK(s.active);                // still airborne
}

static void TestBounce() {
    PhysicsSystem phys;
    PhysicsSystem::ProjectileState s;
    s.position    = Vec3Make(0, 0.5f, 0);
    s.velocity    = Vec3Make(0, -5, 0);
    s.restitution = 0.6f;
    s.active      = true;

    // Run until first bounce
    for (int i = 0; i < 120; ++i)
        phys.Integrate(s, 1.0f/60.0f);

    CHECK(s.bounceCount >= 1);
}

static void TestSleep() {
    PhysicsSystem phys;
    PhysicsSystem::ProjectileState s;
    s.position    = Vec3Make(0, 0.16f, 0);
    s.velocity    = Vec3Make(0, -0.001f, 0);
    s.restitution = 0.1f;  // nearly inelastic
    s.active      = true;
    s.bounceCount = 6; // kMaxBounces

    // Should sleep quickly
    int steps = 0;
    while (s.active && steps < 600) {
        phys.Integrate(s, 1.0f/60.0f);
        steps++;
    }
    CHECK(!s.active);
}

static void TestRaycastGround() {
    PhysicsSystem phys;
    Vec3 hit {}, norm {};
    bool hit1 = phys.Raycast(Vec3Make(0, 10, 0), Vec3Make(0, -1, 0), 100, hit, norm);
    CHECK(hit1);
    CHECK(fabsf(hit.y) < 1e-4f);
    CHECK(fabsf(norm.y - 1.0f) < 1e-4f);

    // Ray going up — no hit
    bool hit2 = phys.Raycast(Vec3Make(0, 1, 0), Vec3Make(0, 1, 0), 100, hit, norm);
    CHECK(!hit2);
}

static void TestOverlapAABB() {
    PhysicsSystem phys;
    CHECK(phys.OverlapAABB(
        Vec3Make(0, 0, 0), Vec3Make(1,1,1),
        Vec3Make(-0.5f,-0.5f,-0.5f), Vec3Make(0.5f,0.5f,0.5f)));
    CHECK(!phys.OverlapAABB(
        Vec3Make(5, 0, 0), Vec3Make(0.4f,0.4f,0.4f),
        Vec3Make(-0.5f,-0.5f,-0.5f), Vec3Make(0.5f,0.5f,0.5f)));
}

int main() {
    TestGravityIntegrate();
    TestBounce();
    TestSleep();
    TestRaycastGround();
    TestOverlapAABB();

    printf("Physics tests: %d/%d passed\n", gPassed, gTests);
    return (gPassed == gTests) ? 0 : 1;
}
