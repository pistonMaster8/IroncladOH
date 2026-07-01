#include "ServerInstance.hpp"
#include "../Core/Log.hpp"
#include <cstring>
#include <ctime>
#include <chrono>
#include <thread>

ServerInstance::ServerInstance(const ServerConfig& cfg) : m_cfg(cfg) {}
ServerInstance::~ServerInstance() { Stop(); }

f64 ServerInstance::NowSeconds() {
    using namespace std::chrono;
    return duration_cast<duration<f64>>(
        steady_clock::now().time_since_epoch()).count();
}

bool ServerInstance::Start() {
    if (!m_transport.Bind(m_cfg.port)) {
        LOG_ERR("Server", "Failed to bind UDP port %u", m_cfg.port);
        return false;
    }
    m_running      = true;
    m_nextTickTime = NowSeconds();
    LOG_INF("Server", "PostFall dedicated server started on port %u (tick %u Hz)",
            m_cfg.port, m_cfg.tickRateHz);
    return true;
}

void ServerInstance::RunFrame() {
    f64 now = NowSeconds();
    if (now >= m_nextTickTime) {
        TickNetwork();
        TickMatches();
        m_nextTickTime += 1.0 / static_cast<f64>(m_cfg.tickRateHz);
    } else {
        // Brief sleep to avoid burning 100% CPU
        std::this_thread::sleep_for(std::chrono::milliseconds(1));
    }
}

void ServerInstance::Stop() {
    if (m_running) {
        m_running = false;
        m_transport.Close();
        LOG_INF("Server", "Server stopped.");
    }
}

void ServerInstance::TickNetwork() {
    m_transport.Poll([&](const Endpoint& from, const u8* data, u32 len) {
        m_metrics.bytesIn   += len;
        m_metrics.packetsIn += 1;
        HandlePacket(from, data, len);
    });
}

void ServerInstance::HandlePacket(const Endpoint& from, const u8* data, u32 len) {
    if (len < sizeof(MsgHeader)) return;

    MsgHeader hdr;
    memcpy(&hdr, data, sizeof(hdr));

    switch (hdr.type) {
        case MsgType::Handshake: {
            if (len < sizeof(MsgHandshake)) break;
            MsgHandshake msg; memcpy(&msg, data, sizeof(msg));
            HandleHandshake(from, msg);
            break;
        }
        case MsgType::LobbyReady: {
            if (len < sizeof(MsgLobbyReady)) break;
            MsgLobbyReady msg; memcpy(&msg, data, sizeof(msg));
            HandleLobbyReady(from, msg);
            break;
        }
        case MsgType::CommandPacket: {
            if (len < sizeof(MsgHeader) + 1) break;
            MsgCommandPacket msg; memcpy(&msg, data, sizeof(msg));
            HandleCommandPacket(from, msg);
            break;
        }
        case MsgType::Ping: {
            if (len < sizeof(MsgPing)) break;
            MsgPing msg; memcpy(&msg, data, sizeof(msg));
            HandlePing(from, msg);
            break;
        }
        case MsgType::Disconnect: {
            if (len < sizeof(MsgDisconnect)) break;
            MsgDisconnect msg; memcpy(&msg, data, sizeof(msg));
            HandleDisconnect(from, msg);
            break;
        }
        default:
            LOG_WRN("Server", "Unknown packet type 0x%02x from %s:%u",
                    static_cast<u8>(hdr.type), from.address, from.port);
            break;
    }
}

void ServerInstance::HandleHandshake(const Endpoint& from, const MsgHandshake& msg) {
    if (msg.protoVersion != kNetProtocolVersion) {
        MsgReject reject;
        reject.reason = 1;
        snprintf(reject.msg, sizeof(reject.msg), "Protocol version mismatch: got %u, need %u",
                 msg.protoVersion, kNetProtocolVersion);
        SendTo(from, reinterpret_cast<const u8*>(&reject), sizeof(reject));
        return;
    }

    if (m_match.clientCount >= 3) {
        MsgReject reject;
        reject.reason = 2;
        snprintf(reject.msg, sizeof(reject.msg), "Match full (3/3 players)");
        SendTo(from, reinterpret_cast<const u8*>(&reject), sizeof(reject));
        return;
    }

    // Assign slot
    u32 slotIdx = m_match.clientCount++;
    auto& cs    = m_match.clients[slotIdx];
    cs.endpoint   = from;
    cs.playerSlot = static_cast<PlayerSlot>(slotIdx + 1);
    cs.connected  = true;

    MsgHandshakeAck ack;
    ack.playerSlot = static_cast<u8>(cs.playerSlot);
    ack.matchSeed  = 12345; // deterministic seed
    SendTo(from, reinterpret_cast<const u8*>(&ack), sizeof(ack));

    LOG_INF("Server", "Player %d connected from %s:%u (name: %.32s)",
            slotIdx+1, from.address, from.port, msg.devName);

    m_metrics.connectedClients++;
}

void ServerInstance::HandleLobbyReady(const Endpoint& from, const MsgLobbyReady& msg) {
    auto* cs = FindClient(from, m_match);
    if (!cs) return;
    cs->ready = (msg.ready != 0);

    LOG_INF("Server", "Player %d ready=%d", static_cast<int>(cs->playerSlot), cs->ready);

    // Start if all connected players ready
    bool allReady = true;
    u32 readyCount = 0;
    for (u32 i = 0; i < m_match.clientCount; ++i) {
        if (!m_match.clients[i].ready) allReady = false;
        else readyCount++;
    }

    if (allReady && m_match.clientCount == 3) {
        m_match.phase = MatchPhase::Running;
        m_match.sim   = std::make_unique<GameSim>();
        m_match.sim->SpawnInitialScene();

        for (u32 i = 0; i < m_match.clientCount; ++i) {
            MsgMatchStart startMsg;
            startMsg.seed       = m_match.seed;
            startMsg.playerSlot = static_cast<u8>(m_match.clients[i].playerSlot);
            startMsg.startTick  = 0;
            SendTo(m_match.clients[i].endpoint,
                   reinterpret_cast<const u8*>(&startMsg), sizeof(startMsg));
        }
        LOG_INF("Server", "Match started with 3 players!");
        m_metrics.activeMatches = 1;
    }
}

