/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * CoreData.h — the umbrella, and it grows one wave at a time.
 *
 * WHAT IS HERE TODAY IS DELIBERATELY SMALL: the defines and the error domain. COREDATA-PLAN.md's W1 (the model)
 * brings seven class headers, W2 the object pair, W3 the context, and so on; the umbrella gains each in the same
 * commit that makes it answer, so `#import <CoreData/CoreData.h>` never names a class that does not exist. That
 * is the rule the AppKit's umbrella is held to, and the ledger measures it there.
 *
 * THE ORDER IS APPLE'S: model before objects, objects before the context, the context before the stores, stores
 * before migration. Reading the framework in that order is reading it bottom-up, which is how it is built.
 */

#ifndef COREDATA_COREDATA_H
#define COREDATA_COREDATA_H

#import <Foundation/Foundation.h>

#import <CoreData/CoreDataDefines.h>
#import <CoreData/CoreDataErrors.h>

/* W1 — the model. Each header arrives in the same commit that makes its class answer, so the umbrella never
 * names a class that does not exist. */
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/NSAttributeDescription.h>
#import <CoreData/NSRelationshipDescription.h>
#import <CoreData/NSFetchedPropertyDescription.h>
#import <CoreData/NSExpressionDescription.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSManagedObjectModel.h>

/* W2 — the object and its identity. */
#import <CoreData/NSManagedObjectID.h>
#import <CoreData/NSManagedObject.h>

#endif /* COREDATA_COREDATA_H */
