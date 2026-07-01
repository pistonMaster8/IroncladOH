#include "GameSim.hpp"
#include "Terrain.hpp"
#include "Buildings.hpp"
#include "../Core/Log.hpp"
#include <cmath>
#include <algorithm>

// Compute launch velocity so the ball winds up at `to` after all bounces, not just
// the first arc. Each bounce retains restitution*vertical and (1-friction)*horizontal
// speed; the extra distance forms a geometric series that is solved analytically here.
static Vec3 BallisticVelocity(Vec3 from, Vec3 to) {
    constexpr f32 g            = 9.81f;
    // Must match ProjectileComponent::restitution and ResolveBounce::kFriction
    constexpr f32 kRestitution = 0.72f;
    constexpr f32 kHorizRetain = 1.0f - 0.3f;          // 1 - kFriction
    constexpr f32 kBounceRatio = kRestitution * kHorizRetain;           // 0.504
    constexpr f32 kBounceSum   = kBounceRatio / (1.0f - kBounceRatio); // geometric series sum ~1.016

    f32 dx = to.x - from.x;
    f32 dz = to.z - from.z;
    f32 dh = sqrtf(dx*dx + dz*dz);
    if (dh < 0.01f) return Vec3Make(0, 8.0f, 0);

    // Vertical launch speed: 45-degree-optimal for the intended total distance
    f32 vy = fmaxf(4.0f, fminf(14.0f, sqrtf(dh * g * 0.5f)));

    // Vertical speed at first ground contact (independent of horizontal speed)
    f32 vy_impact = sqrtf(vy*vy + 2.0f * g * (from.y - to.y));

    // Time of first arc
    f32 t = (vy + vy_impact) / g;

    // kFactor = D_total / D_first_arc = 1 + D_bounces/D_first_arc
    // D_bounces = vh * (2*vy_impact/g) * kBounceSum
    // D_first   = vh * t
    f32 kFactor = 1.0f + 2.0f * vy_impact * kBounceSum / (vy + vy_impact);

    // Reduce first-arc target so total travel (first arc + bounces) equals dh
    f32 vh = (dh / kFactor) / t;
    return Vec3Make(dx / dh * vh, vy, dz / dh * vh);
}

GameSim::GameSim() = default;

void GameSim::Advance(f64 dtSeconds) {
    m_accumulator += dtSeconds;

    // Fixed-tick loop
    while (m_accumulator >= kSimTickSeconds) {
        // Drain pending inputs into queues
        for (auto& pi : m_pendingInputs) {
            if (auto* q = m_world.Commands().Get(EntityID{}); false) { (void)q; } // quiet unused
            // Find all entities owned by this player and push command
            m_world.Commands().ForEach([&](EntityID id, CommandQueueComponent& cq) {
                auto* own = m_world.Ownerships().Get(id);
                if (own && own->owner == pi.player) {
                    pi.command.tick = m_tick;
                    cq.Push(pi.command);
                }
            });
        }
        m_pendingInputs.clear();

        TickOnce();
        m_tick++;
        m_accumulator -= kSimTickSeconds;
    }

    m_alpha = m_accumulator / kSimTickSeconds;

    m_stats.entityCount     = m_world.EntityCount();
    m_stats.currentTick     = m_tick;
    m_stats.accumulator     = m_accumulator;
    m_stats.projectileCount = m_world.Projectiles().Count();
    m_stats.activeAICount   = m_world.AIControllers().Count();
}

void GameSim::SubmitCommand(PlayerSlot player, Command cmd) {
    m_pendingInputs.push_back({ player, cmd });
}

void GameSim::TickOnce() {
    TickCommands();
    TickWander();
    TickFollow();
    TickAutoThrow();
    TickAvoidance();
    TickMovement();
    TickAI(kSimDt);
    TickPhysics(kSimDt);
    TickSeparation();
    TickBuildingCollision();
    TickTerrain();
    TickExplosions(kSimDt);
    TickSelectionRings(kSimDt);
}

void GameSim::TickSelectionRings(f32 dt) {
    m_world.SelectionRings().ForEach([&](EntityID, SelectionRingComponent& rc) {
        for (int r = 0; r < 3; ++r)
            rc.rotAngle[r] += rc.rotSpeed[r] * dt;
    });
}

void GameSim::TickTerrain() {
    m_world.Transforms().ForEach([&](EntityID id, TransformComponent& xf) {
        if (m_world.Projectiles().Get(id)) return;
        xf.position.y = Terrain::Height(xf.position.x, xf.position.z);
    });
}

