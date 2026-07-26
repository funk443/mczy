cmake_minimum_required(VERSION 3.16)
project(mczy_engine CXX)

set(CMAKE_CXX_STANDARD 20)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Vendored BopomofoSyllable.cpp uses bopomofo Unicode chars as C++ identifiers
# (UTF-8 identifiers), which GCC only supports from 10. Fail clearly at configure
# instead of a cryptic "expected unqualified-id" deep in the build.
if(CMAKE_CXX_COMPILER_ID STREQUAL "GNU" AND CMAKE_CXX_COMPILER_VERSION VERSION_LESS 10)
  message(FATAL_ERROR "GCC ${CMAKE_CXX_COMPILER_VERSION} too old: vendored sources use UTF-8 identifiers. "
                      "Use GCC >= 10 (e.g. -DCMAKE_CXX_COMPILER=g++-10) or clang.")
endif()

# Upstream McBopomofo sources, vendored as a pinned submodule. We reuse the
# engine + KeyHandler unmodified and supply our own frontend (main.cpp) + a tiny
# fcitx shim (engine/fcitx-shim) so nothing here links against fcitx5.
set(MCB ${CMAKE_CURRENT_SOURCE_DIR}/vendor/fcitx5-mcbopomofo/src)

if(NOT EXISTS ${MCB}/KeyHandler.cpp)
  message(FATAL_ERROR "submodule missing: run `git submodule update --init`")
endif()

# Pure (fcitx-free) engine sublibs, built straight from upstream's own CMake.
# ENABLE_TEST/ENABLE_BENCHMARK default off, so no GTest/benchmark is pulled.
add_subdirectory(${MCB}/Engine          ${CMAKE_CURRENT_BINARY_DIR}/Engine)
add_subdirectory(${MCB}/Big5Utils       ${CMAKE_CURRENT_BINARY_DIR}/Big5Utils)
add_subdirectory(${MCB}/BopomofoBraille ${CMAKE_CURRENT_BINARY_DIR}/BopomofoBraille)
add_subdirectory(${MCB}/ChineseNumbers  ${CMAKE_CURRENT_BINARY_DIR}/ChineseNumbers)
add_subdirectory(${MCB}/RomanNumbers    ${CMAKE_CURRENT_BINARY_DIR}/RomanNumbers)

add_executable(mczy-engine
  main.cpp
  DictionaryService.cpp        # no-op stub, replaces upstream's fcitx-coupled .cpp
  ${MCB}/KeyHandler.cpp
  ${MCB}/InputState.cpp
  ${MCB}/NumberInputHelper.cpp
)

target_include_directories(mczy-engine PRIVATE
  ${CMAKE_CURRENT_SOURCE_DIR}/fcitx-shim   # <fcitx-utils/*> stubs; -I wins for angle includes
  ${MCB}
  ${MCB}/Engine
)

target_link_libraries(mczy-engine PRIVATE
  McBopomofoLMLib gramambular2_lib MandarinLib
  Big5UtilsLib BopomofoBraille ChineseNumbersLib RomanNumbersLib
)
