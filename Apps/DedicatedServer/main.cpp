// PostFall dedicated server — headless, no renderer, no audio.
// First-class macOS target; later Linux/Windows.
//
// Usage:
//   ./PostFallServer [--port 7777] [--tickrate 60] [--dev] [--log ./logs]

#include "../../Engine/Server/ServerInstance.hpp"
#include "../../Engine/Core/Log.hpp"
#include <cstdlib>
#include <cstring>
#include <csignal>
#include <iostream>

// ─── Signal handling for clean shutdown ──────────────────────────────────────
static volatile bool gRunning = true;
static void OnSignal(int) { gRunning = false; }

// ─── CLI argument parsing ─────────────────────────────────────────────────────
static ServerConfig ParseArgs(int argc, char** argv) {
    ServerConfig cfg;
    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--port") == 0 && i+1 < argc)
            cfg.port = static_cast<u16>(atoi(argv[++i]));
        else if (strcmp(argv[i], "--tickrate") == 0 && i+1 < argc)
            cfg.tickRateHz = static_cast<u32>(atoi(argv[++i]));
        else if (strcmp(argv[i], "--map") == 0 && i+1 < argc)
            cfg.mapName = argv[++i];
        else if (strcmp(argv[i], "--log") == 0 && i+1 < argc)
            cfg.logDir = argv[++i];
        else if (strcmp(argv[i], "--dev") == 0)
            cfg.devMode = true;
        else if (strcmp(argv[i], "--verbose") == 0)
            cfg.verboseLogging = true;
    }
    return cfg;
}

int main(int argc, char** argv) {
    signal(SIGINT,  OnSignal);
    signal(SIGTERM, OnSignal);

    LOG_INF("Server", "PostFall Dedicated Server v0.1 (proto %u)", kNetProtocolVersion);

    ServerConfig cfg = ParseArgs(argc, argv);
    if (cfg.verboseLogging) Log::SetMinLevel(LogLevel::Debug);

    ServerInstance server(cfg);
    if (!server.Start()) {
        LOG_ERR("Server", "Failed to start. Exiting.");
        return 1;
    }

    u64 frameCount = 0;
    while (gRunning && server.IsRunning()) {
        server.RunFrame();
        frameCount++;

        // Print metrics every 10 seconds (~600 ticks at 60Hz)
        if (frameCount % (cfg.tickRateHz * 10) == 0) {
            server.PrintMetrics();
        }
    }

    server.Stop();
    LOG_INF("Server", "Clean shutdown after %llu frames.", (unsigned long long)frameCount);
    return 0;
}
