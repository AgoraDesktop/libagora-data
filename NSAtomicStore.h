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
	NSMutableSet *_dirtyNodes;		/* nodes written since the last save */
	NSMutableSet *_removedObjectIDs;	/* rows deleted since the last save */
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

/* THE THREE DOORS A LAZY STORE OVERRIDES (§0.18). A store that can read one row answers all three from the file; the
 * ones that cannot — binary and XML, which have no per-row read — answer from the cache they loaded, which is what
 * they had before. THE BASE CLASS IS THEREFORE STILL EAGER, and nothing changes for those two. */
@interface NSAtomicStore (CDLazy)
/* Every object this store holds, BY ID ONLY: no values are read. */
- (NSArray *)cd_objectIDs;
/* One row, on demand. */
- (NSAtomicStoreCacheNode *)cd_cacheNodeForObjectID:(NSManagedObjectID *)objectID;
/* MANY rows at once, for the scan that has to look at every candidate (§0.19): a lazy store would otherwise run one
 * SELECT per row. The base class has them all already, so this is a no-op there. */
- (void)cd_prefetchNodesForObjectIDs:(NSArray *)objectIDs;
/* What has changed since the last save: nodes added and rows removed. A store that saves incrementally reads these;
 * a store that rewrites the file ignores them. */
- (NSSet *)cd_dirtyNodes;
- (NSSet *)cd_removedObjectIDs;
/* Called by a store once its save has written the changes, so the next save starts from empty. */
- (void)cd_clearChanges;
@end

#endif /* COREDATA_NSATOMICSTORE_H */
