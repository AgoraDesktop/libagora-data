/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/* The fetch pipeline, private to this library: `COREDATA-PLAN.md` §8.1's four stages over a node cache. W7
 * replaces the candidate source with SQL and leaves the order alone. */

#ifndef COREDATA_CDFETCHENGINE_H
#define COREDATA_CDFETCHENGINE_H

#import <Foundation/Foundation.h>

@class NSAtomicStore;
@class NSFetchRequest;
@class NSManagedObjectContext;
@class NSError;

NSArray *CDFetchExecute(NSAtomicStore *store, NSManagedObjectContext *context,
                        NSFetchRequest *request, NSError **error);

#endif /* COREDATA_CDFETCHENGINE_H */