void GameSim::TickBuildingCollision() {
    const BuildingBox* buildings = nullptr;
    int nBuildings = GetBuildings(&buildings);

    constexpr f32 kUnitRadius = 0.5f;

    m_world.Transforms().ForEach([&](EntityID id, TransformComponent& xf) {
        if (m_world.Projectiles().Get(id)) return;
        for (int b = 0; b < nBuildings; ++b) {
            const auto& box = buildings[b];
            // Closest point on AABB footprint to unit center (XZ only)
            f32 cx = fmaxf(box.x - box.hw, fminf(xf.position.x, box.x + box.hw));
            f32 cz = fmaxf(box.z - box.hd, fminf(xf.position.z, box.z + box.hd));
            f32 dx = xf.position.x - cx;
            f32 dz = xf.position.z - cz;
            f32 d2 = dx*dx + dz*dz;
            if (d2 >= kUnitRadius * kUnitRadius || d2 < 1e-9f) continue;
            f32 d  = sqrtf(d2);
            f32 pen = kUnitRadius - d;
            xf.position.x += (dx / d) * pen;
            xf.position.z += (dz / d) * pen;
        }
    });
}

void GameSim::TickCommands() {
    // Tick throw cooldowns down every sim step.
    m_world.Commands().ForEach([&](EntityID, CommandQueueComponent& cq) {
        if (cq.throwCooldown > 0.0f)
            cq.throwCooldown = fmaxf(0.0f, cq.throwCooldown - kSimDt);
    });

    m_world.Commands().ForEach([&](EntityID id, CommandQueueComponent& cq) {
        if (cq.Empty()) return;
        Command& cmd = cq.Front();

        switch (cmd.type) {
            case CommandType::Move: {
                auto* mv = m_world.Moves().Get(id);
                if (mv) {
                    mv->destination    = cmd.targetPos;
                    mv->hasDestination = true;
                }
                auto* ai = m_world.AIControllers().Get(id);
                if (ai) ai->state = BehaviorState::Moving;
                cq.Pop();
                break;
            }
            case CommandType::ThrowAbility: {
                if (cq.throwCooldown > 0.0f) {
                    cq.Pop();
                    break;
                }
                auto* xf = m_world.Transforms().Get(id);
                auto* own= m_world.Ownerships().Get(id);
                if (xf && own) {
                    Vec3 dir = Vec3Norm(Vec3Make(
                        cmd.targetPos.x - xf->position.x,
                        0.5f,
                        cmd.targetPos.z - xf->position.z));
                    Vec3 vel = Vec3Make(dir.x * 10.0f, dir.y * 10.0f, dir.z * 10.0f);
                    SpawnProjectile(
                        Vec3Make(xf->position.x, xf->position.y + 1.0f, xf->position.z),
                        vel, own->owner);
                    cq.throwCooldown = 5.0f;
                }
                cq.Pop();
                break;
            }
            default:
                cq.Pop();
                break;
        }
    });
}

void GameSim::TickWander() {
    const BuildingBox* buildings = nullptr;
    int nBuildings = GetBuildings(&buildings);

    m_world.AIControllers().ForEach([&](EntityID id, AIControllerComponent& ai) {
        if (ai.autonomy != AutonomyMode::Wandering) return;
        auto* mv = m_world.Moves().Get(id);
        if (!mv || mv->hasDestination) return;

        ai.wanderPhase += 1.2f + static_cast<f32>(id.index % 7) * 0.17f;
        constexpr f32 kRadius = 30.0f;
        constexpr f32 kLimit  = 42.0f;
        constexpr f32 kMargin = 0.9f; // unit radius + clearance

        f32 destX = fmaxf(-kLimit, fminf(kLimit, cosf(ai.wanderPhase) * kRadius));
        f32 destZ = fmaxf(-kLimit, fminf(kLimit, sinf(ai.wanderPhase) * kRadius));

        // Reject destinations inside or too close to a building.
        // hasDestination stays false → fires again next tick with advanced phase.
        for (int b = 0; b < nBuildings; ++b) {
            const auto& box = buildings[b];
            if (fabsf(destX - box.x) < box.hw + kMargin &&
                fabsf(destZ - box.z) < box.hd + kMargin) return;
        }

        mv->destination    = Vec3Make(destX, 0.0f, destZ);
        mv->hasDestination = true;
    });
}

void GameSim::TickFollow() {
    m_world.Moves().ForEach([&](EntityID id, MoveComponent& mv) {
        if (!mv.followTarget.IsValid()) return;
        if (!m_world.IsAlive(mv.followTarget)) {
            mv.followTarget = EntityID::Invalid();
            return;
        }
        auto* targetXf = m_world.Transforms().Get(mv.followTarget);
        if (!targetXf) {
            mv.followTarget = EntityID::Invalid();
            return;
        }
        auto* xf = m_world.Transforms().Get(id);
        if (!xf) return;

        // Closest point on the standoff circle to this unit's current position
        f32 dx  = xf->position.x - targetXf->position.x;
        f32 dz  = xf->position.z - targetXf->position.z;
        f32 len = sqrtf(dx*dx + dz*dz);
        f32 nx  = len > 0.001f ? dx / len : 1.0f;
        f32 nz  = len > 0.001f ? dz / len : 0.0f;

        mv.destination = Vec3Make(
            targetXf->position.x + nx * mv.followRadius,
            0.0f,
            targetXf->position.z + nz * mv.followRadius);
        mv.hasDestination = true;
    });
}

