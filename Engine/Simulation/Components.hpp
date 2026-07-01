#pragma once
#include "../Core/Math.hpp"
#include "../Core/Handle.hpp"
#include "../Core/StringID.hpp"
#include <cstdint>
#include <array>

// ─── Player slot ─────────────────────────────────────────────────────────────
enum class PlayerSlot : u8 { None = 0, P1 = 1, P2 = 2, P3 = 3, Count = 4 };

// Player colors indexed by PlayerSlot (0=None, 1=P1, 2=P2, 3=P3)
inline Vec3 PlayerColor(PlayerSlot slot) {
    switch (slot) {
        case PlayerSlot::P1:   return Vec3Make(0.2f, 0.5f, 1.0f);
        case PlayerSlot::P2:   return Vec3Make(1.0f, 0.3f, 0.2f);
        case PlayerSlot::P3:   return Vec3Make(0.2f, 0.8f, 0.2f);
        default:               return Vec3Make(0.8f, 0.8f, 0.8f);
    }
}

// ─── Transform ───────────────────────────────────────────────────────────────
struct TransformComponent {
    Vec3 position   { Vec3Make(0,0,0) };
    Quat rotation   {};
    f32  scale      { 1.0f };
};

// ─── Renderable ──────────────────────────────────────────────────────────────
using MeshHandle     = TypedHandle<struct MeshTag>;
using MaterialHandle = TypedHandle<struct MaterialTag>;
using TextureHandle  = TypedHandle<struct TextureTag>;

struct RenderableComponent {
    MeshHandle     mesh;
    MaterialHandle material;
    Vec3           tint        { Vec3Make(1,1,1) };
    bool           castShadow  { true };
    bool           visible     { true };
};

// ─── Ownership ───────────────────────────────────────────────────────────────
struct OwnershipComponent {
    PlayerSlot owner { PlayerSlot::None };
};

// ─── Selection ───────────────────────────────────────────────────────────────
struct SelectionComponent {
    bool selected  { false };
    bool hovered   { false };
    // Ground-plane footprint radius — must match RenderUnit::shadowRadius.
    // Selection is a 2D circle-overlap test: cursor disc (r=0.25) overlaps this circle → selected.
    f32  radius    { 0.5f };
};

// ─── Command types ───────────────────────────────────────────────────────────
enum class CommandType : u8 {
    None = 0,
    Move,
    Attack,
    ThrowAbility,
    BuildInteract,
};

struct Command {
    CommandType  type       { CommandType::None };
    Vec3         targetPos  {};
    EntityID     targetEnt  {};
    PlayerSlot   issuer     {};
    u64          tick       { 0 };
};

struct CommandQueueComponent {
    static constexpr u32 kMaxQueued = 8;
    std::array<Command, kMaxQueued> queue {};
    u32 head { 0 };
    u32 tail { 0 };
    f32 throwCooldown { 0.0f };
    u32 Count() const { return tail - head; }
    bool Empty() const { return head == tail; }
    void Push(Command c) {
        if (Count() < kMaxQueued) queue[tail++ % kMaxQueued] = c;
    }
    Command Pop() {
        PFGE_ASSERT(!Empty());
        return queue[head++ % kMaxQueued];
    }
    Command& Front() { return queue[head % kMaxQueued]; }
};

// ─── Movement ────────────────────────────────────────────────────────────────
struct MoveComponent {
    Vec3  destination    {};
    bool  hasDestination { false };
    f32   arrivalRadius  { 0.3f };
    // Kinematic state — persists between orders
    Vec3  velocity       {};
    // Per-order curve parameters (set when order is issued)
    f32   vMaxCurve      { 5.0f };
    f32   accelCurve     { 8.0f };
    f32   decelCurve     { 8.0f };
    // Follow-with-standoff: if followTarget is valid, TickFollow continuously
    // updates destination to keep this unit at followRadius from the target
    // at the personal approach angle followAngle.
    EntityID followTarget {};
    f32      followAngle  { 0.0f };
    f32      followRadius { 5.0f };
    // Avoidance steering (set by TickAvoidance, consumed by TickMovement)
    Vec3 steeringDest     {};
    bool hasSteeringDest  { false };
};

