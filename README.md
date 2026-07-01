# IroncladOH

IroncladOH is a C++20/Metal strategy-game prototype with a Swift macOS shell, a
headless dedicated server, and unit tests for simulation, physics, and network
protocol code.

## Requirements

For the macOS game app:

- macOS 14 or newer
- Xcode 15.2 or newer
- CMake 3.26 or newer
- Apple Silicon Mac recommended

For the dedicated server/tests:

- CMake 3.26 or newer
- C++20 compiler
- On macOS, Xcode Command Line Tools are enough for headless targets

Install CMake on macOS with:

```sh
brew install cmake
```

## Clone

```sh
git clone https://github.com/pistonMaster8/IroncladOH.git
cd IroncladOH
```

## Build And Run The macOS App

```sh
cmake --preset xcode-macos
cmake --build --preset xcode-macos --config Debug --target IroncladOH
open build/xcode/bin/Debug/IroncladOH.app
```

Or use the helper:

```sh
./Scripts/run_macos_app.sh
```

You can also open `build/xcode/IroncladOH.xcodeproj` and run the `IroncladOH`
scheme from Xcode. If signing is required on the target Mac, set your
development team in Signing & Capabilities.

## Dedicated Server

```sh
cmake --preset server-debug
cmake --build --preset server-debug --target IroncladOHServer
./build/server-debug/bin/IroncladOHServer --port 7777 --dev --verbose
```

Helper:

```sh
./Scripts/run_server.sh
```

## Tests

```sh
cmake --preset server-debug
cmake --build --preset server-debug
ctest --test-dir build/server-debug --output-on-failure
```

Helper:

```sh
./Scripts/test.sh
```

## Repository Contents

- `Apps/MacGame` - Swift/ObjC++ macOS app shell
- `Apps/DedicatedServer` - headless server executable
- `Engine` - C++ engine, simulation, renderer, animation, networking, AI
- `PlaceholderModels` - bundled placeholder glTF models
- `Tools/AssetCooker` - asset cooking tool scaffold
- `Tests` - headless C++ test targets
- `Docs` - architecture, build, and deployment notes

Generated build directories are intentionally ignored. A fresh clone should build
from source using the commands above. The Swift macOS app uses the Xcode
generator; the headless server/tests use normal Unix Makefiles.