void GameSim::TickAutoThrow() {
    m_world.Moves().ForEach([&](EntityID id, MoveComponent& mv) {
        if (!mv.followTarget.IsValid()) return;
        auto* cq = m_world.Commands().Get(id);
        if (!cq || cq->throwCooldown > 0.0f) return;
        auto* xf  = m_world.Transforms().Get(id);
        auto* own = m_world.Ownerships().Get(id);
        if (!xf || !own) return;
        auto* targetXf = m_world.Transforms().Get(mv.followTarget);
        if (!targetXf) return;

        f32 dx   = targetXf->position.x - xf->position.x;
        f32 dz   = targetXf->position.z - xf->position.z;
        f32 dist = sqrtf(dx*dx + dz*dz);

        if (dist > mv.followRadius * 2.0f) return;

        Vec3 launchPos = Vec3Make(xf->position.x, xf->position.y + 1.2f, xf->position.z);
        Vec3 vel;
        auto* tai = m_world.AIControllers().Get(mv.followTarget);
        bool isStationary = tai && tai->autonomy == AutonomyMode::Stationary;
        if (isStationary) {
            vel = BallisticVelocity(launchPos, targetXf->position);
        } else {
            f32 len  = fmaxf(dist, 0.001f);
            Vec3 dir = Vec3Norm(Vec3Make(dx / len, 0.3f, dz / len));
            vel = Vec3Make(dir.x * 12.0f, dir.y * 12.0f, dir.z * 12.0f);
        }
        SpawnProjectile(launchPos, vel, own->owner, isStationary);
        cq->throwCooldown = 5.0f;
    });
}

void GameSim::TickAvoidance() {
    // ── Unit-vs-unit detection (tight, forward-biased circle) ────────────────
    constexpr f32 kForwardOff = 0.8f;
    constexpr f32 kDetectR    = 1.2f;
    constexpr f32 kSideStep   = 1.5f;

    // ── Building detection (larger look-ahead — buildings are much wider) ─────
    constexpr f32 kBldFwdOff  = 3.0f;
    constexpr f32 kBldDetectR = 4.0f;
    constexpr f32 kBldClear   = 1.2f;  // extra margin beyond building half-extent

    // Load static building data once per tick
    const BuildingBox* buildings = nullptr;
    int nBuildings = GetBuildings(&buildings);

    // Snapshot moveable, non-stationary unit positions
    struct Pos { EntityID id; f32 x, z; };
    static Pos snap[256];
    int nSnap = 0;
    m_world.Moves().ForEach([&](EntityID id, MoveComponent&) {
        auto* xf = m_world.Transforms().Get(id);
        if (!xf || nSnap >= 256) return;
        auto* ai = m_world.AIControllers().Get(id);
        if (ai && ai->autonomy == AutonomyMode::Stationary) return;
        snap[nSnap++] = { id, xf->position.x, xf->position.z };
    });

    m_world.Moves().ForEach([&](EntityID id, MoveComponent& mv) {
        mv.hasSteeringDest = false;

        auto* xf = m_world.Transforms().Get(id);
        if (!xf || !mv.hasDestination) return;
        auto* ai = m_world.AIControllers().Get(id);
        if (ai && ai->autonomy == AutonomyMode::Stationary) return;

        f32 toDx = mv.destination.x - xf->position.x;
        f32 toDz = mv.destination.z - xf->position.z;
        f32 toDist = sqrtf(toDx*toDx + toDz*toDz);
        if (toDist < mv.arrivalRadius + 0.05f) return;

        f32 fwdX = toDx / toDist, fwdZ = toDz / toDist;
        f32 rightX = -fwdZ, rightZ = fwdX;

        // ── 1. Building avoidance (takes priority — buildings don't yield) ────
        {
            f32 bdcx = xf->position.x + fwdX * kBldFwdOff;
            f32 bdcz = xf->position.z + fwdZ * kBldFwdOff;

            f32 bldLateral = 0.f;
            f32 maxHalf    = 0.f;
            bool anyBuilding = false;

            for (int b = 0; b < nBuildings; ++b) {
                const auto& box = buildings[b];
                // Closest point on building AABB to the building detection center
                f32 cpx = fmaxf(box.x - box.hw, fminf(bdcx, box.x + box.hw));
                f32 cpz = fmaxf(box.z - box.hd, fminf(bdcz, box.z + box.hd));
                f32 dx = cpx - bdcx, dz = cpz - bdcz;
                if (dx*dx + dz*dz > kBldDetectR * kBldDetectR) continue;

                // Lateral offset of the building center — determines which side to pass
                bldLateral += (box.x - xf->position.x) * rightX
                            + (box.z - xf->position.z) * rightZ;
                maxHalf = fmaxf(maxHalf, fmaxf(box.hw, box.hd));
                anyBuilding = true;
            }

            if (anyBuilding) {
                // Deterministic per-unit tiebreaker when heading straight at building centre
                f32 avoidDir = (fabsf(bldLateral) > 0.05f)
                    ? (bldLateral >= 0.f ? -1.f : 1.f)
                    : (id.index & 1 ? 1.f : -1.f);
                f32 sideStep = maxHalf + kBldClear;
                f32 fwdReach = fmaxf(toDist * 0.5f, 4.0f);
                mv.steeringDest = Vec3Make(
                    xf->position.x + fwdX * fwdReach + rightX * avoidDir * sideStep,
                    0.f,
                    xf->position.z + fwdZ * fwdReach + rightZ * avoidDir * sideStep);
                mv.hasSteeringDest = true;
                return; // building steer overrides unit steer
            }
        }

        // ── 2. Unit-vs-unit avoidance (tight forward circle) ─────────────────
        {
            f32 dcx = xf->position.x + fwdX * kForwardOff;
            f32 dcz = xf->position.z + fwdZ * kForwardOff;

            f32 lateralSum = 0.f;
            bool anyBlocker = false;
            for (int i = 0; i < nSnap; ++i) {
                if (snap[i].id == id) continue;
                f32 dx = snap[i].x - dcx, dz = snap[i].z - dcz;
                if (dx*dx + dz*dz > kDetectR * kDetectR) continue;
                lateralSum += dx * rightX + dz * rightZ;
                anyBlocker = true;
            }
            if (!anyBlocker) return;

            f32 avoidDir = (lateralSum >= 0.f) ? -1.f : 1.f;
            f32 fwdReach = fmaxf(toDist * 0.5f, 2.0f);
            mv.steeringDest = Vec3Make(
                xf->position.x + fwdX * fwdReach + rightX * avoidDir * kSideStep,
                0.f,
                xf->position.z + fwdZ * fwdReach + rightZ * avoidDir * kSideStep);
            mv.hasSteeringDest = true;
        }
    });
}

