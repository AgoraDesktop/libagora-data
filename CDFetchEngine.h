/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * The fetch pipeline, private to this library: `COREDATA-PLAN.md` §8.1's stages over a node cache.
 *
 * IT IS TWO STAGES RATHER THAN ONE BECAUSE OF MULTIPLE STORES. "Which rows" is per store; "what order, which slice,
 * what shape" is over the merged set — a fetch that sorted and paged inside each store would return the first N rows
 * of every store instead of the first N rows of the answer, and `fetchOffset` would restart at each one.
 */

#ifndef COREDATA_CDFETCHENGINE_H
#define COREDATA_CDFETCHENGINE_H

#import <Foundation/Foundation.h>

@class NSAtomicStore;
@class NSFetchRequest;
@class NSEntityDescription;
@class NSManagedObjectContext;
@class NSError;

/* Stage one, per store: the objects this store holds that match the request's entity and predicate. UNSORTED and
 * UNPAGED, because those decisions belong to the merged set. */
NSArray *CDFetchCandidates(NSAtomicStore *store, NSManagedObjectContext *context, NSFetchRequest *request);

/* The context's own unsaved insertions that match — added ONCE, not once per store. */
NSArray *CDFetchPendingCandidates(NSManagedObjectContext *context, NSFetchRequest *request);

/* Stage two, over the union: sort, offset, limit, result type, and faults at the door. */
id CDFetchShape(NSArray *candidates, NSFetchRequest *request, NSEntityDescription *entity);

/* Both stages for one store, which is what the single-store case wants and what W5's suite measures. */
NSArray *CDFetchExecute(NSAtomicStore *store, NSManagedObjectContext *context,
                        NSFetchRequest *request, NSError **error);

#endif /* COREDATA_CDFETCHENGINE_H */
