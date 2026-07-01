#pragma once
#include "../Simulation/GameSim.hpp"
#include "../Network/Transport/UDPTransport.hpp"
#include "../Network/Protocol/Messages.hpp"
#include <vector>
#include <string>
#include <memory>
#include <functional>

// ─── Server configuration ─────────────────────────────────────────────────────
struct ServerConfig {
    u16         port            { 7777 };
    u32         maxMatches      { 4 };
    u32         tickRateHz      { kSimTickRateHertz };
    std::string mapName         { "default" };
    std::string logDir          { "." };
    bool        devMode         { false };
    bool        verboseLogging  { false };
};

// ─── Connected client slot ────────────────────────────────────────────────────
struct ClientSlot {
    Endpoint    endpoint        {};
    PlayerSlot  playerSlot      { PlayerSlot::None };
    bool        connected       { false };
    bool        ready           { false };
    u64         lastPingTick    { 0 };
    f32         latencyMs       { 0.0f };
    u16         lastSeqRecv     { 0 };
    u16         sendSeq         { 0 };
    AckState    ackState        {};
};

// ─── Match state ──────────────────────────────────────────────────────────────
enum class MatchPhase : u8 { Lobby, Running, Finished };

struct MatchState {
    MatchPhase phase   { MatchPhase::Lobby };
    u32        seed    { 0 };
    u64        tick    { 0 };
    ClientSlot clients[3] {};      // exactly 3 player slots
    u32        clientCount { 0 };
    std::unique_ptr<GameSim> sim;
};

// ─── Server metrics ───────────────────────────────────────────────────────────
struct ServerMetrics {
    u32 activeMatches  { 0 };
    u32 connectedClients{ 0 };
    f64 avgTickTimeMs  { 0 };
    u64 bytesIn        { 0 };
    u64 bytesOut       { 0 };
    u64 packetsIn      { 0 };
    u64 packetsOut     { 0 };
};

// ─── ServerInstance ───────────────────────────────────────────────────────────
// Headless, no renderer, no audio. Runs the authoritative simulation.
// Designed to compile and run on macOS and Linux.
class ServerInstance {
public:
    explicit ServerInstance(const ServerConfig& cfg);
    ~ServerInstance();

    bool Start();
    void RunFrame();   // Call in a tight loop; handles timing internally
    void Stop();

    bool IsRunning() const { return m_running; }

    const ServerMetrics& Metrics() const { return m_metrics; }
    void PrintMetrics() const;

private:
    void TickNetwork();
    void TickMatches();
    void HandlePacket(const Endpoint& from, const u8* data, u32 len);

    void HandleHandshake   (const Endpoint& from, const MsgHandshake& msg);
    void HandleLobbyReady  (const Endpoint& from, const MsgLobbyReady& msg);
    void HandleCommandPacket(const Endpoint& from, const MsgCommandPacket& msg);
    void HandlePing        (const Endpoint& from, const MsgPing& msg);
    void HandleDisconnect  (const Endpoint& from, const MsgDisconnect& msg);

    void SendSnapshot(MatchState& match, ClientSlot& client);
    void SendTo(const Endpoint& to, const u8* data, u32 len);

    ClientSlot* FindClient(const Endpoint& ep, MatchState& match);

    ServerConfig    m_cfg;
    UDPTransport    m_transport;
    MatchState      m_match;       // single match for MVP
    ServerMetrics   m_metrics;
    bool            m_running   { false };
    f64             m_nextTickTime { 0.0 };

    // Simple high-res timer
    static f64 NowSeconds();
};