void GameSim::TickMovement() {
    m_world.Moves().ForEach([&](EntityID id, MoveComponent& mv) {
        auto* xf = m_world.Transforms().Get(id);
        if (!xf) return;

        if (!mv.hasDestination) {
            // Dampen residual velocity while idle
            mv.velocity.x *= 0.85f;
            mv.velocity.z *= 0.85f;
            return;
        }

        // Arrival check always uses the real destination
        Vec3 toDest = Vec3Make(
            mv.destination.x - xf->position.x,
            0,
            mv.destination.z - xf->position.z);
        f32 distToDest = Vec3Len(toDest);

        if (distToDest <= mv.arrivalRadius) {
            mv.velocity       = Vec3Make(0, 0, 0);
            mv.hasDestination  = false;
            mv.hasSteeringDest = false;
            auto* ai = m_world.AIControllers().Get(id);
            if (ai) ai->state = BehaviorState::Idle;
            return;
        }

        // Steer toward avoidance waypoint when active, otherwise toward destination
        Vec3 steerTarget = mv.hasSteeringDest ? mv.steeringDest : mv.destination;
        Vec3 delta = Vec3Make(
            steerTarget.x - xf->position.x,
            0,
            steerTarget.z - xf->position.z);
        f32 dist = Vec3Len(delta);
        if (dist < 0.01f) dist = 0.01f;

        Vec3 dir = Vec3Norm(delta);

        // Brake based on real-destination distance so units don't overshoot
        f32 brakeSpeed   = sqrtf(2.0f * mv.decelCurve * distToDest);
        f32 desiredSpeed = fminf(mv.vMaxCurve, brakeSpeed);

        // Steer current velocity toward desired velocity, clamped by acceleration
        Vec3 desiredVel  = Vec3Make(dir.x * desiredSpeed, 0, dir.z * desiredSpeed);
        Vec3 diff        = Vec3Make(desiredVel.x - mv.velocity.x, 0, desiredVel.z - mv.velocity.z);
        f32  diffMag     = Vec3Len(diff);
        f32  maxDv       = mv.accelCurve * kSimDt;
        if (diffMag > maxDv) {
            f32 s = maxDv / diffMag;
            diff  = Vec3Make(diff.x * s, 0, diff.z * s);
        }
        mv.velocity.x += diff.x;
        mv.velocity.z += diff.z;

        f32 oldX = xf->position.x, oldZ = xf->position.z;
        xf->position.x += mv.velocity.x * kSimDt;
        xf->position.z += mv.velocity.z * kSimDt;

        // Slope-based traversal: block movement onto terrain steeper than ~45°.
        // This naturally prevents units from climbing cliff faces while allowing
        // the ramp (~11% grade) and the flat cliff-top plateau.
        {
            constexpr f32 kMaxClimbSlope = 1.0f; // rise:run threshold (~45°)
            f32 moveDx   = xf->position.x - oldX;
            f32 moveDz   = xf->position.z - oldZ;
            f32 moveDist = sqrtf(moveDx * moveDx + moveDz * moveDz);
            if (moveDist > 1e-4f) {
                f32 dH = Terrain::Height(xf->position.x, xf->position.z)
                       - Terrain::Height(oldX, oldZ);
                if (fabsf(dH) / moveDist > kMaxClimbSlope) {
                    xf->position.x = oldX;
                    xf->position.z = oldZ;
                    mv.velocity.x  = 0.f;
                    mv.velocity.z  = 0.f;
                }
            }
        }

        // Hard outer edge — prevent walking off the map mesh
        constexpr f32 kMapEdge = 88.5f;
        if (xf->position.x >  kMapEdge) { xf->position.x =  kMapEdge; mv.velocity.x = fminf(0.0f, mv.velocity.x); }
        if (xf->position.x < -kMapEdge) { xf->position.x = -kMapEdge; mv.velocity.x = fmaxf(0.0f, mv.velocity.x); }
        if (xf->position.z >  kMapEdge) { xf->position.z =  kMapEdge; mv.velocity.z = fminf(0.0f, mv.velocity.z); }
        if (xf->position.z < -kMapEdge) { xf->position.z = -kMapEdge; mv.velocity.z = fmaxf(0.0f, mv.velocity.z); }
    });
}

