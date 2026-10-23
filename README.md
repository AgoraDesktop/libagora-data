# libagora-data

**Core Data for Agora** — the object-graph and persistence framework of Agora's Cocoa-compatible stack:
managed objects and their contexts, fetch requests and the predicate engine they stand on, the persistent
stores and their coordinator, and the migration machinery between model versions.

Agora is an installable desktop environment for Linux and BSD; see the project README in the parent
directory (`../README.md`). `libagora-data` sits on `libagora-base` (Foundation), which it needs for
`NSPredicate`, `NSExpression`, `NSKeyedArchiver` and `NSDecimalNumber`, and on nothing else of Agora's:
`NSPersistentDocument` is AppKit's one Core Data class and stays in `libagora-app`.

## Provenance

Not an import. There is no Core Data in the Fiwix tree this stack's Foundation came from, and the only Core
Data implementation in this repository's neighbourhood is the Cocotron corpus under `audit/corpus/`, which is
a **reading aid**: 21 files and ~3,350 lines with no SQLite store and `NSLog(@"… not implemented")` for nine
of the attribute types. `COREDATA-PLAN.md` in the parent repository says what it is worth — a checklist of the
traps, not a base to build on.

The reference is `MacOSX10.6.sdk`. The surface is **21 classes, 331 selectors, 24 headers, 56 constants, 0
protocols, 0 C functions**, generated into [`api/10.6/coredata-manifest.txt`](api/10.6/coredata-manifest.txt)
by `libagora-app`'s `tools/api-ledger` — the recipe and the facts are committed, the SDK is not.

## Status

**Phase 0 — the component, and nothing else yet.** What exists: this build, the include shim that makes
`<CoreData/…>` work, the umbrella, `CoreDataDefines.h`, and the error table transcribed from the 10.6 headers.
That is deliberate: `CoreData.h` gains a class header in the same commit that makes the class answer, so the
umbrella never names a class that does not exist.

The waves, their gates and their order are in `COREDATA-PLAN.md` (§12). The one that matters first is the
object graph itself — the model (W1), the objects (W2) and the context (W3) — against the in-memory store,
which is the conformance reference every other store is measured against.

## Building

The Objective-C compiler must be **clang** — this tree targets the GNUstep 2.0 runtime through `libobjc2`, and
GCC's Objective-C front end has not existed for years (`cc1obj`). The build says so and stops, rather than failing
three levels into a CMake feature test.

```sh
cmake -S . -B build \
  -DCMAKE_C_COMPILER=clang -DCMAKE_OBJC_COMPILER=clang \
  -DCMAKE_INSTALL_PREFIX=/path/to/prefix \
  -DCMAKE_PREFIX_PATH=/path/to/prefix      # where libagora-base is installed
cmake --build build
ctest --test-dir build
cmake --install build
```

A consumer writes `find_package(AgoraData CONFIG)` and links `AgoraData::Data`. Foundation is found as a
dependency of this package rather than spelled out, because Core Data's headers cannot be preprocessed
without it.
