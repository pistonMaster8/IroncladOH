#pragma once
#include "../../Core/Types.hpp"
#include <functional>
#include <string>

// ─── Platform-agnostic UDP socket wrapper ────────────────────────────────────
// Thin POSIX socket wrapper. Works on macOS, iOS (UDP allowed), and Linux.
// App Store note: TCP fallback can wrap this for review compliance.

struct Endpoint {
    char    address[64] {};   // IPv4 or IPv6 string
    u16     port        { 0 };

    bool operator==(const Endpoint& o) const {
        return port == o.port && strcmp(address, o.address) == 0;
    }
};

using RecvCallback = std::function<void(const Endpoint& from, const u8* data, u32 len)>;

class UDPTransport {
public:
    UDPTransport();
    ~UDPTransport();

    // Bind to local port (server) or 0 for ephemeral client port
    bool Bind(u16 port);
    void Close();
    bool IsOpen() const;

    // Non-blocking send
    bool Send(const Endpoint& to, const u8* data, u32 len);

    // Poll for received packets (calls cb for each)
    void Poll(RecvCallback cb);

    // Simulate network conditions (dev builds only)
    void SetSimulatedLatencyMs(f32 ms) { m_simLatencyMs = ms; }
    void SetSimulatedLossRate (f32 r)  { m_simLossRate  = r; }  // 0..1

    Endpoint LocalEndpoint() const;

private:
    int   m_sockFd        { -1 };
    f32   m_simLatencyMs  { 0.0f };
    f32   m_simLossRate   { 0.0f };
};
