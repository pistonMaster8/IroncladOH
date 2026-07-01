#include "UDPTransport.hpp"
#include "../../Core/Log.hpp"
#include <cstring>
#include <cerrno>

#if defined(_WIN32)
#  include <winsock2.h>
#  include <ws2tcpip.h>
#  pragma comment(lib, "Ws2_32.lib")
   using socklen_t = int;
#else
#  include <sys/socket.h>
#  include <netinet/in.h>
#  include <arpa/inet.h>
#  include <fcntl.h>
#  include <unistd.h>
#endif

UDPTransport::UDPTransport() = default;

UDPTransport::~UDPTransport() { Close(); }

bool UDPTransport::Bind(u16 port) {
    m_sockFd = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (m_sockFd < 0) {
        LOG_ERR("Net", "socket() failed: %s", strerror(errno));
        return false;
    }

    // Non-blocking
#if !defined(_WIN32)
    fcntl(m_sockFd, F_SETFL, O_NONBLOCK);
#endif

    int reuse = 1;
    setsockopt(m_sockFd, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));

    sockaddr_in addr {};
    addr.sin_family      = AF_INET;
    addr.sin_port        = htons(port);
    addr.sin_addr.s_addr = INADDR_ANY;

    if (bind(m_sockFd, reinterpret_cast<sockaddr*>(&addr), sizeof(addr)) < 0) {
        LOG_ERR("Net", "bind() failed on port %u: %s", port, strerror(errno));
        Close();
        return false;
    }

    LOG_INF("Net", "UDP socket bound on port %u", port);
    return true;
}

void UDPTransport::Close() {
    if (m_sockFd >= 0) {
#if defined(_WIN32)
        closesocket(m_sockFd);
#else
        close(m_sockFd);
#endif
        m_sockFd = -1;
    }
}

bool UDPTransport::IsOpen() const { return m_sockFd >= 0; }

bool UDPTransport::Send(const Endpoint& to, const u8* data, u32 len) {
    if (!IsOpen()) return false;
    sockaddr_in addr {};
    addr.sin_family = AF_INET;
    addr.sin_port   = htons(to.port);
    inet_pton(AF_INET, to.address, &addr.sin_addr);
    ssize_t sent = sendto(m_sockFd, data, len, 0,
                          reinterpret_cast<sockaddr*>(&addr), sizeof(addr));
    return sent == static_cast<ssize_t>(len);
}

void UDPTransport::Poll(RecvCallback cb) {
    if (!IsOpen()) return;
    static u8 buf[2048];
    sockaddr_in from {};
    socklen_t fromLen = sizeof(from);

    for (;;) {
        ssize_t n = recvfrom(m_sockFd, buf, sizeof(buf), 0,
                             reinterpret_cast<sockaddr*>(&from), &fromLen);
        if (n <= 0) break; // EAGAIN / EWOULDBLOCK = no more data

        Endpoint ep;
        inet_ntop(AF_INET, &from.sin_addr, ep.address, sizeof(ep.address));
        ep.port = ntohs(from.sin_port);
        cb(ep, buf, static_cast<u32>(n));
    }
}

Endpoint UDPTransport::LocalEndpoint() const {
    sockaddr_in addr {};
    socklen_t len = sizeof(addr);
    getsockname(m_sockFd, reinterpret_cast<sockaddr*>(&addr), &len);
    Endpoint ep;
    inet_ntop(AF_INET, &addr.sin_addr, ep.address, sizeof(ep.address));
    ep.port = ntohs(addr.sin_port);
    return ep;
}
