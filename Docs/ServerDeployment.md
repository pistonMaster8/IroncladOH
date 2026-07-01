# PostFall — Dedicated Server Deployment (M4 Mac mini)

## Prerequisites
- macOS 15+ (Sequoia) on M4 Mac mini
- Xcode Command Line Tools: `xcode-select --install`
- CMake 3.26+: `brew install cmake`

---

## Build

```bash
git clone <repo> /opt/postfall
cd /opt/postfall
cmake -B build -DCMAKE_BUILD_TYPE=Release
cd build && make -j$(sysctl -n hw.ncpu) PostFallServer
```

Binary: `/opt/postfall/build/bin/PostFallServer`

---

## Configuration file

`/opt/postfall/server.conf` (TOML-style, parsed by server at startup):

```toml
port = 7777
tickRateHz = 60
maxMatches = 4
map = "default"
logDir = "/var/log/postfall"
devMode = false
```

Launch with:
```bash
./PostFallServer --port 7777 --log /var/log/postfall
```

---

## launchd service (recommended for persistent server)

Save to `/Library/LaunchDaemons/com.postfall.server.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.postfall.server</string>
  <key>ProgramArguments</key>
  <array>
    <string>/opt/postfall/build/bin/PostFallServer</string>
    <string>--port</string>
    <string>7777</string>
    <string>--log</string>
    <string>/var/log/postfall</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>StandardOutPath</key>
  <string>/var/log/postfall/server.log</string>
  <key>StandardErrorPath</key>
  <string>/var/log/postfall/server.err</string>
  <key>ThrottleInterval</key>
  <integer>5</integer>
</dict>
</plist>
```

```bash
# Install and start
sudo launchctl load /Library/LaunchDaemons/com.postfall.server.plist
sudo launchctl start com.postfall.server

# Stop
sudo launchctl stop com.postfall.server

# Check status
sudo launchctl list | grep postfall

# View logs
tail -f /var/log/postfall/server.log
```

---

## Firewall

Open UDP port 7777 in macOS firewall:
```bash
sudo /usr/libexec/ApplicationFirewall/socketfilterfw --add /opt/postfall/build/bin/PostFallServer
```

If behind a NAT router: forward UDP 7777 to the Mac mini's local IP.

---

## Server metrics

Metrics are printed to the log every 10 seconds:
```
[INF][ServerMetrics] matches=1 clients=3 in=12.4KB out=84.2KB pktsIn=1200 pktsOut=4000
```

---

## Future: Linux / Third-Party Hosting

The server uses only POSIX APIs (socket, bind, recvfrom, sendto, fcntl). It has no dependency on Metal, AppKit, or any Apple-specific framework.

To build for Linux:
```bash
cmake -B build_linux -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++
make PostFallServer
```

Hosted platforms tested or planned:
- **macOS M4 Mac mini** — current primary playtest server
- **Ubuntu 22.04 / Hetzner CAX11** — planned Linux deployment
- **Fly.io (Machines)** — planned containerized deployment
- AWS/GCP/Azure — viable with the same binary

Docker compatibility: planned. Add `Dockerfile` and `docker-compose.yml` once Linux build is verified.
