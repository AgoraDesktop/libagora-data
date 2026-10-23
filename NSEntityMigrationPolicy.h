/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSEntityMigrationPolicy — the seven hooks a migration calls, and the default copy that runs when a subclass
 * overrides none of them. W6 of COREDATA-PLAN.md §12, §9.
 *
 * THE THREE PASSES ARE THE CONTRACT: creation, then relationships, then validation. A subclass that overrides
 * `-createDestinationInstancesForSourceInstance:…` gets the whole per-instance creation to itself, and the pass
 * boundary is what lets a relationship pass see every destination object that exists.
 *
 * THE DEFAULT `-createDestinationInstances…` IS NOT A NO-OP: it creates the destination object and applies the
 * mapping's attribute expressions with `$source` bound, which is what makes an INFERRED mapping migrate anything
 * without a policy subclass at all.
 */

#ifndef COREDATA_NSENTITYMIGRATIONPOLICY_H
#define COREDATA_NSENTITYMIGRATIONPOLICY_H

#import <Foundation/Foundation.h>
#import <CoreData/CoreDataDefines.h>

COREDATA_EXTERN NSString *const NSMigrationManagerKey;
COREDATA_EXTERN NSString *const NSMigrationSourceObjectKey;
COREDATA_EXTERN NSString *const NSMigrationDestinationObjectKey;
COREDATA_EXTERN NSString *const NSMigrationEntityMappingKey;
COREDATA_EXTERN NSString *const NSMigrationPropertyMappingKey;
COREDATA_EXTERN NSString *const NSMigrationEntityPolicyKey;

@class NSManagedObject;
@class NSEntityMapping;
@class NSMigrationManager;

@interface NSEntityMigrationPolicy : NSObject

- (BOOL)beginEntityMapping:(NSEntityMapping *)mapping
                   manager:(NSMigrationManager *)manager
                     error:(NSError **)error;

- (BOOL)createDestinationInstancesForSourceInstance:(NSManagedObject *)sInstance
                                      entityMapping:(NSEntityMapping *)mapping
                                            manager:(NSMigrationManager *)manager
                                              error:(NSError **)error;

- (BOOL)endInstanceCreationForEntityMapping:(NSEntityMapping *)mapping
                                    manager:(NSMigrationManager *)manager
                                      error:(NSError **)error;

- (BOOL)createRelationshipsForDestinationInstance:(NSManagedObject *)dInstance
                                    entityMapping:(NSEntityMapping *)mapping
                                          manager:(NSMigrationManager *)manager
                                            error:(NSError **)error;

- (BOOL)endRelationshipCreationForEntityMapping:(NSEntityMapping *)mapping
                                        manager:(NSMigrationManager *)manager
                                          error:(NSError **)error;

- (BOOL)performCustomValidationForEntityMapping:(NSEntityMapping *)mapping
                                        manager:(NSMigrationManager *)manager
                                          error:(NSError **)error;

- (BOOL)endEntityMapping:(NSEntityMapping *)mapping
                 manager:(NSMigrationManager *)manager
                   error:(NSError **)error;

@end

#endif /* COREDATA_NSENTITYMIGRATIONPOLICY_H */
