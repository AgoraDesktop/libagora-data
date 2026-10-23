# The 10.6 API census, checked in both directions.
#
# Copyright © 2026 Kyle J. Cardoza.
# SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
# SPDX-License-Identifier: GPL-3.0-or-later
#
# usage: cmake -DPYTHON=<python3> -DLEDGER=<tools/api-ledger> -DMANIFEST=<manifest> -DLIBRARY=<built .so> \
#              -DSOURCE_DIR=<libagora-app> -DCENSUS=<tests/api-10.6-census.txt> -P api_census.cmake
#
# **`-DLIBRARY` IS WHY THIS GATE EXISTS IN THE FORM IT DOES.** The first version counted a C function as present when a
# header declared it, and that measurement was wrong in both directions inside a single afternoon: five declared depth
# functions had no definition at all (unresolved references inside `libagora-app.so`), and four defined pasteboard
# refusals had no declaration, so nobody could call them. A function is now present when `nm -D --defined-only` finds it,
# which is the question a caller's link line asks, and the two disagreement counts are pinned at zero.
#
# **THE INTERPRETER IS NOT ENOUGH HERE; `nm` IS ALSO REQUIRED.** It is the same binutils the build already uses.
#
# **THE THIRD OF THE CENSUS INSTRUMENTS, AND THE ONLY ONE THAT MEASURES RATHER THAN RECORDS.** `claims_census.cmake`
# counts claims in this tree's own prose — a refusal site, an owed note — and holds them per file. This one holds the
# ANSWER, and the answer is not a claim: it is what a caller asking for a door on a class would actually get, computed
# from the headers and the method bodies with inheritance resolved. The companion file `api-10.6-census.txt` pins it.
#
# **WHY A SEPARATE SCRIPT RATHER THAN A NEEDLE AND A COUNT.** The other two censuses can be counted with a regex over
# a file, so their logic lives entirely in CMake and that is the right shape for them. This one cannot: deciding
# whether an Apple selector is answered requires walking `@interface`/`@protocol`/`@implementation` blocks, expanding
# `@property` into its accessors, and resolving a superclass chain — which is a parser, not a pattern. So the parser is
# `tools/api-ledger` and this file is the GATE around it: it runs the ledger, and then does the same two-directional
# comparison the other censuses do, with the same kind of diagnostic, because the comparison is the part that has to be
# visible in the build and reviewable in a diff.
#
# **TWO DIRECTIONS, AND THEY ARE NOT SYMMETRIC IN WHAT THEY MEAN.**
#
#   a census line the tree no longer measures  -> a metric DISAPPEARED. Either a class left the tree, or the ledger
#                                                 stopped emitting a name, and both are regressions or renames that
#                                                 need to be seen rather than absorbed.
#   a measured metric the census does not name  -> NEW SURFACE. This is the direction that would otherwise go
#                                                 unrecorded: a slice adds twelve selectors and the count quietly
#                                                 improves, which is an improvement nobody writes down.
#   a count that has moved                      -> the ordinary case, in either direction.
#
# All three fail. Which means the ONLY way to change this census is to edit it, in a commit that says why — the same
# deliberate-act rule the refusal census states, applied to the measurement the refusals are about.
#
# **AND THE ARITHMETIC IS CHECKED AS WELL AS THE COUNTS.** Each family pins `-present`, `-offered` and `-missing`, so
# a hand edit that moves one without the others leaves the census internally inconsistent. A census that can hold a
# contradiction is half an instrument.

if(NOT PYTHON OR NOT LEDGER OR NOT MANIFEST OR NOT SOURCE_DIR OR NOT CENSUS OR NOT LIBRARY)
  message(FATAL_ERROR
    "api_census.cmake needs -DPYTHON, -DLEDGER, -DMANIFEST, -DLIBRARY, -DSOURCE_DIR and -DCENSUS "
    "(the library is required: a declared function that is not a symbol is a link error waiting for a caller)")
endif()

foreach(required IN ITEMS "${LEDGER}" "${MANIFEST}" "${CENSUS}" "${LIBRARY}")
  if(NOT EXISTS "${required}")
    message(FATAL_ERROR "api_census.cmake: missing file `${required}`")
  endif()
endforeach()

# ---------------------------------------------------------------------------
# THE MEASUREMENT, from the ledger.
# ---------------------------------------------------------------------------
execute_process(
  COMMAND "${PYTHON}" "${LEDGER}" census "${MANIFEST}" "${SOURCE_DIR}" --library "${LIBRARY}"
  OUTPUT_VARIABLE measured_text
  ERROR_VARIABLE measured_error
  RESULT_VARIABLE measured_status)

if(NOT measured_status EQUAL 0)
  message(FATAL_ERROR
    "api_census.cmake: `api-ledger census` failed (${measured_status}).\n${measured_error}")
endif()

# ---------------------------------------------------------------------------
# THE MEASUREMENT, parsed. `name count`, the colon in a metric name is part of the name.
# ---------------------------------------------------------------------------
set(actual_names "")
string(REPLACE "\n" ";" measured_lines "${measured_text}")
foreach(line IN LISTS measured_lines)
  string(STRIP "${line}" line)
  if(line STREQUAL "")
    continue()
  endif()
  if(NOT line MATCHES "^([^ ]+) +([0-9]+)$")
    message(FATAL_ERROR "api-ledger emitted a line that is not `name count`: `${line}`")
  endif()
  set(name "${CMAKE_MATCH_1}")
  set(actual_names ${actual_names} "${name}")
  set(actual_${name} "${CMAKE_MATCH_2}")
endforeach()

