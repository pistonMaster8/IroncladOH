cmake_minimum_required(VERSION 3.26)

project(IroncladOH
    VERSION 0.1.0
    LANGUAGES CXX C
)

option(IRONCLADOH_BUILD_APP "Build the Apple Swift/Metal app bundle" OFF)

# Objective-C++ and Swift are only needed for Apple app bundles. Keeping the
# default project C/C++ lets the dedicated server configure with Makefiles and on
# non-Apple hosts. Swift builds require the Xcode generator.
if (IRONCLADOH_BUILD_APP)
    if (NOT APPLE)
        message(FATAL_ERROR "IRONCLADOH_BUILD_APP requires Apple platforms")
    endif()
    enable_language(OBJCXX)
    enable_language(Swift)
endif()

# ─── Global C++ standard ──────────────────────────────────────────────────────
set(CMAKE_CXX_STANDARD          20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS        OFF)
set(CMAKE_OBJCXX_STANDARD       20)

# ─── Swift version ────────────────────────────────────────────────────────────
if (IRONCLADOH_BUILD_APP)
    set(CMAKE_Swift_LANGUAGE_VERSION 5)
endif()

# ─── Output directories ───────────────────────────────────────────────────────
set(CMAKE_RUNTIME_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/bin)
set(CMAKE_LIBRARY_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)
set(CMAKE_ARCHIVE_OUTPUT_DIRECTORY ${CMAKE_BINARY_DIR}/lib)

# ─── Compiler flags ───────────────────────────────────────────────────────────
if (CMAKE_CXX_COMPILER_ID MATCHES "Clang")
    set(PFGE_CXX_WARNINGS
        -Wall -Wextra -Wpedantic
        -Wshadow -Wno-unused-parameter
        -Wno-gnu-anonymous-struct)
    if (APPLE)
        list(APPEND PFGE_CXX_WARNINGS -Wno-nullability-extension)
    endif()
endif()

# ─── Platform detection ───────────────────────────────────────────────────────
if (APPLE)
    set(PFGE_PLATFORM_APPLE TRUE)
    if (CMAKE_SYSTEM_NAME STREQUAL "iOS")
        set(PFGE_PLATFORM_IOS TRUE)
    else()
        set(PFGE_PLATFORM_MACOS TRUE)
    endif()
endif()

# ─── Engine Core library ──────────────────────────────────────────────────────
add_library(EngineCore STATIC
    Engine/Simulation/World.cpp
    Engine/Simulation/GameSim.cpp
    Engine/Physics/PhysicsSystem.cpp
    Engine/AI/AISystem.cpp
    Engine/Network/Transport/UDPTransport.cpp
    Engine/Server/ServerInstance.cpp
    Engine/Animation/Core/Skeleton.cpp
    Engine/Animation/Core/Pose.cpp
    Engine/Animation/Runtime/AnimationClip.cpp
    Engine/Animation/Runtime/AnimationSampler.cpp
    Engine/Animation/Runtime/AnimationStateMachine.cpp
    Engine/Animation/Runtime/AnimationController.cpp
    Engine/Animation/IK/IKSolver.cpp
    Engine/Animation/Procedural/ProceduralAnimator.cpp
    Engine/Animation/Debug/AnimationDebug.cpp
)