// ─── Health ──────────────────────────────────────────────────────────────────
struct HealthComponent {
    f32 current { 100.0f };
    f32 max     { 100.0f };
    bool IsAlive() const { return current > 0.0f; }
};

// ─── Physics (projectile) ────────────────────────────────────────────────────
struct ProjectileComponent {
    Vec3  velocity     { Vec3Make(0,0,0) };
    f32   mass         { 1.0f };
    f32   restitution  { 0.72f };
    f32   drag         { 0.005f };
    f32   radius       { 0.15f };
    f32   lifetime     { 3.5f };
    bool  active       { true };
    u32   bounceCount  { 0 };

    EntityID  ownerEnt {};
    PlayerSlot owner   { PlayerSlot::None };
    bool targetedStationary { false }; // suppresses proximity detonation from wandering units
};

// ─── AI state ────────────────────────────────────────────────────────────────
enum class AutonomyMode : u8 {
    Manual       = 0,
    Assisted     = 1,
    Autonomous   = 2,
    Uncontrolled = 3,
    Scripted     = 4,
    Wandering    = 5,  // picks random destinations, ignores enemies
    Stationary   = 6,  // never moves; target for ballistic throws
};

enum class BehaviorState : u8 {
    Idle        = 0,
    Moving      = 1,
    Attacking   = 2,
    Retreating  = 3,
    Stunned     = 4,
    Dead        = 5,
};

struct AIControllerComponent {
    AutonomyMode autonomy       { AutonomyMode::Assisted };
    BehaviorState state         { BehaviorState::Idle };
    EntityID      currentTarget {};
    f32   sightRadius           { 8.0f };
    f32   attackRange           { 2.0f };
    f32   retreatHealthPct      { 0.25f };
    f32   utilityTimer          { 0.0f };
    f32   wanderPhase           { 0.0f }; // accumulated angle for Wandering units
    static constexpr f32 kUtilityTickRate = 0.5f; // re-evaluate every 0.5s
};

struct PathFollowerComponent {
    static constexpr u32 kMaxPathLen = 32;
    std::array<Vec3, kMaxPathLen> waypoints {};
    u32  waypointCount  { 0 };
    u32  waypointIdx    { 0 };
    bool pathValid      { false };
};

struct PerceptionComponent {
    EntityID lastKnownEnemyPos[3] {};  // one per player slot
    Vec3     lastKnownPositions[3] {};
    bool     seenThisTick[3] {};
};

// ─── Selection rings (visual unit identifier) ────────────────────────────────
// Three spinning rings drawn on the ground plane when a unit is selected.
// The inner edges are wavy (wave harmonics are unique per unit and serve as its ID).
// Ring 2 (outer) is shared across all units spawned in the same batch.
struct SelectionRingHarmonic {
    f32 amp;    // radial amplitude (metres)
    f32 freq;   // integer harmonic stored as float (2, 3, 5, 7)
    f32 phase;  // phase offset (radians)
};

struct SelectionRingComponent {
    SelectionRingHarmonic waves[3][4]; // [ring_index][harmonic_index]
    f32 rotSpeed[3];   // radians/sec per ring (slightly random)
    f32 rotAngle[3];   // current rotation (sim-maintained)
};

// ─── Unit type tag ────────────────────────────────────────────────────────────
enum class UnitType : u8 {
    Basic      = 0,
    Hero       = 1,
    Vehicle    = 2,
    Building   = 3,
    Projectile = 4,
    ShadowDisc = 5,
};

struct UnitTypeComponent {
    UnitType type { UnitType::Basic };
};
