cmake_minimum_required(VERSION 3.14)
project(autonion_unlock_helper LANGUAGES CXX)

add_executable(autonion_unlock_helper
  "main.cpp"
)

apply_standard_settings(autonion_unlock_helper)
target_compile_definitions(autonion_unlock_helper PRIVATE "NOMINMAX")
target_link_libraries(autonion_unlock_helper PRIVATE Advapi32.lib Crypt32.lib User32.lib Ws2_32.lib Wtsapi32.lib)
