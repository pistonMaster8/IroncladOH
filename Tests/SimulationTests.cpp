// SimulationTests.cpp — ECS and game simulation headless tests.

#include "../Engine/Simulation/World.hpp"
#include "../Engine/Simulation/GameSim.hpp"
#include <cstdio>
#include <cassert>

static int gTests = 0;
static int gPassed = 0;

#define CHECK(expr) \
    do { gTests++; \
         if (expr) { gPassed++; } \
         else { fprintf(stderr, "FAIL: %s (line %d)\n", #expr, __LINE__); } \
    } while(0)

static void TestEntityLifecycle() {
    World w;
    EntityID a = w.CreateEntity();
    EntityID b = w.CreateEntity();
    CHECK(a.IsValid());
    CHECK(b.IsValid());
    CHECK(a != b);
    CHECK(w.EntityCount() == 2);

    w.DestroyEntity(a);
    CHECK(!w.IsAlive(a));
    CHECK(w.IsAlive(b));
    CHECK(w.EntityCount() == 1);
}

static void TestComponentStorage() {
    World w;
    EntityID e = w.CreateEntity();
    w.Transforms().Add(e, TransformComponent{ Vec3Make(1, 2, 3) });

    auto* xf = w.Transforms().Get(e);
    CHECK(xf != nullptr);
    CHECK(xf->position.x == 1.0f);
    CHECK(xf->position.y == 2.0f);

    w.Transforms().Remove(e);
    CHECK(w.Transforms().Get(e) == nullptr);
}

static void TestSpawnScene() {
    GameSim sim;
    sim.SpawnInitialScene();

    // Six player shadow-disc units plus seven neutral AI targets.
    CHECK(sim.GetWorld().EntityCount() == 13);

    // Verify player ownership distribution and neutral AI population.
    int p1=0, p2=0, p3=0, neutral=0, wandering=0, stationary=0;
    sim.GetWorld().Ownerships().ForEach([&](EntityID id, OwnershipComponent& own) {
        if (own.owner == PlayerSlot::P1) ++p1;
        if (own.owner == PlayerSlot::P2) ++p2;
        if (own.owner == PlayerSlot::P3) ++p3;
        if (own.owner == PlayerSlot::None) ++neutral;

        if (auto* ai = sim.GetWorld().AIControllers().Get(id)) {
            if (ai->autonomy == AutonomyMode::Wandering) ++wandering;
            if (ai->autonomy == AutonomyMode::Stationary) ++stationary;
        }
    });
    CHECK(p1 == 2);
    CHECK(p2 == 2);
    CHECK(p3 == 2);
    CHECK(neutral == 7);
    CHECK(wandering == 4);
    CHECK(stationary == 3);
}

static void TestMoveCommand() {
    GameSim sim;
    sim.SpawnInitialScene();

    // Find P1 entity
    EntityID p1e {};
    sim.GetWorld().Ownerships().ForEach([&](EntityID id, OwnershipComponent& own) {
        if (own.owner == PlayerSlot::P1) p1e = id;
    });
    CHECK(p1e.IsValid());

    // Submit move command
    Command cmd;
    cmd.type      = CommandType::Move;
    cmd.targetPos = Vec3Make(3, 0, 3);
    cmd.issuer    = PlayerSlot::P1;
    sim.SubmitCommand(PlayerSlot::P1, cmd);

    // Advance ~2 seconds
    for (int i = 0; i < 120; ++i)
        sim.Advance(1.0 / 60.0);

    // Unit should have moved toward (3,0,3)
    auto* xf = sim.GetWorld().Transforms().Get(p1e);
    CHECK(xf != nullptr);
    CHECK(xf->position.x > -8.0f + 0.5f);  // moved from -8
}

static void TestProjectileSpawn() {
    GameSim sim;
    EntityID proj = sim.SpawnProjectile(
        Vec3Make(0, 5, 0),
        Vec3Make(5, 3, 0),
        PlayerSlot::P1);
    CHECK(proj.IsValid());
    CHECK(sim.GetWorld().Projectiles().Has(proj));

    // Advance 1 second — projectile should still be active initially
    for (int i = 0; i < 60; ++i)
        sim.Advance(1.0 / 60.0);

    auto* p = sim.GetWorld().Projectiles().Get(proj);
    // proj may have bounced or deactivated; entity still valid
    CHECK(sim.GetWorld().IsAlive(proj));
    CHECK(sim.Stats().projectileCount >= 0);
}

static void TestDeterministicTick() {
    // Run same scenario twice, compare final position
    auto run = [](Vec3& outPos) {
        GameSim sim;
        sim.SpawnInitialScene();
        Command cmd;
        cmd.type      = CommandType::Move;
        cmd.targetPos = Vec3Make(5, 0, 5);
        cmd.issuer    = PlayerSlot::P2;
        sim.SubmitCommand(PlayerSlot::P2, cmd);
        for (int i = 0; i < 180; ++i) sim.Advance(1.0/60.0);

        EntityID p2e {};
        sim.GetWorld().Ownerships().ForEach([&](EntityID id, OwnershipComponent& own) {
            if (own.owner == PlayerSlot::P2) p2e = id;
        });
        if (p2e.IsValid())
            if (auto* xf = sim.GetWorld().Transforms().Get(p2e))
                outPos = xf->position;
    };

    Vec3 pos1 {}, pos2 {};
    run(pos1);
    run(pos2);

    CHECK(pos1.x == pos2.x);
    CHECK(pos1.z == pos2.z);
}

int main() {
    TestEntityLifecycle();
    TestComponentStorage();
    TestSpawnScene();
    TestMoveCommand();
    TestProjectileSpawn();
    TestDeterministicTick();

    printf("Simulation tests: %d/%d passed\n", gPassed, gTests);
    return (gPassed == gTests) ? 0 : 1;
}
