/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSAtomicStore — the store subclassing contract on 10.6, and the only one (`NSIncrementalStore` is 10.7 and
 * deliberately not here). W4 of COREDATA-PLAN.md §12.
 *
 * THE CONTRACT IS A NODE CACHE, NOT AN OBJECT MAPPER. A subclass never sees a fetch or a save pipeline: it
 * answers `-load:` (build the nodes), `-save:` (write them out) and the four reference-object doors that turn a
 * row key into an object ID and back. Everything else — which node a managed object corresponds to, when to
 * update it — is this class, once, for all four stores.
 *
 * REFERENCES ARE OPAQUE ON PURPOSE: a store may key rows by NSNumber (in-memory, SQLite) or by a string (XML), so
 * the cache keeps the reference the subclass chose and never interprets it.
 */

#ifndef COREDATA_NSATOMICSTORE_H
#define COREDATA_NSATOMICSTORE_H

#import <Foundation/Foundation.h>
#import <CoreData/NSPersistentStore.h>

@class NSAtomicStoreCacheNode;
@class NSEntityDescription;
@class NSManagedObject;
@class NSManagedObjectID;

@interface NSAtomicStore : NSPersistentStore
{
	NSMutableDictionary *_cacheNodes;	/* NSManagedObjectID -> NSAtomicStoreCacheNode */
	NSMutableDictionary *_referenceCounters;	/* entity name -> last used key */
}

- (id)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator
                       configurationName:(NSString *)configurationName
                                     URL:(NSURL *)url
                                 options:(NSDictionary *)options;

- (BOOL)load:(NSError **)error;
- (BOOL)save:(NSError **)error;

- (NSAtomicStoreCacheNode *)newCacheNodeForManagedObject:(NSManagedObject *)managedObject;
- (void)updateCacheNode:(NSAtomicStoreCacheNode *)node fromManagedObject:(NSManagedObject *)managedObject;

- (NSSet *)cacheNodes;
- (void)addCacheNodes:(NSSet *)cacheNodes;
- (void)willRemoveCacheNodes:(NSSet *)cacheNodes;
- (NSAtomicStoreCacheNode *)cacheNodeForObjectID:(NSManagedObjectID *)objectID;

- (NSManagedObjectID *)objectIDForEntity:(NSEntityDescription *)entity referenceObject:(id)data;
- (id)newReferenceObjectForManagedObject:(NSManagedObject *)managedObject;
- (id)referenceObjectForObjectID:(NSManagedObjectID *)objectID;

@end

#endif /* COREDATA_NSATOMICSTORE_H */
