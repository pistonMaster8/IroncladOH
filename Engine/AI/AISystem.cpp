#include "AISystem.hpp"
#include <cmath>

void AISystem::Tick(World& world, f32 dt, const std::vector<ConditionEvent>& events) {
    world.AIControllers().ForEach([&](EntityID id, AIControllerComponent& ai) {
        auto* xf  = world.Transforms().Get(id);
        auto* mv  = world.Moves().Get(id);
        auto* hp  = world.Healths().Get(id);
        auto* own = world.Ownerships().Get(id);

        if (!xf || !own) return;

        // Handle condition events first
        ResolveConditions(world, id, ai, xf, own, events);

        // Skip Manual units — player drives them directly
        if (ai.autonomy == AutonomyMode::Manual) return;

        TickUnit(world, id, ai, xf, mv, hp, own, dt);
    });
    m_events.clear();
}

void AISystem::TickUnit(World& world, EntityID id, AIControllerComponent& ai,
                        TransformComponent* xf, MoveComponent* mv,
                        HealthComponent* hp, OwnershipComponent* own, f32 dt) {
    ai.utilityTimer += dt;
    if (ai.utilityTimer < AIControllerComponent::kUtilityTickRate) return;
    ai.utilityTimer = 0.0f;

    if (!mv || !hp) return;

    // Wandering units are driven by GameSim::TickWander, not the AI system.
    if (ai.autonomy == AutonomyMode::Wandering) return;

    f32 healthPct = hp->max > 0 ? hp->current / hp->max : 1.0f;

    // ─── FSM transitions ──────────────────────────────────────────────────
    switch (ai.state) {
        case BehaviorState::Dead:
            return;

        case BehaviorState::Stunned:
            // Timer-based: stun clears in game logic elsewhere
            return;

        case BehaviorState::Retreating: {
            if (healthPct > ai.retreatHealthPct + 0.15f) {
                // Recovered enough — go back to idle
                ai.state = BehaviorState::Idle;
            }
            return;
        }

        case BehaviorState::Idle:
        case BehaviorState::Moving: {
            if (ai.autonomy == AutonomyMode::Autonomous) {
                // Utility scoring for Autonomous units
                EntityID nearestEnemy = FindNearestEnemy(world, id, xf->position, own->owner, ai.sightRadius);

                f32 retreatScore = Utility::RetreatScore(healthPct, ai.retreatHealthPct);
                f32 chaseScore   = 0.0f;
                f32 attackScore  = 0.0f;
                f32 distToEnemy  = std::numeric_limits<f32>::max();

                if (nearestEnemy.IsValid()) {
                    auto* exf = world.Transforms().Get(nearestEnemy);
                    if (exf) {
                        Vec3 d = Vec3Make(xf->position.x - exf->position.x,
                                         0, xf->position.z - exf->position.z);
                        distToEnemy  = Vec3Len(d);
                        chaseScore   = Utility::ChaseScore(distToEnemy, ai.sightRadius);
                        attackScore  = Utility::AttackScore(distToEnemy, ai.attackRange, healthPct);
                    }
                }

                if (retreatScore > 0.6f) {
                    ai.state = BehaviorState::Retreating;
                    Vec3 retreatDir = Vec3Norm(xf->position);
                    mv->destination    = Vec3Make(xf->position.x + retreatDir.x * 6.0f,
                                                   0, xf->position.z + retreatDir.z * 6.0f);
                    mv->hasDestination = true;
                } else if (attackScore > chaseScore && attackScore > 0.3f) {
                    ai.state         = BehaviorState::Attacking;
                    ai.currentTarget = nearestEnemy;
                } else if (chaseScore > 0.2f && nearestEnemy.IsValid()) {
                    auto* exf = world.Transforms().Get(nearestEnemy);
                    if (exf) {
                        mv->destination    = exf->position;
                        mv->hasDestination = true;
                        ai.state           = BehaviorState::Moving;
                        ai.currentTarget   = nearestEnemy;
                    }
                }
            } else if (ai.autonomy == AutonomyMode::Assisted) {
                // Assisted: react to immediate threats only
                EntityID nearestEnemy = FindNearestEnemy(world, id, xf->position, own->owner, ai.attackRange);
                if (nearestEnemy.IsValid() && ai.state == BehaviorState::Idle) {
                    ai.state         = BehaviorState::Attacking;
                    ai.currentTarget = nearestEnemy;
                }
            }
            break;
        }

        case BehaviorState::Attacking: {
            // Validate target still alive
            if (!ai.currentTarget.IsValid() || !world.IsAlive(ai.currentTarget)) {
                ai.currentTarget = EntityID::Invalid();
                ai.state         = BehaviorState::Idle;
                return;
            }
            auto* exf = world.Transforms().Get(ai.currentTarget);
            if (!exf) { ai.state = BehaviorState::Idle; return; }

            Vec3 d = Vec3Make(xf->position.x - exf->position.x,
                               0, xf->position.z - exf->position.z);
            f32 dist = Vec3Len(d);

            if (dist > ai.sightRadius) {
                // Lost sight
                ai.state = BehaviorState::Idle;
            } else if (dist > ai.attackRange) {
                // Move into range
                mv->destination    = exf->position;
                mv->hasDestination = true;
                ai.state           = BehaviorState::Moving;
            }
            // Within attack range: gameplay system handles damage
            break;
        }
    }
}

void AISystem::ResolveConditions(World& world, EntityID id, AIControllerComponent& ai,
                                 TransformComponent* xf, OwnershipComponent* own,
                                 const std::vector<ConditionEvent>& events) {
    for (const auto& ev : events) {
        switch (ev.type) {
            case ConditionType::OnDamaged:
                if (ev.subject == id) {
                    auto* mv = world.Moves().Get(id);
                    if (mv && ai.state == BehaviorState::Idle && mv->hasDestination == false) {
                        // React: look for threat
                        auto* exf = world.Transforms().Get(ev.object);
                        if (exf && mv) {
                            mv->destination    = exf->position;
                            mv->hasDestination = true;
                            ai.state           = BehaviorState::Moving;
                            ai.currentTarget   = ev.object;
                        }
                    }
                }
                break;

            case ConditionType::OnEnemyEntersRange:
                if (ev.subject == id && ai.autonomy != AutonomyMode::Manual) {
                    ai.currentTarget = ev.object;
                    ai.state         = BehaviorState::Attacking;
                }
                break;

            default:
                break;
        }
    }
}

EntityID AISystem::FindNearestEnemy(World& world, EntityID self,
                                    Vec3 selfPos, PlayerSlot selfOwner,
                                    f32 sightRadius) const {
    EntityID nearest {};
    f32 bestDist = sightRadius;

    const_cast<World&>(world).Transforms().ForEach([&](EntityID eid, TransformComponent& exf) {
        if (eid == self) return;
        auto* eown = const_cast<World&>(world).Ownerships().Get(eid);
        if (!eown || eown->owner == selfOwner || eown->owner == PlayerSlot::None) return;

        Vec3 d = Vec3Make(selfPos.x - exf.position.x, 0, selfPos.z - exf.position.z);
        f32 dist = Vec3Len(d);
        if (dist < bestDist) { bestDist = dist; nearest = eid; }
    });
    return nearest;
}
