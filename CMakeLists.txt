# Linux/portable build of the colour core and its tests (fast feedback loop).
# The macOS application is built with SwiftPM (Package.swift); both builds use
# the same sources, including the vendored LittleCMS.
cmake_minimum_required(VERSION 3.16)
project(selphy_color_core C)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
if(NOT CMAKE_BUILD_TYPE)
  set(CMAKE_BUILD_TYPE Release)
endif()
find_package(Threads REQUIRED)

file(GLOB LCMS_SOURCES ${CMAKE_SOURCE_DIR}/Sources/CLittleCMS/src/*.c)
add_library(lcms2_vendored STATIC ${LCMS_SOURCES})
target_include_directories(lcms2_vendored
  PUBLIC ${CMAKE_SOURCE_DIR}/Sources/CLittleCMS/include
  PRIVATE ${CMAKE_SOURCE_DIR}/Sources/CLittleCMS/src)
target_compile_definitions(lcms2_vendored PRIVATE HasTHREADS=1 HAVE_GMTIME_R=1)
target_link_libraries(lcms2_vendored PUBLIC m Threads::Threads)

add_library(selphy_core STATIC ${CMAKE_SOURCE_DIR}/Sources/SELPHYColorCore/selphy_color_core.c
  ${CMAKE_SOURCE_DIR}/Sources/SELPHYColorCore/selphy_chart.c)
target_include_directories(selphy_core PUBLIC ${CMAKE_SOURCE_DIR}/Sources/SELPHYColorCore/include)
target_link_libraries(selphy_core PUBLIC lcms2_vendored)
target_compile_options(selphy_core PRIVATE -Wall -Wextra -Werror)

# Shared library for the Python validation tools (validation/); same sources as selphy_core.
add_library(selphy_core_shared SHARED
  ${CMAKE_SOURCE_DIR}/Sources/SELPHYColorCore/selphy_color_core.c
  ${CMAKE_SOURCE_DIR}/Sources/SELPHYColorCore/selphy_chart.c ${LCMS_SOURCES})
target_include_directories(selphy_core_shared
  PUBLIC ${CMAKE_SOURCE_DIR}/Sources/SELPHYColorCore/include ${CMAKE_SOURCE_DIR}/Sources/CLittleCMS/include
  PRIVATE ${CMAKE_SOURCE_DIR}/Sources/CLittleCMS/src)
target_compile_definitions(selphy_core_shared PRIVATE HasTHREADS=1 HAVE_GMTIME_R=1)
target_link_libraries(selphy_core_shared PRIVATE m Threads::Threads)

enable_testing()
if(EXISTS ${CMAKE_SOURCE_DIR}/Tests/CoreTests/core_tests.c)
  add_executable(core_tests ${CMAKE_SOURCE_DIR}/Tests/CoreTests/core_tests.c)
  target_link_libraries(core_tests PRIVATE selphy_core)
  target_compile_options(core_tests PRIVATE -Wall -Wextra -Werror)
  add_test(NAME core_tests COMMAND core_tests ${CMAKE_SOURCE_DIR}/ICC-Profile165-CP1500.icc)
endif()
