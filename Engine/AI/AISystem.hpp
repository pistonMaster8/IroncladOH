#pragma once
// AI architecture: FSM per unit + utility scoring for autonomous choices.
// Server-authoritative: this runs on both dedicated server and local simulation.
// See Engine/Simulation/Components.hpp for AIControllerComponent, AutonomyMode, etc.

#include "../Simulation/World.hpp"
#include "../Core/Log.hpp"
#include <functional>

// ─── Condition/event types ────────────────────────────────────────────────────
enum class ConditionType : u16 {
    OnDamaged           = 0,
    OnAllyDamagedNearby = 1,
    OnHealthBelowPct    = 2,
    OnEnemyEntersRange  = 3,
    OnPathBlocked       = 4,
    OnLeaderKilled      = 5,
    OnHazardNearby      = 6,
    OnCommandIssued     = 7,
    Count               = 8,
};

struct ConditionEvent {
    ConditionType type {};
    EntityID      subject {};
    EntityID      object  {};
    f32           value   { 0.0f };
};

// ─── Utility scorer ───────────────────────────────────────────────────────────
// Returns [0,1] desirability for each candidate action.
namespace Utility {
    inline f32 AttackScore(f32 distToTarget, f32 attackRange, f32 healthPct) {
        if (distToTarget > attackRange * 1.5f) return 0.0f;
        f32 proximity = 1.0f - Saturate(distToTarget / attackRange);
        return proximity * healthPct;
    }

    inline f32 RetreatScore(f32 healthPct, f32 retreatThreshold) {
        return healthPct < retreatThreshold ? (1.0f - healthPct / retreatThreshold) : 0.0f;
    }

    inline f32 ChaseScore(f32 distToTarget, f32 sightRadius) {
        return Saturate(1.0f - distToTarget / sightRadius);
    }
}

// ─── AISystem ────────────────────────────────────────────────────────────────
class AISystem {
public:
    // Called each simulation tick (fixed dt)
    void Tick(World& world, f32 dt, const std::vector<ConditionEvent>& events);

    // Fire a condition event into all AI controllers (used by sim to broadcast damage, etc.)
    void FireEvent(const ConditionEvent& e) { m_events.push_back(e); }

    // Pull fired events (consumed per tick)
    std::vector<ConditionEvent>& PendingEvents() { return m_events; }

private:
    void TickUnit(World& world, EntityID id, AIControllerComponent& ai,
                  TransformComponent* xf, MoveComponent* mv,
                  HealthComponent* hp, OwnershipComponent* own, f32 dt);

    void ResolveConditions(World& world, EntityID id, AIControllerComponent& ai,
                           TransformComponent* xf, OwnershipComponent* own,
                           const std::vector<ConditionEvent>& events);

    EntityID FindNearestEnemy(World& world, EntityID self,
                              Vec3 selfPos, PlayerSlot selfOwner,
                              f32 sightRadius) const;

    std::vector<ConditionEvent> m_events;
};