void GameSim::TickAI(f32 dt) {
    m_world.AIControllers().ForEach([&](EntityID id, AIControllerComponent& ai) {
        if (ai.autonomy == AutonomyMode::Manual) return;

        ai.utilityTimer += dt;
        if (ai.utilityTimer < AIControllerComponent::kUtilityTickRate) return;
        ai.utilityTimer = 0.0f;

        auto* mv  = m_world.Moves().Get(id);
        auto* hp  = m_world.Healths().Get(id);
        auto* own = m_world.Ownerships().Get(id);
        auto* xf  = m_world.Transforms().Get(id);
        if (!mv || !hp || !own || !xf) return;

        // Retreat if low health
        if (hp->current < hp->max * ai.retreatHealthPct && ai.state != BehaviorState::Retreating) {
            ai.state = BehaviorState::Retreating;
            // Simple retreat: move back toward spawn corner
            Vec3 retreatDir = Vec3Norm(xf->position);
            mv->destination    = Vec3Make(xf->position.x + retreatDir.x * 5.0f,
                                          0, xf->position.z + retreatDir.z * 5.0f);
            mv->hasDestination = true;
            return;
        }

        // Autonomous: find nearest enemy
        if (ai.autonomy == AutonomyMode::Autonomous && ai.state == BehaviorState::Idle) {
            EntityID nearest {};
            f32 nearestDist = ai.sightRadius;
            m_world.Transforms().ForEach([&](EntityID eid, TransformComponent& exf) {
                if (eid == id) return;
                auto* eown = m_world.Ownerships().Get(eid);
                if (!eown || eown->owner == own->owner) return;
                Vec3 d = Vec3Make(xf->position.x - exf.position.x,
                                   0,
                                   xf->position.z - exf.position.z);
                f32 dist = Vec3Len(d);
                if (dist < nearestDist) { nearestDist = dist; nearest = eid; }
            });

            if (nearest.IsValid()) {
                auto* exf = m_world.Transforms().Get(nearest);
                if (exf) {
                    mv->destination    = exf->position;
                    mv->hasDestination = true;
                    ai.state           = BehaviorState::Moving;
                    ai.currentTarget   = nearest;
                }
            }
        }
    });
}

