# Copyright (c) 2026 Xiaohai Li <haixiaolee@gmail.com>
# SPDX-License-Identifier: MIT
cmake_minimum_required(VERSION 3.5)
project(nia_arpprobe)

if(NOT CMAKE_BUILD_TYPE)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

if(NOT DEFINED COYOTE_SW_DIR)
    set(_cand
        ${CMAKE_CURRENT_SOURCE_DIR}/../src/sw
        ${CMAKE_CURRENT_SOURCE_DIR}/../../src/sw
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../sw
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../src/sw
        ${CMAKE_CURRENT_SOURCE_DIR}/../../../../src/sw)
    foreach(_c ${_cand})
        if(EXISTS ${_c}/CMakeLists.txt)
            set(COYOTE_SW_DIR ${_c})
            break()
        endif()
    endforeach()
endif()
if(NOT DEFINED COYOTE_SW_DIR)
    message(FATAL_ERROR
        "Cannot find Coyote's sw/ directory from ${CMAKE_CURRENT_SOURCE_DIR}.\n"
        "Run `./diag.sh build-arp` from the IMAGES PACK root, or pass "
        "-DCOYOTE_SW_DIR=<path to Coyote/sw>.")
endif()
message(STATUS "arpprobe: using libcoyote from ${COYOTE_SW_DIR}")

add_subdirectory(${COYOTE_SW_DIR} ${CMAKE_BINARY_DIR}/coyote)

add_executable(arpprobe main.cpp)
set_property(TARGET arpprobe PROPERTY CXX_STANDARD 20)
target_link_libraries(arpprobe PUBLIC Coyote)
