cmake_minimum_required(VERSION 3.26)

# ─── Physics tests ────────────────────────────────────────────────────────────
add_executable(PhysicsTests
    PhysicsTests.cpp
)
target_link_libraries(PhysicsTests PRIVATE EngineCore)
target_include_directories(PhysicsTests PRIVATE ${CMAKE_SOURCE_DIR})
target_compile_options(PhysicsTests PRIVATE -std=c++20)
add_test(NAME PhysicsTests COMMAND PhysicsTests)

# ─── Simulation / ECS tests ───────────────────────────────────────────────────
add_executable(SimulationTests
    SimulationTests.cpp
)
target_link_libraries(SimulationTests PRIVATE EngineCore)
target_include_directories(SimulationTests PRIVATE ${CMAKE_SOURCE_DIR})
target_compile_options(SimulationTests PRIVATE -std=c++20)
add_test(NAME SimulationTests COMMAND SimulationTests)

# ─── Network protocol tests ───────────────────────────────────────────────────
add_executable(NetworkTests
    NetworkTests.cpp
)
target_link_libraries(NetworkTests PRIVATE EngineCore)
target_include_directories(NetworkTests PRIVATE ${CMAKE_SOURCE_DIR})
target_compile_options(NetworkTests PRIVATE -std=c++20)
add_test(NAME NetworkTests COMMAND NetworkTests)