void GameSim::TickPhysics(f32 dt) {
    m_world.Projectiles().ForEach([&](EntityID id, ProjectileComponent& proj) {
        if (!proj.active) return;

        auto* xf = m_world.Transforms().Get(id);
        if (!xf) return;

        proj.lifetime -= dt;
        if (proj.lifetime <= 0.0f) {
            proj.active = false;
            SpawnExplosion(xf->position);
            return;
        }

        PhysicsSystem::ProjectileState state;
        state.position    = xf->position;
        state.velocity    = proj.velocity;
        state.radius      = proj.radius;
        state.mass        = proj.mass;
        state.restitution = proj.restitution;
        state.drag        = proj.drag;
        state.bounceCount = proj.bounceCount;
        state.active      = proj.active;

        bool still = m_physics.Integrate(state, dt);

        // Building collision for bombs — sphere vs AABB in 3D
        if (still) {
            const BuildingBox* buildings = nullptr;
            int nBuildings = GetBuildings(&buildings);
            for (int b = 0; b < nBuildings; ++b) {
                const auto& box = buildings[b];
                f32 minX = box.x - box.hw, maxX = box.x + box.hw;
                f32 minY = box.baseY,      maxY = box.baseY + box.hh * 2.f;
                f32 minZ = box.z - box.hd, maxZ = box.z + box.hd;

                f32 cx = fmaxf(minX, fminf(state.position.x, maxX));
                f32 cy = fmaxf(minY, fminf(state.position.y, maxY));
                f32 cz = fmaxf(minZ, fminf(state.position.z, maxZ));
                f32 dx = state.position.x - cx;
                f32 dy = state.position.y - cy;
                f32 dz = state.position.z - cz;
                f32 d2 = dx*dx + dy*dy + dz*dz;
                if (d2 >= state.radius * state.radius) continue;

                f32 nx, ny, nz;
                if (d2 > 1e-9f) {
                    f32 d = sqrtf(d2);
                    nx = dx/d; ny = dy/d; nz = dz/d;
                    f32 pen = state.radius - d;
                    state.position.x += nx*pen;
                    state.position.y += ny*pen;
                    state.position.z += nz*pen;
                } else {
                    // Center inside box: eject along minimum-overlap axis
                    f32 ovX = fminf(state.position.x - minX, maxX - state.position.x);
                    f32 ovY = fminf(state.position.y - minY, maxY - state.position.y);
                    f32 ovZ = fminf(state.position.z - minZ, maxZ - state.position.z);
                    if (ovX <= ovY && ovX <= ovZ) {
                        nx=state.position.x<box.x?-1.f:1.f; ny=0; nz=0;
                        state.position.x += nx*(ovX + state.radius);
                    } else if (ovY <= ovZ) {
                        nx=0; ny=state.position.y<(box.baseY+box.hh)?-1.f:1.f; nz=0;
                        state.position.y += ny*(ovY + state.radius);
                    } else {
                        nx=0; ny=0; nz=state.position.z<box.z?-1.f:1.f;
                        state.position.z += nz*(ovZ + state.radius);
                    }
                }
                // Reflect velocity off face with restitution
                f32 vDotN = state.velocity.x*nx + state.velocity.y*ny + state.velocity.z*nz;
                if (vDotN < 0.f) {
                    f32 scale = 1.f + state.restitution;
                    state.velocity.x -= scale * vDotN * nx;
                    state.velocity.y -= scale * vDotN * ny;
                    state.velocity.z -= scale * vDotN * nz;
                }
            }
        }

        xf->position     = state.position;
        proj.velocity    = state.velocity;
        proj.bounceCount = state.bounceCount;
        proj.active      = still;

        // Proximity detonation: explode when passing within explosion radius of a moving enemy
        if (still && !proj.targetedStationary) {
            constexpr f32 kProximityR = 1.5f;
            bool detonated = false;
            m_world.AIControllers().ForEach([&](EntityID eid, AIControllerComponent& ai) {
                if (detonated || ai.autonomy != AutonomyMode::Wandering) return;
                auto* exf = m_world.Transforms().Get(eid);
                if (!exf) return;
                f32 ex = exf->position.x - xf->position.x;
                f32 ey = exf->position.y - xf->position.y;
                f32 ez = exf->position.z - xf->position.z;
                if (sqrtf(ex*ex + ey*ey + ez*ez) <= kProximityR) detonated = true;
            });
            if (detonated) { proj.active = false; still = false; }
        }

        if (!still) SpawnExplosion(xf->position);
    });
}

void GameSim::SpawnExplosion(Vec3 pos) {
    if (m_explosionCount < kMaxExplosionsLocal)
        m_explosions[m_explosionCount++] = ExplosionState{ pos };
}

void GameSim::TickExplosions(f32 dt) {
    int alive = 0;
    for (int i = 0; i < m_explosionCount; ++i) {
        m_explosions[i].elapsed += dt;
        if (m_explosions[i].elapsed < m_explosions[i].duration)
            m_explosions[alive++] = m_explosions[i];
    }
    m_explosionCount = alive;
}

