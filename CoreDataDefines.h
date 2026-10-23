/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * CoreDataDefines.h — the three macros every other header in this framework is written in terms of.
 *
 * THEY ARE SPELLED THE WAY APPLE SPELLS THEM (`COREDATA_EXTERN`, `COREDATA_DEPRECATED`, and the
 * `AVAILABLE_MAC_OS_X_VERSION_10_n_AND_LATER` family) because source compatibility is the contract: a client
 * that writes `COREDATA_EXTERN` or annotates a subclass with a 10.6 availability macro must compile here
 * exactly as it does against the SDK.
 *
 * THE AVAILABILITY MACROS ARE DEFINED EMPTY RATHER THAN OMITTED. A header that annotates nothing has nothing
 * for a reader to check against, and the whole point of the 10.6 ledger (COREDATA-PLAN.md §2) is that each
 * name carries the version it ARRIVED in — not the version this tree happened to implement it in. The macros
 * exist so the annotations can be written and read; a consumer's `#if` on them behaves as it would on macOS
 * where everything here is already available.
 */

#ifndef COREDATA_COREDATADEFINES_H
#define COREDATA_COREDATADEFINES_H

#ifdef __cplusplus
#define COREDATA_EXTERN		extern "C"
#else
#define COREDATA_EXTERN		extern
#endif

#ifndef COREDATA_DEPRECATED
#define COREDATA_DEPRECATED	__attribute__((deprecated))
#endif

#ifndef AVAILABLE_MAC_OS_X_VERSION_10_4_AND_LATER
#define AVAILABLE_MAC_OS_X_VERSION_10_4_AND_LATER
#define AVAILABLE_MAC_OS_X_VERSION_10_5_AND_LATER
#define AVAILABLE_MAC_OS_X_VERSION_10_6_AND_LATER
#endif

#ifndef DEPRECATED_IN_MAC_OS_X_VERSION_10_6_AND_LATER
#define DEPRECATED_IN_MAC_OS_X_VERSION_10_6_AND_LATER
#endif

#endif /* COREDATA_COREDATADEFINES_H */
