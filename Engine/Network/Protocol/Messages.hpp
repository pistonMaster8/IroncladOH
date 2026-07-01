#pragma once
#include "../../Core/Types.hpp"
#include "../../Core/Math.hpp"
#include "../../Simulation/Components.hpp"
#include <cstring>
#include <cassert>

// ─── Protocol versioning ──────────────────────────────────────────────────────
constexpr u16 kNetProtocolVersion = 1;  // bump on incompatible changes
constexpr u16 kAssetVersion       = 1;
constexpr u32 kSimTickRateHertz   = 60;

// ─── Message type IDs ─────────────────────────────────────────────────────────
enum class MsgType : u8 {
    // Handshake
    Handshake       = 0x01,
    HandshakeAck    = 0x02,
    Reject          = 0x03,

    // Lobby
    LobbyJoin       = 0x10,
    LobbyJoinAck    = 0x11,
    LobbyState      = 0x12,
    LobbyReady      = 0x13,
    MatchStart      = 0x14,

    // Gameplay (per-tick, compact)
    CommandPacket   = 0x20,
    Snapshot        = 0x21,
    DeltaSnapshot   = 0x22,
    EventPacket     = 0x23,

    // Control
    Ping            = 0x30,
    Pong            = 0x31,
    Disconnect      = 0x40,
    Kick            = 0x41,
    Resync          = 0x50,

    // Debug / dev builds only
    ServerStats     = 0xF0,
};

// ─── Compact binary message header ────────────────────────────────────────────
// All messages start with this 8-byte header.
#pragma pack(push, 1)
struct MsgHeader {
    MsgType type    {};
    u8      flags   { 0 };
    u16     seq     { 0 };  // sender sequence number
    u16     ack     { 0 };  // last received sequence from remote
    u16     length  { 0 };  // payload bytes after header
};
static_assert(sizeof(MsgHeader) == 8);

// ─── Handshake ────────────────────────────────────────────────────────────────
struct MsgHandshake {
    MsgHeader hdr   { MsgType::Handshake };
    u16 protoVersion{ kNetProtocolVersion };
    u16 assetVersion{ kAssetVersion };
    u32 tickRate    { kSimTickRateHertz };
    char devName[32]{};  // dev identity, not account; empty in release
};

struct MsgHandshakeAck {
    MsgHeader hdr   { MsgType::HandshakeAck };
    u8  playerSlot  { 0 };  // assigned 1-3
    u32 matchSeed   { 0 };
};

struct MsgReject {
    MsgHeader hdr    { MsgType::Reject };
    u8        reason { 0 };
    char      msg[64]{};
};

// ─── Lobby ────────────────────────────────────────────────────────────────────
struct MsgLobbyState {
    MsgHeader hdr { MsgType::LobbyState };
    u8  playerCount    { 0 };
    u8  readyMask      { 0 };  // bit per player slot
    u8  slotsOccupied  { 0 };  // bit per slot
    char mapName[32]   {};
};

struct MsgLobbyReady {
    MsgHeader hdr { MsgType::LobbyReady };
    u8 ready { 0 };
};

struct MsgMatchStart {
    MsgHeader hdr  { MsgType::MatchStart };
    u32 seed       { 0 };
    u8  playerSlot { 0 };
    u32 startTick  { 0 };
};

// ─── Gameplay ─────────────────────────────────────────────────────────────────
// Compact command: 24 bytes
struct NetCommand {
    u8   type     { 0 };   // CommandType
    u8   player   { 0 };   // PlayerSlot
    u16  _pad     { 0 };
    f32  targetX  { 0 };
    f32  targetY  { 0 };
    f32  targetZ  { 0 };
    u32  entityId { 0 };   // target entity index, 0 = none
    u64  tick     { 0 };
};
static_assert(sizeof(NetCommand) == 28);

struct MsgCommandPacket {
    MsgHeader  hdr { MsgType::CommandPacket };
    u8         cmdCount { 0 };
    NetCommand cmds[4];   // max 4 commands per packet
};

// Replicated unit state: 32 bytes
struct NetUnitState {
    u32 entityId    { 0 };
    f32 x, y, z    {};
    f32 velX, velY, velZ {};
    u8  playerSlot  { 0 };
    u8  health      { 255 };  // 0-255 mapped from 0%-100%
    u8  aiState     { 0 };
    u8  flags       { 0 };    // bit0=selected, bit1=active, bit2=projectile
};
static_assert(sizeof(NetUnitState) == 32);

struct MsgSnapshot {
    MsgHeader    hdr { MsgType::Snapshot };
    u64          tick { 0 };
    u16          unitCount { 0 };
    // NetUnitState units[unitCount] follow in packet (variable length)
};

// ─── Ping/Pong ───────────────────────────────────────────────────────────────
struct MsgPing {
    MsgHeader hdr   { MsgType::Ping };
    u64       clientTime { 0 };
};
struct MsgPong {
    MsgHeader hdr       { MsgType::Pong };
    u64       clientTime { 0 };
    u64       serverTime { 0 };
};

// ─── Disconnect ──────────────────────────────────────────────────────────────
struct MsgDisconnect {
    MsgHeader hdr    { MsgType::Disconnect };
    u8        reason { 0 };
    char      msg[48]{};
};

#pragma pack(pop)

// ─── Reliability layer helpers ────────────────────────────────────────────────
// Simple ACK bitfield: tracks last 16 received packets.
struct AckState {
    u16 lastAcked { 0 };
    u16 ackBits   { 0 };  // bit N = packet (lastAcked - N) was received

    void Record(u16 seq) {
        if (seq == lastAcked + 1) {
            ackBits = (ackBits << 1) | 1;
            lastAcked = seq;
        } else {
            // Out of order / gap
            i16 diff = static_cast<i16>(seq - lastAcked);
            if (diff > 0) {
                ackBits = (ackBits >> diff) | (1 << (16 - diff));
                lastAcked = seq;
            }
        }
    }

    bool WasReceived(u16 seq) const {
        i16 diff = static_cast<i16>(lastAcked - seq);
        if (diff < 0 || diff >= 16) return false;
        return (ackBits & (1 << diff)) != 0;
    }
};