target_include_directories(EngineCore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
target_compile_options(EngineCore PRIVATE ${PFGE_CXX_WARNINGS})
target_compile_definitions(EngineCore PUBLIC
    $<$<CONFIG:Debug>:PFGE_DEBUG=1>
)

# ─── Metal renderer (Apple only) ─────────────────────────────────────────────
if (PFGE_PLATFORM_APPLE AND IRONCLADOH_BUILD_APP)
    add_library(EngineRenderer STATIC
        Engine/Renderer/Metal/MetalRenderer.mm
    )
    target_include_directories(EngineRenderer PUBLIC ${CMAKE_CURRENT_SOURCE_DIR})
    target_compile_options(EngineRenderer PRIVATE ${PFGE_CXX_WARNINGS})

    find_library(METAL_LIB          Metal)
    find_library(METALKIT_LIB       MetalKit)
    find_library(QUARTZCORE_LIB     QuartzCore)
    find_library(FOUNDATION_LIB     Foundation)

    target_link_libraries(EngineRenderer PUBLIC
        EngineCore
        ${METAL_LIB}
        ${METALKIT_LIB}
        ${QUARTZCORE_LIB}
        ${FOUNDATION_LIB}
    )
endif()

# ─── Dedicated Server (headless, no renderer, macOS/Linux) ──────────────────
add_executable(IroncladOHServer
    Apps/DedicatedServer/main.cpp
)
target_link_libraries(IroncladOHServer PRIVATE EngineCore)
target_compile_options(IroncladOHServer PRIVATE ${PFGE_CXX_WARNINGS})

# ─── macOS Game app ───────────────────────────────────────────────────────────
if (PFGE_PLATFORM_MACOS AND IRONCLADOH_BUILD_APP)
    set(MACGAME_SWIFT_SOURCES
        Apps/MacGame/IroncladOHApp.swift
        Apps/MacGame/ContentView.swift
        Apps/MacGame/GameView.swift
    )
    set(MACGAME_OBJCXX_SOURCES
        Apps/MacGame/EngineHost.mm
    )

    set(CHARACTER_MODELS
        PlaceholderModels/Soldier.glb
    )
    set_source_files_properties(${CHARACTER_MODELS} PROPERTIES
        MACOSX_PACKAGE_LOCATION Resources
    )

    set(APP_ICON Apps/MacGame/Resources/AppIcon.icns)
    set_source_files_properties(${APP_ICON} PROPERTIES
        MACOSX_PACKAGE_LOCATION Resources
    )

    add_executable(IroncladOH MACOSX_BUNDLE
        ${MACGAME_SWIFT_SOURCES}
        ${MACGAME_OBJCXX_SOURCES}
        ${CHARACTER_MODELS}
        ${APP_ICON}
    )

    # Set the Objective-C++ bridging header for Swift
    set_target_properties(IroncladOH PROPERTIES
        XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/Apps/MacGame/EngineHost.h"
        XCODE_ATTRIBUTE_SWIFT_OBJC_INTERFACE_HEADER_NAME "IroncladOH-Swift.h"
        MACOSX_BUNDLE_BUNDLE_NAME "Ironclad-OH"
        MACOSX_BUNDLE_BUNDLE_IDENTIFIER "com.ironclad.oh"
        MACOSX_BUNDLE_GUI_IDENTIFIER    "com.ironclad.oh"
        MACOSX_BUNDLE_SHORT_VERSION_STRING "0.1"
        MACOSX_BUNDLE_ICON_FILE "AppIcon"
        XCODE_ATTRIBUTE_ENABLE_HARDENED_RUNTIME YES
        XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.ironclad.oh"
        XCODE_ATTRIBUTE_SWIFT_VERSION "5"
        XCODE_ATTRIBUTE_CLANG_ENABLE_OBJC_ARC YES
    )

    # Info.plist
    set_target_properties(IroncladOH PROPERTIES
        MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Apps/MacGame/Info.plist
    )

    find_library(APPKIT_LIB         AppKit)
    find_library(SWIFTUI_LIB        SwiftUI)

    target_link_libraries(IroncladOH PRIVATE
        EngineCore
        EngineRenderer
        ${APPKIT_LIB}
        ${METAL_LIB}
        ${METALKIT_LIB}
        ${QUARTZCORE_LIB}
        ${FOUNDATION_LIB}
    )

    target_compile_options(IroncladOH PRIVATE
        $<$<COMPILE_LANGUAGE:OBJCXX>:${PFGE_CXX_WARNINGS}>
        $<$<COMPILE_LANGUAGE:Swift>:-import-objc-header ${CMAKE_CURRENT_SOURCE_DIR}/Apps/MacGame/EngineHost.h>
    )

    target_include_directories(IroncladOH PRIVATE ${CMAKE_CURRENT_SOURCE_DIR})

    # Minimum macOS deployment target
    set_target_properties(IroncladOH PROPERTIES
        XCODE_ATTRIBUTE_MACOSX_DEPLOYMENT_TARGET "14.0"
    )
endif()

# ─── Tests ────────────────────────────────────────────────────────────────────
option(PFGE_BUILD_TESTS "Build tests" ON)
if (PFGE_BUILD_TESTS)
    enable_testing()
    add_subdirectory(Tests)
endif()
