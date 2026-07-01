#pragma once
#include "World.hpp"
#include "../Physics/PhysicsSystem.hpp"
#include <vector>
#include <functional>

// ─── Avoidance constants (also used for debug visualization) ─────────────────
inline constexpr float kAvoidForwardOff = 0.8f;  // detection circle forward bias
inline constexpr float kAvoidDetectR    = 1.2f;  // detection circle radius

// ─── Simulation tick rate ─────────────────────────────────────────────────────
constexpr f64 kSimTickRate    = 60.0;
constexpr f64 kSimTickSeconds = 1.0 / kSimTickRate;
constexpr f32 kSimDt          = static_cast<f32>(kSimTickSeconds);

// ─── Input command submitted by a player this tick ───────────────────────────
struct PlayerInput {
    PlayerSlot player {};
    Command    command {};
};

// ─── Simulation stats (debug overlay) ────────────────────────────────────────
struct SimStats {
    u32 entityCount     { 0 };
    u32 projectileCount { 0 };
    u32 activeAICount   { 0 };
    u64 currentTick     { 0 };
    f64 accumulator     { 0 };
};

// ─── Explosion (visual-only, no ECS) ─────────────────────────────────────────
struct ExplosionState {
    Vec3 position;
    f32  elapsed   { 0.0f };
    f32  duration  { 0.45f };
    f32  maxRadius { 3.0f };
};

// ─── GameSim ─────────────────────────────────────────────────────────────────
// Owns the authoritative World and advances it in fixed ticks.
// The renderer interpolates between ticks using lastTransforms.
class GameSim {
public:
    GameSim();

    // Call once per display frame with real elapsed time
    void Advance(f64 dtSeconds);

    // Submit a player command (queued for next tick)
    void SubmitCommand(PlayerSlot player, Command cmd);

    // Create the three-player unit setup
    void SpawnInitialScene();

    // Spawn a thrown projectile from a position/velocity
    EntityID SpawnProjectile(Vec3 position, Vec3 velocity, PlayerSlot owner, bool targetedStationary = false);

    // Selection: raycast against selection spheres from normalised screen coords
    // Returns Invalid() if nothing hit.
    EntityID PickEntity(Vec3 rayOrigin, Vec3 rayDir) const;

    // Getters
    World&       GetWorld()       { return m_world; }
    const World& GetWorld() const { return m_world; }
    const SimStats& Stats() const { return m_stats; }
    f64 InterpolationAlpha() const { return m_alpha; }

    // Explosions (visual only — read by EngineHost to populate RenderScene)
    int                   ExplosionCount()        const { return m_explosionCount; }
    const ExplosionState& GetExplosion(int i)     const { return m_explosions[i]; }

private:
    void TickOnce();
    void TickCommands();
    void TickWander();
    void TickFollow();
    void TickAutoThrow();
    void TickMovement();
    void TickAI(f32 dt);
    void TickPhysics(f32 dt);
    void TickSeparation();
    void SpawnExplosion(Vec3 pos);
    void TickExplosions(f32 dt);
    void TickAvoidance();
    void TickSelectionRings(f32 dt);
    void TickTerrain();
    void TickBuildingCollision();

    World           m_world;
    PhysicsSystem   m_physics;

    std::vector<PlayerInput> m_pendingInputs;
    u64  m_tick       { 0 };
    f64  m_accumulator{ 0.0 };
    f64  m_alpha      { 0.0 };
    SimStats m_stats;

    static constexpr int kMaxExplosionsLocal = 64;
    ExplosionState m_explosions[kMaxExplosionsLocal] {};
    int            m_explosionCount { 0 };
};