void ServerInstance::HandleCommandPacket(const Endpoint& from, const MsgCommandPacket& msg) {
    if (m_match.phase != MatchPhase::Running) return;
    auto* cs = FindClient(from, m_match);
    if (!cs || !m_match.sim) return;

    for (u8 i = 0; i < msg.cmdCount; ++i) {
        const auto& nc = msg.cmds[i];
        Command cmd;
        cmd.type      = static_cast<CommandType>(nc.type);
        cmd.targetPos = Vec3Make(nc.targetX, nc.targetY, nc.targetZ);
        cmd.issuer    = cs->playerSlot;
        cmd.tick      = nc.tick;
        m_match.sim->SubmitCommand(cs->playerSlot, cmd);
    }
}

void ServerInstance::HandlePing(const Endpoint& from, const MsgPing& msg) {
    MsgPong pong;
    pong.clientTime = msg.clientTime;
    // serverTime not implemented here (would use real clock)
    pong.serverTime = 0;
    SendTo(from, reinterpret_cast<const u8*>(&pong), sizeof(pong));
}

void ServerInstance::HandleDisconnect(const Endpoint& from, const MsgDisconnect& /*msg*/) {
    auto* cs = FindClient(from, m_match);
    if (!cs) return;
    LOG_INF("Server", "Player %d disconnected from %s:%u",
            static_cast<int>(cs->playerSlot), from.address, from.port);
    cs->connected = false;
    cs->ready     = false;
    m_metrics.connectedClients--;
}

void ServerInstance::TickMatches() {
    if (m_match.phase != MatchPhase::Running || !m_match.sim) return;

    constexpr f64 kTickDt = 1.0 / kSimTickRateHertz;
    m_match.sim->Advance(kTickDt);
    m_match.tick++;

    // Send snapshots every 3 ticks (~20 Hz at 60 Hz sim)
    if (m_match.tick % 3 == 0) {
        for (u32 i = 0; i < m_match.clientCount; ++i) {
            if (m_match.clients[i].connected)
                SendSnapshot(m_match, m_match.clients[i]);
        }
    }
}

void ServerInstance::SendSnapshot(MatchState& match, ClientSlot& client) {
    // Build snapshot packet (variable-length)
    static u8 buf[4096];
    MsgSnapshot header;
    header.tick = match.tick;

    auto& world = match.sim->GetWorld();
    constexpr u32 kMaxSnapshotUnits = 256;
    u32 unitCount = 0;
    NetUnitState units[kMaxSnapshotUnits];

    world.Transforms().ForEach([&](EntityID id, TransformComponent& xf) {
        if (unitCount >= kMaxSnapshotUnits) return;
        auto* proj = world.Projectiles().Get(id);
        auto* own  = world.Ownerships().Get(id);
        auto* hp   = world.Healths().Get(id);
        auto* ai   = world.AIControllers().Get(id);

        auto& u      = units[unitCount++];
        u.entityId   = id.index;
        u.x          = xf.position.x;
        u.y          = xf.position.y;
        u.z          = xf.position.z;
        u.playerSlot = own ? static_cast<u8>(own->owner) : 0;
        u.health     = hp  ? static_cast<u8>(255 * hp->current / (hp->max + 1e-6f)) : 255;
        u.aiState    = ai  ? static_cast<u8>(ai->state) : 0;
        u.flags      = proj ? 0x02 : 0x00;
        if (proj) {
            u.velX = proj->velocity.x;
            u.velY = proj->velocity.y;
            u.velZ = proj->velocity.z;
        }
    });

    header.unitCount = static_cast<u16>(unitCount);

    u32 offset = 0;
    memcpy(buf + offset, &header, sizeof(header)); offset += sizeof(header);
    memcpy(buf + offset, units,  unitCount * sizeof(NetUnitState)); offset += unitCount * sizeof(NetUnitState);

    SendTo(client.endpoint, buf, offset);
    m_metrics.bytesOut   += offset;
    m_metrics.packetsOut += 1;
}

void ServerInstance::SendTo(const Endpoint& to, const u8* data, u32 len) {
    m_transport.Send(to, data, len);
    m_metrics.bytesOut   += len;
    m_metrics.packetsOut += 1;
}

ClientSlot* ServerInstance::FindClient(const Endpoint& ep, MatchState& match) {
    for (u32 i = 0; i < match.clientCount; ++i) {
        auto& cs = match.clients[i];
        if (cs.endpoint == ep) return &cs;
    }
    return nullptr;
}

void ServerInstance::PrintMetrics() const {
    LOG_INF("ServerMetrics",
            "matches=%u clients=%u in=%.1fKB out=%.1fKB pktsIn=%llu pktsOut=%llu",
            m_metrics.activeMatches,
            m_metrics.connectedClients,
            m_metrics.bytesIn  / 1024.0,
            m_metrics.bytesOut / 1024.0,
            (unsigned long long)m_metrics.packetsIn,
            (unsigned long long)m_metrics.packetsOut);
}