// ─── Selection ring ID generation ────────────────────────────────────────────
// Each unit gets a unique SelectionRingComponent whose wave harmonics serve as its
// visual ID.  Ring 2 (outer) is shared within a spawn batch; rings 0+1 are unique.
static uint32_t SRHash(uint32_t s) {
    s ^= (s << 13); s ^= (s >> 17); s ^= (s << 5); return s;
}
static float SRHashF(uint32_t s) {
    return (float)(SRHash(s) & 0xFFFFu) * (1.0f / 65535.0f);
}
static SelectionRingComponent MakeSelectionRing(uint32_t unitSeed, uint32_t batchSeed) {
    SelectionRingComponent rc{};
    const float kFreqs[4]  = { 2.0f, 3.0f, 5.0f, 7.0f };
    constexpr float kAmpLo = 0.008f, kAmpHi = 0.025f;
    const float kBaseSpeed[3] = { 1.2f, 0.75f, 0.45f };
    const float kDeviation[3] = { 0.3f, 0.20f, 0.15f };

    for (int r = 0; r < 2; ++r) {  // rings 0 and 1: unique per unit
        for (int h = 0; h < 4; ++h) {
            uint32_t s = SRHash(unitSeed * 997u + (uint32_t)(r * 31 + h * 7));
            rc.waves[r][h].amp   = kAmpLo + SRHashF(s)      * (kAmpHi - kAmpLo);
            rc.waves[r][h].freq  = kFreqs[h];
            rc.waves[r][h].phase = SRHashF(s + 1u) * 6.28318f;
        }
        rc.rotSpeed[r] = kBaseSpeed[r]
            + (SRHashF(SRHash(unitSeed * 43u + (uint32_t)r)) - 0.5f) * 2.0f * kDeviation[r];
    }
    for (int h = 0; h < 4; ++h) {  // ring 2: shared per spawn batch
        uint32_t s = SRHash(batchSeed * 997u + (uint32_t)(2 * 31 + h * 7));
        rc.waves[2][h].amp   = kAmpLo + SRHashF(s)      * (kAmpHi - kAmpLo);
        rc.waves[2][h].freq  = kFreqs[h];
        rc.waves[2][h].phase = SRHashF(s + 1u) * 6.28318f;
    }
    rc.rotSpeed[2] = kBaseSpeed[2]
        + (SRHashF(SRHash(batchSeed * 43u + 2u)) - 0.5f) * 2.0f * kDeviation[2];
    return rc;
}

static uint32_t sUnitSeedCtr  = 0;
static uint32_t sBatchSeedCtr = 0;

void GameSim::SpawnInitialScene() {
    // Six shadow-disc units scattered near center, two per player
    const Vec3 discPositions[6] = {
        Vec3Make(-2.3f, 0,  -1.7f),
        Vec3Make( 1.8f, 0,  -2.9f),
        Vec3Make( 3.1f, 0,   0.6f),
        Vec3Make(-0.7f, 0,   2.8f),
        Vec3Make( 2.4f, 0,   2.1f),
        Vec3Make(-3.2f, 0,   0.4f),
    };
    const PlayerSlot slots[6] = {
        PlayerSlot::P1, PlayerSlot::P2, PlayerSlot::P3,
        PlayerSlot::P1, PlayerSlot::P2, PlayerSlot::P3,
    };

    uint32_t batchSeed = SRHash(++sBatchSeedCtr * 7919u);
    for (int i = 0; i < 6; ++i) {
        uint32_t unitSeed = SRHash(++sUnitSeedCtr * 6271u);
        EntityID e = m_world.CreateEntity();
        m_world.Transforms().Add(e, TransformComponent{ discPositions[i] });
        m_world.Ownerships().Add(e, OwnershipComponent{ slots[i] });
        m_world.Selections().Add(e, SelectionComponent{});
        m_world.Commands().Add(e, CommandQueueComponent{});
        m_world.Moves().Add(e, MoveComponent{});
        m_world.Healths().Add(e, HealthComponent{});
        m_world.AIControllers().Add(e, AIControllerComponent{ .autonomy = AutonomyMode::Assisted });
        m_world.PathFollowers().Add(e, PathFollowerComponent{});
        m_world.UnitTypes().Add(e, UnitTypeComponent{ UnitType::ShadowDisc });
        m_world.Renderables().Add(e, RenderableComponent{ .castShadow = false });
        m_world.SelectionRings().Add(e, MakeSelectionRing(unitSeed, batchSeed));
    }

    // Four enemy units at map corners — unselectable, wander autonomously.
    constexpr f32 kCorner = 12.0f;
    const Vec3 cornerPositions[4] = {
        Vec3Make(-kCorner, 0,  kCorner),
        Vec3Make( kCorner, 0,  kCorner),
        Vec3Make( kCorner, 0, -kCorner),
        Vec3Make(-kCorner, 0, -kCorner),
    };
    uint32_t enemyBatchSeed = SRHash(++sBatchSeedCtr * 7919u);
    for (int i = 0; i < 4; ++i) {
        uint32_t unitSeed = SRHash(++sUnitSeedCtr * 6271u);
        EntityID e = m_world.CreateEntity();
        m_world.Transforms().Add(e, TransformComponent{ cornerPositions[i] });
        m_world.Ownerships().Add(e, OwnershipComponent{ PlayerSlot::None });
        m_world.Moves().Add(e, MoveComponent{});
        m_world.Healths().Add(e, HealthComponent{});
        AIControllerComponent aiComp{};
        aiComp.autonomy   = AutonomyMode::Wandering;
        aiComp.wanderPhase = static_cast<f32>(i) * 1.5708f;
        m_world.AIControllers().Add(e, std::move(aiComp));
        m_world.UnitTypes().Add(e, UnitTypeComponent{ UnitType::ShadowDisc });
        m_world.Renderables().Add(e, RenderableComponent{ .castShadow = false });
        m_world.Selections().Add(e, SelectionComponent{});
        m_world.SelectionRings().Add(e, MakeSelectionRing(unitSeed, enemyBatchSeed));
    }

    // Three stationary enemies on the far side of the map — black, unselectable.
    const Vec3 stationaryPositions[3] = {
        Vec3Make(-4.0f, 0, -11.0f),
        Vec3Make( 0.0f, 0, -11.0f),
        Vec3Make( 4.0f, 0, -11.0f),
    };
    uint32_t statBatchSeed = SRHash(++sBatchSeedCtr * 7919u);
    for (int i = 0; i < 3; ++i) {
        uint32_t unitSeed = SRHash(++sUnitSeedCtr * 6271u);
        EntityID e = m_world.CreateEntity();
        m_world.Transforms().Add(e, TransformComponent{ stationaryPositions[i] });
        m_world.Ownerships().Add(e, OwnershipComponent{ PlayerSlot::None });
        m_world.Healths().Add(e, HealthComponent{});
        AIControllerComponent aiComp{};
        aiComp.autonomy = AutonomyMode::Stationary;
        m_world.AIControllers().Add(e, std::move(aiComp));
        m_world.UnitTypes().Add(e, UnitTypeComponent{ UnitType::ShadowDisc });
        m_world.Renderables().Add(e, RenderableComponent{ .castShadow = false });
        m_world.Selections().Add(e, SelectionComponent{});
        m_world.SelectionRings().Add(e, MakeSelectionRing(unitSeed, statBatchSeed));
    }

}

