# Copyright © 2026 Kyle J. Cardoza.
# SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
# SPDX-License-Identifier: LGPL-3.0-or-later

# libagora-data's tests. The build tree's library comes FIRST in LD_LIBRARY_PATH, which is the failure
# libagora-app's test headers record having hit: with the prefix first, every test loaded the INSTALLED library
# and the source tree it was meant to test was ignored.
set(_agora_data_test_env "LD_LIBRARY_PATH=$<TARGET_FILE_DIR:Data>:$<TARGET_FILE_DIR:Foundation::Foundation>")

# The umbrella and the error table. It asks the two questions a Phase 0 library can answer honestly: that every
# header is reachable through <CoreData/CoreData.h>, and that the eight string constants are DISTINCT non-empty
# values -- because eight constants that all point at one string would pass a nil check and mean nothing.
# AND THE RUNTIME IS NAMED HERE, because a shared library's PRIVATE dependencies are not propagated: this test
# is Objective-C of its own, so it needs `libobjc` on ITS link line. The failure without it is "DSO missing from
# command line" at the consumer -- the same lesson libagora-app's build records for its own tests. Core Foundation
# is named for the reason libagora-base's tests name it: Foundation's objects ARE Core Foundation objects, and the
# dispatch library Core Foundation carries arrives through that interface.
add_executable(smoke smoke.m)
target_link_libraries(smoke PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME smoke COMMAND smoke)
set_tests_properties(smoke PROPERTIES ENVIRONMENT "${_agora_data_test_env}")

# W1's gate: the seven model classes, and the archive round trip that is the only measurable form of "the model
# loads". A digest that changed between builds would invalidate every store on disk, so the version hash is
# asked for determinism and sensitivity here rather than trusted.
add_executable(model model.m)
target_link_libraries(model PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME model COMMAND model)
set_tests_properties(model PROPERTIES ENVIRONMENT "${_agora_data_test_env}")

# W2's gate: the value store, the diff, the fault state and validation.
add_executable(object object.m)
target_link_libraries(object PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME object COMMAND object)
set_tests_properties(object PROPERTIES ENVIRONMENT "${_agora_data_test_env}")

# THE MEASUREMENT, AS A GATE RATHER THAN A REPORT. `api-ledger census` decides whether a selector is answered by
# walking the superclass chain and the `.m` bodies, and it asks the built library which C functions exist — so a
# declaration cannot fake a door. The pin lives in `coredata-census.txt`; moving a number is a deliberate act in the
# same commit that says which wave moved it.
#
# THE LEDGER IS A SIBLING COMPONENT'S, AND THAT IS A PRECEDENT RATHER THAN A SHORTCUT: libagora-base already points
# at `../libagora-drawing` for Core Graphics' headers through a CACHE PATH with the same shape. A path variable
# means a checkout where the sibling lives elsewhere can still run the suite.
set(AGORA_LEDGER "${CMAKE_CURRENT_SOURCE_DIR}/../../libagora-app/tools/api-ledger"
    CACHE FILEPATH "api-ledger, from the libagora-app component")

find_package(Python3 COMPONENTS Interpreter QUIET)
if(Python3_Interpreter_FOUND)
  # REGISTERED UNCONDITIONALLY WHEN THE INTERPRETER EXISTS, and it fails loudly at run time if the ledger is
  # missing rather than quietly unregistering: a gate that disappears is the drift the census exists to stop.
  add_test(NAME coredata-api-census
    COMMAND "${CMAKE_COMMAND}"
            "-DPYTHON=${Python3_EXECUTABLE}"
            "-DLEDGER=${AGORA_LEDGER}"
            "-DMANIFEST=${CMAKE_CURRENT_SOURCE_DIR}/../api/10.6/coredata-manifest.txt"
            "-DLIBRARY=$<TARGET_FILE:Data>"
            "-DSOURCE_DIR=${CMAKE_CURRENT_SOURCE_DIR}/.."
            "-DCENSUS=${CMAKE_CURRENT_SOURCE_DIR}/coredata-census.txt"
            -P "${CMAKE_CURRENT_SOURCE_DIR}/api_census.cmake")
else()
  message(STATUS "libagora-data: no Python3 interpreter, so the API census gate is not registered")
endif()

# W3's gate: the six sets, the save pipeline, undo/rollback, delete propagation, merge, and D2's thread refusal —
# which is measured by actually making the call from another thread.
add_executable(context context.m)
target_link_libraries(context PRIVATE Data CoreFoundation::CoreFoundation objc pthread)

add_test(NAME context COMMAND context)
set_tests_properties(context PROPERTIES ENVIRONMENT "${_agora_data_test_env}")

# W4's gate: the registry, the metadata, and the save round trip — including the two-context fault, which is the
# first test in this plan where a permanent object ID means something.
add_executable(store store.m)
target_link_libraries(store PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME store COMMAND store)
set_tests_properties(store PROPERTIES ENVIRONMENT "${_agora_data_test_env}")

# W5's gate: the pipeline, and every modifier tested against its own default.
add_executable(fetch fetch.m)
target_link_libraries(fetch PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME fetch COMMAND fetch)
set_tests_properties(fetch PROPERTIES ENVIRONMENT "${_agora_data_test_env}")

# W6's gate: the inference in both directions, the archive, and a migration that is actually RUN.
add_executable(migration migration.m)
target_link_libraries(migration PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME migration COMMAND migration)
set_tests_properties(migration PROPERTIES ENVIRONMENT "${_agora_data_test_env}")

# W7's gate: one fixture through three store types, then the incompatible-model refusal.
add_executable(serialisation serialisation.m)
target_link_libraries(serialisation PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME serialisation COMMAND serialisation)
set_tests_properties(serialisation PROPERTIES ENVIRONMENT "${_agora_data_test_env}")

# The two doors the census scored and nothing used: configuration partitioning and multi-store routing.
add_executable(routing routing.m)
target_link_libraries(routing PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME routing COMMAND routing)
set_tests_properties(routing PROPERTIES ENVIRONMENT "${_agora_data_test_env}")

# §15.2's sixth item and §15.3's eighth: a 10^5-row workload with relationships, batching and undo, against the
# in-memory store AND SQLite. The times it prints are part of the result.
add_executable(scale scale.m)
target_link_libraries(scale PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME scale COMMAND scale)
set_tests_properties(scale PROPERTIES ENVIRONMENT "${_agora_data_test_env}" TIMEOUT 900)

add_executable(bench bench.m)
target_link_libraries(bench PRIVATE Data CoreFoundation::CoreFoundation objc)

# §0.14: the .momd / .mom / .cdm readers, found through a bundle.
add_executable(bundles bundles.m)
target_link_libraries(bundles PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME bundles COMMAND bundles)
set_tests_properties(bundles PROPERTIES ENVIRONMENT "${_agora_data_test_env}")

# §8: predicate-to-SQL pushdown, held to the in-memory scan it replaces.
add_executable(pushdown pushdown.m)
target_link_libraries(pushdown PRIVATE Data CoreFoundation::CoreFoundation objc)

add_test(NAME pushdown COMMAND pushdown)
set_tests_properties(pushdown PROPERTIES ENVIRONMENT "${_agora_data_test_env}")
