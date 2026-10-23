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
