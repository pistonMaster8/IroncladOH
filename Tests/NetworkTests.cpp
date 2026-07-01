// NetworkTests.cpp — Protocol and reliability layer tests.

#include "../Engine/Network/Protocol/Messages.hpp"
#include <cstdio>
#include <cstring>
#include <cassert>

static int gTests = 0;
static int gPassed = 0;

#define CHECK(expr) \
    do { gTests++; \
         if (expr) { gPassed++; } \
         else { fprintf(stderr, "FAIL: %s (line %d)\n", #expr, __LINE__); } \
    } while(0)

static void TestMessageSizes() {
    CHECK(sizeof(MsgHeader)         == 8);
    CHECK(sizeof(NetCommand)        == 28);
    CHECK(sizeof(NetUnitState)      == 32);
    CHECK(sizeof(MsgHandshake)      >= sizeof(MsgHeader));
    CHECK(sizeof(MsgCommandPacket)  >= sizeof(MsgHeader));
}

static void TestHandshakeSerialise() {
    MsgHandshake msg;
    msg.protoVersion = kNetProtocolVersion;
    msg.assetVersion = kAssetVersion;
    strncpy(msg.devName, "TestDev", sizeof(msg.devName)-1);

    // Verify round-trip through raw bytes
    u8 buf[sizeof(MsgHandshake)];
    memcpy(buf, &msg, sizeof(msg));
    MsgHandshake msg2;
    memcpy(&msg2, buf, sizeof(msg2));

    CHECK(msg2.protoVersion == kNetProtocolVersion);
    CHECK(strncmp(msg2.devName, "TestDev", 7) == 0);
}

static void TestAckBitfield() {
    AckState ack;

    ack.Record(1);
    CHECK(ack.lastAcked == 1);
    CHECK(ack.WasReceived(1));
    CHECK(!ack.WasReceived(2));

    ack.Record(2);
    ack.Record(3);
    CHECK(ack.WasReceived(1));
    CHECK(ack.WasReceived(2));
    CHECK(ack.WasReceived(3));
    CHECK(!ack.WasReceived(4));
}

static void TestProtocolVersion() {
    CHECK(kNetProtocolVersion == 1);
    CHECK(kSimTickRateHertz   == 60);
}

int main() {
    TestMessageSizes();
    TestHandshakeSerialise();
    TestAckBitfield();
    TestProtocolVersion();

    printf("Network tests: %d/%d passed\n", gPassed, gTests);
    return (gPassed == gTests) ? 0 : 1;
}
