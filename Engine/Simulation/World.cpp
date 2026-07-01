#include "World.hpp"
#include <algorithm>

EntityID World::CreateEntity() {
    u32 index;
    if (!m_freeSlots.empty()) {
        index = m_freeSlots.back();
        m_freeSlots.pop_back();
    } else {
        index = static_cast<u32>(m_generations.size());
        m_generations.push_back(0);
    }

    EntityID id;
    id.index = index;
    id.gen   = m_generations[index];
    m_alive.push_back(id);
    return id;
}

void World::DestroyEntity(EntityID id) {
    if (!IsAlive(id)) return;

    // Bump generation to invalidate outstanding handles
    m_generations[id.index]++;
    m_freeSlots.push_back(id.index);

    auto it = std::find(m_alive.begin(), m_alive.end(), id);
    if (it != m_alive.end()) m_alive.erase(it);

    // Remove from all component storages
    m_transforms.Remove(id);
    m_renderables.Remove(id);
    m_ownerships.Remove(id);
    m_selections.Remove(id);
    m_commands.Remove(id);
    m_moves.Remove(id);
    m_healths.Remove(id);
    m_projectiles.Remove(id);
    m_aiControllers.Remove(id);
    m_pathFollowers.Remove(id);
    m_perceptions.Remove(id);
    m_unitTypes.Remove(id);
}

bool World::IsAlive(EntityID id) const {
    if (id.index >= m_generations.size()) return false;
    return m_generations[id.index] == id.gen;
}