# ---------------------------------------------------------------------------
# THE CENSUS, parsed. Blank lines and `#` comments skipped, exactly as the other two do.
# ---------------------------------------------------------------------------
file(READ "${CENSUS}" census_text)
set(expected_names "")
# **THE COMMENT LINES COME OUT BEFORE THE NEWLINES TURN INTO LIST SEPARATORS.** `string(REPLACE "\n" ";" ...)` splits on
# semicolons too, and the header of this census is prose with semicolons in it, so the split fragments a comment into a
# line that reads as `name count` and is not. Stripping comments first is what lets the census be WRITTEN in sentences
# rather than ASCII-art prose kept free of punctuation for the parser's sake.
string(REGEX REPLACE "(^|\n)[ \t]*#[^\n]*" "\\1" census_body "${census_text}")
string(REPLACE "\n" ";" census_lines "${census_body}")
foreach(line IN LISTS census_lines)
  string(STRIP "${line}" line)
  if(line STREQUAL "" OR line MATCHES "^#")
    continue()
  endif()
  if(NOT line MATCHES "^([^ ]+) +([0-9]+)$")
    message(FATAL_ERROR "the census has a line that is not `name count`: `${line}`")
  endif()
  set(name "${CMAKE_MATCH_1}")
  set(count "${CMAKE_MATCH_2}")
  list(FIND expected_names "${name}" _seen_index)
  if(NOT _seen_index EQUAL -1)
    message(FATAL_ERROR "the census names `${name}` twice")
  endif()
  set(expected_names ${expected_names} "${name}")
  set(expected_${name} "${count}")
endforeach()

# ---------------------------------------------------------------------------
# BOTH DIRECTIONS.
# ---------------------------------------------------------------------------
set(problems "")

# **AND NO PROBLEM MESSAGE MAY CONTAIN A SEMICOLON.** A CMake list is semicolon-separated, so `list(APPEND problems
# "a; b")` appends TWO entries and the summary counts one drift as two — the same trap that broke the census parse
# above, in the diagnostics rather than the data. Commas, not semicolons.

foreach(name IN LISTS expected_names)
  # `IN_LIST` is newer than the CMake this tree builds with, so the membership tests are `list(FIND …)`.
  list(FIND actual_names "${name}" _actual_index)
  if(_actual_index EQUAL -1)
    list(APPEND problems
      "  ${name}  the census names it, and the tree does not measure it any more")
  elseif(NOT expected_${name} STREQUAL actual_${name})
    list(APPEND problems
      "  ${name}  census ${expected_${name}}, measured ${actual_${name}}")
  endif()
endforeach()

foreach(name IN LISTS actual_names)
  list(FIND expected_names "${name}" _expected_index)
  if(_expected_index EQUAL -1)
    list(APPEND problems
      "  ${name}  measured ${actual_${name}}, and the census does not name it")
  endif()
endforeach()

# ---------------------------------------------------------------------------
# AND THE TWO DISAGREEMENTS ARE NOT "DRIFT", THEY ARE BUGS.
#
# A declaration with no definition is a door a caller can compile against and cannot link against; a definition with no
# declaration is a door nobody can open. Neither is a number to move deliberately — so they are checked as faults with
# their own message, before the drift report, and the message says which way round the fault is.
# ---------------------------------------------------------------------------
foreach(fault IN ITEMS
        declared-not-defined:functions-declared-not-defined
        defined-not-declared:functions-defined-not-declared)
  string(REPLACE ":" ";" fault_pair "${fault}")
  list(GET fault_pair 0 fault_name)
  list(GET fault_pair 1 fault_metric)
  if(NOT actual_${fault_metric} STREQUAL "0")
    message(FATAL_ERROR
      "The API census found ${actual_${fault_metric}} function(s) `nm -D` and the headers DISAGREE about "
      "(${fault_name}).\n"
      "  declared-not-defined: declared in a header, absent from the built library — a link error waiting for a caller.\n"
      "  defined-not-declared: built into the library, absent from every header — a door nobody can open.\n"
      "Neither is a census number to move. Fix the tree, then re-pin.")
  endif()
endforeach()

# ---------------------------------------------------------------------------
# AND THE CENSUS'S OWN ARITHMETIC.
# ---------------------------------------------------------------------------
foreach(family IN ITEMS classes selectors protocols functions)
  if(DEFINED expected_${family}-present AND DEFINED expected_${family}-offered
     AND DEFINED expected_${family}-missing)
    math(EXPR family_sum
      "${expected_${family}-present} + ${expected_${family}-missing}")
    if(NOT family_sum EQUAL expected_${family}-offered)
      list(APPEND problems
        "  ${family}  present + missing is ${family_sum}, offered is ${expected_${family}-offered}")
    endif()
  endif()
endforeach()

if(problems)
  list(LENGTH problems problem_count)
  string(REPLACE ";" "\n" problem_text "${problems}")
  message(FATAL_ERROR
    "The 10.6 API census has drifted, in ${problem_count} place(s).\n"
    "${problem_text}\n"
    "\n"
    "This census is the MEASURED answer to how much of the 10.6 AppKit this tree reaches, so changing\n"
    "it is a deliberate act rather than a side effect. If the movement is intended, edit\n"
    "tests/api-10.6-census.txt in the same commit and say in the message what landed. If it is not\n"
    "intended, something was removed or renamed. `tools/api-ledger missing` names what is absent.")
endif()

message(STATUS
  "api census holds: ${actual_classes-present} of ${actual_classes-offered} classes, "
  "${actual_selectors-present} of ${actual_selectors-offered} selectors, "
  "${actual_protocols-present} of ${actual_protocols-offered} protocols, "
  "${actual_functions-present} of ${actual_functions-offered} functions")
