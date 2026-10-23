# Copyright © 2026 Kyle J. Cardoza.
# SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
# SPDX-License-Identifier: LGPL-3.0-or-later

#===----------------------------------------------------------------------===#
#
# Agora's build for Core Data (libagora-data).
#
# THE LAYERING IS APPLE'S, NOT THIS TREE'S CONVENIENCE. `CoreData.framework` sits on Foundation, and
# `NSPersistentDocument` -- the one AppKit class that touches Core Data -- is AppKit's and stays in
# libagora-app. So this component links Foundation and nothing else of Agora's, and the AppKit reaches it
# through its own dependency rather than the other way round. That direction is what COREDATA-PLAN.md §5.1
# argues for; putting 331 selectors inside the AppKit would have made the AppKit's census larger than the AppKit.
#
# THE HEADERS ARE INCLUDED AS <CoreData/...> AND LIVE AT THIS REPOSITORY'S ROOT, so the root is exposed as a
# `CoreData/` directory through a generated symlink -- the same shim, for the same reason, as libagora-base's.
#
# EVERY .m IN THE DIRECTORY IS COMPILED IN, as the rest of the tree does: a new translation unit is added by
# being written, not by being listed.
#
#===----------------------------------------------------------------------===#

cmake_minimum_required(VERSION 3.24)

project(AgoraData LANGUAGES C OBJC)

# `$ORIGIN` for the same reason every other component states it: a runpath is not inherited by a
# dependency's own dependencies, so each library has to name the directory its neighbours are in.
set(CMAKE_INSTALL_RPATH "\$ORIGIN")

# THE OBJECTIVE-C COMPILER MUST BE CLANG, AND SAYING SO HERE IS WORTH THREE LINES. Configured without a
# compiler argument, CMake picks the system C compiler, which for `-x objective-c` tries to exec `cc1obj` --
# a binary GCC has not shipped for years. The failure is `cannot execute 'cc1obj'` three levels into a CMake
# feature test, which names neither the language nor the fix. The other components in this tree are configured
# the same way; this one is the first to say so out loud.
if(NOT CMAKE_OBJC_COMPILER_ID MATCHES "Clang")
  message(FATAL_ERROR
    "libagora-data needs clang for Objective-C (it targets the GNUstep 2.0 runtime through libobjc2).\n"
    "Configure with: -DCMAKE_C_COMPILER=clang -DCMAKE_OBJC_COMPILER=clang")
endif()

enable_testing()

include(GNUInstallDirs)

set(CMAKE_POSITION_INDEPENDENT_CODE YES)
if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

# THE INSTALL RPATH IS IN THE BUILD TREE TOO, so `cmake --install` COPIES the library instead of RELINKING it.
# libagora-app's build records the failure that rule was learned from: an install-time relink asked for a file
# the linker never produced, and the install failed on the missing file while the headers installed fine.
set(CMAKE_BUILD_WITH_INSTALL_RPATH ON)

# ---------------------------------------------------------------------------
# Dependencies
# ---------------------------------------------------------------------------
find_package(libobjc CONFIG REQUIRED)          # -> objc
find_package(Foundation CONFIG REQUIRED)       # Agora's Foundation (libagora-base)

# ---------------------------------------------------------------------------
# The include shim: headers are spelled <CoreData/...> and live here
# ---------------------------------------------------------------------------
set(_agora_include_dir "${CMAKE_BINARY_DIR}/agora-include")
file(REMOVE_RECURSE "${_agora_include_dir}")
file(MAKE_DIRECTORY "${_agora_include_dir}")
file(CREATE_LINK "${CMAKE_CURRENT_SOURCE_DIR}" "${_agora_include_dir}/CoreData" SYMBOLIC)

# ---------------------------------------------------------------------------
# The library
# ---------------------------------------------------------------------------
file(GLOB COREDATA_SOURCES CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.m")

option(BUILD_SHARED_LIBS "Build shared libraries" ON)

add_library(Data SHARED ${COREDATA_SOURCES})

# THE FILE IS `libagora-data.so`, NOT `libData.so` -- the target name is short because consumers link `Data`,
# the FILE carries the component's name because that is what every other library in this tree does
# (`libagora-base.so`, `libagora-app.so`) and because a `libData.so` in the prefix would collide with anything.
set_target_properties(Data PROPERTIES OUTPUT_NAME agora-data)

target_include_directories(Data
    PUBLIC
        $<BUILD_INTERFACE:${_agora_include_dir}>
        $<INSTALL_INTERFACE:${CMAKE_INSTALL_INCLUDEDIR}>)

# FOUNDATION IS PUBLIC: every Core Data header names Foundation's types (`NSString`, `NSArray`,
# `NSPredicate`, `NSExpression`, `NSError`), so a consumer of this library reaches Foundation itself.
target_link_libraries(Data
    PUBLIC Foundation::Foundation
    PRIVATE objc)

# THE HEADERS ARE INSTALLED BY NAME, NOT BY COPYING THE SOURCE TREE. `install(DIRECTORY .)` was the first attempt
# and it was measured: it recreated `api/`, `cmake/` and `tests/` as EMPTY directories inside
# `include/CoreData/`, because FILES_MATCHING filters the files and not the traversal. A prefix that grows a
# directory per source subdirectory is a prefix that misdescribes the installed surface.
file(GLOB COREDATA_HEADERS CONFIGURE_DEPENDS "${CMAKE_CURRENT_SOURCE_DIR}/*.h")
install(FILES ${COREDATA_HEADERS} DESTINATION ${CMAKE_INSTALL_INCLUDEDIR}/CoreData)
install(TARGETS Data
    EXPORT AgoraDataTargets
    ARCHIVE DESTINATION ${CMAKE_INSTALL_LIBDIR}
    LIBRARY DESTINATION ${CMAKE_INSTALL_LIBDIR}
    RUNTIME DESTINATION ${CMAKE_INSTALL_BINDIR})

# ---------------------------------------------------------------------------
# The CMake package, so a consumer writes find_package(AgoraData CONFIG)
# ---------------------------------------------------------------------------
include(CMakePackageConfigHelpers)

install(EXPORT AgoraDataTargets
    FILE AgoraDataTargets.cmake
    NAMESPACE AgoraData::
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/AgoraData)

configure_package_config_file(cmake/AgoraDataConfig.cmake.in
    ${CMAKE_CURRENT_BINARY_DIR}/AgoraDataConfig.cmake
    INSTALL_DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/AgoraData)
write_basic_package_version_file(
    ${CMAKE_CURRENT_BINARY_DIR}/AgoraDataConfigVersion.cmake
    VERSION 1.0.0
    COMPATIBILITY SameMajorVersion)
install(FILES
    ${CMAKE_CURRENT_BINARY_DIR}/AgoraDataConfig.cmake
    ${CMAKE_CURRENT_BINARY_DIR}/AgoraDataConfigVersion.cmake
    DESTINATION ${CMAKE_INSTALL_LIBDIR}/cmake/AgoraData)

add_subdirectory(tests)