EntityID GameSim::SpawnProjectile(Vec3 position, Vec3 velocity, PlayerSlot owner, bool targetedStationary) {
    EntityID e = m_world.CreateEntity();
    m_world.Transforms().Add(e, TransformComponent{ position, {}, 0.15f });
    m_world.Projectiles().Add(e, ProjectileComponent{
        .velocity           = velocity,
        .owner              = owner,
        .targetedStationary = targetedStationary,
    });
    m_world.Ownerships().Add(e, OwnershipComponent{ owner });
    m_world.Renderables().Add(e, RenderableComponent{
        .tint = PlayerColor(owner),
        .castShadow = false,
    });
    m_world.UnitTypes().Add(e, UnitTypeComponent{ UnitType::Projectile });
    LOG_DBG("GameSim", "Spawned projectile for player %d", static_cast<int>(owner));
    return e;
}

EntityID GameSim::PickEntity(Vec3 rayOrigin, Vec3 rayDir) const {
    EntityID best {};
    f32 bestT = std::numeric_limits<f32>::max();

    const_cast<World&>(m_world).Selections().ForEach([&](EntityID id, SelectionComponent& sel) {
        auto* xf = const_cast<World&>(m_world).Transforms().Get(id);
        if (!xf) return;

        // Ray-sphere intersection
        Vec3 oc = Vec3Make(
            rayOrigin.x - xf->position.x,
            rayOrigin.y - xf->position.y,
            rayOrigin.z - xf->position.z);
        f32 b  = Vec3Dot(oc, rayDir);
        f32 c  = Vec3Dot(oc, oc) - sel.radius * sel.radius;
        f32 disc = b*b - c;
        if (disc < 0) return;
        f32 t = -b - sqrtf(disc);
        if (t > 0 && t < bestT) { bestT = t; best = id; }
    });

    return best;
}

void GameSim::TickSeparation() {
    static constexpr f32 kMinDist      = 1.05f; // two discs of r=0.5 + small gap
    static constexpr f32 kPushStrength = 0.4f;

    EntityID entities[256];
    int count = 0;
    m_world.Moves().ForEach([&](EntityID id, MoveComponent&) {
        if (m_world.Transforms().Get(id) && count < 256)
            entities[count++] = id;
    });

    for (int i = 0; i < count; ++i) {
        for (int j = i + 1; j < count; ++j) {
            auto* xfi = m_world.Transforms().Get(entities[i]);
            auto* xfj = m_world.Transforms().Get(entities[j]);
            if (!xfi || !xfj) continue;
            f32 dx = xfj->position.x - xfi->position.x;
            f32 dz = xfj->position.z - xfi->position.z;
            f32 distSq = dx*dx + dz*dz;
            if (distSq >= kMinDist * kMinDist || distSq < 1e-6f) continue;
            f32 dist   = sqrtf(distSq);
            f32 push   = (kMinDist - dist) * kPushStrength;
            f32 nx = dx / dist;
            f32 nz = dz / dist;
            xfi->position.x -= nx * push;
            xfi->position.z -= nz * push;
            xfj->position.x += nx * push;
            xfj->position.z += nz * push;
        }
    }
}
