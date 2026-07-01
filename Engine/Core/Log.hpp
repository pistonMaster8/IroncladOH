#pragma once
#include "Types.hpp"
#include <cstdio>
#include <cstdarg>

enum class LogLevel : u8 {
    Debug   = 0,
    Info    = 1,
    Warning = 2,
    Error   = 3,
};

namespace Log {

inline LogLevel gMinLevel = LogLevel::Debug;

inline void SetMinLevel(LogLevel level) { gMinLevel = level; }

inline void Write(LogLevel level, const char* category, const char* fmt, ...) {
    if (level < gMinLevel) return;
    const char* prefix = "";
    switch (level) {
        case LogLevel::Debug:   prefix = "DBG"; break;
        case LogLevel::Info:    prefix = "INF"; break;
        case LogLevel::Warning: prefix = "WRN"; break;
        case LogLevel::Error:   prefix = "ERR"; break;
    }
    char buf[1024];
    va_list args;
    va_start(args, fmt);
    vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);
    fprintf(level >= LogLevel::Warning ? stderr : stdout,
            "[%s][%s] %s\n", prefix, category, buf);
}

} // namespace Log

#define LOG_DBG(cat, fmt, ...) ::Log::Write(LogLevel::Debug,   cat, fmt, ##__VA_ARGS__)
#define LOG_INF(cat, fmt, ...) ::Log::Write(LogLevel::Info,    cat, fmt, ##__VA_ARGS__)
#define LOG_WRN(cat, fmt, ...) ::Log::Write(LogLevel::Warning, cat, fmt, ##__VA_ARGS__)
#define LOG_ERR(cat, fmt, ...) ::Log::Write(LogLevel::Error,   cat, fmt, ##__VA_ARGS__)
