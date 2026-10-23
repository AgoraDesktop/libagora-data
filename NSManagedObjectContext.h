/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSManagedObjectContext — the unit of work, and the only object in Core Data that decides when something has
 * *happened*. W3 of COREDATA-PLAN.md §12.
 *
 * SIX SETS, THREE OF THEM PUBLIC. `-insertedObjects`, `-updatedObjects` and `-deletedObjects` are what a caller
 * sees; the three `_pending…` sets behind them are what the object graph has been told since the last
 * `-processPendingChanges`. That split is not bureaucracy — it is why `-processPendingChanges` is a door at all,
 * and it is what makes `NSManagedObjectContextObjectsDidChangeNotification` mean "at the end of this event" rather
 * than "whenever a setter ran".
 *
 * CONCURRENCY IS 10.6'S, FAITHFULLY: `<NSLocking>` with `-lock`/`-unlock`/`-tryLock` over a RECURSIVE lock, no
 * `-performBlock:`, no concurrency types — none of them exist on 10.6 (they are 10.7) and inventing them would
 * make a client compile here that would not compile on macOS. What Agora adds is decision D2: a context records
 * the thread that owns it, and touching it from another thread without holding the lock raises
 * `NSManagedObjectContextLockingError` instead of corrupting the sets — a strict superset of Apple's contract,
 * which a correct program never sees.
 *
 * SAVE WITHOUT A COORDINATOR IS IN-MEMORY, AND SAYS SO. W4 puts the store behind a private door
 * (`cd_saveContext:error:`); until that lands, `-save:` validates, adopts the diff as committed, clears the sets
 * and posts the notifications — a complete object-graph save with no durability claim. The alternative (refusing)
 * would make undo, rollback and merge untestable for a wave, which is a worse trade than a documented gap.
 */

#ifndef COREDATA_NSMANAGEDOBJECTCONTEXT_H
#define COREDATA_NSMANAGEDOBJECTCONTEXT_H

#import <Foundation/Foundation.h>
#import <CoreData/CoreDataDefines.h>

@class NSError;
@class NSFetchRequest;
@class NSManagedObject;
@class NSManagedObjectID;
@class NSPersistentStore;
@class NSPersistentStoreCoordinator;
@class NSUndoManager;
@class NSRecursiveLock;

COREDATA_EXTERN NSString *const NSManagedObjectContextWillSaveNotification;
COREDATA_EXTERN NSString *const NSManagedObjectContextDidSaveNotification;
COREDATA_EXTERN NSString *const NSManagedObjectContextObjectsDidChangeNotification;

COREDATA_EXTERN NSString *const NSInsertedObjectsKey;
COREDATA_EXTERN NSString *const NSUpdatedObjectsKey;
COREDATA_EXTERN NSString *const NSDeletedObjectsKey;
COREDATA_EXTERN NSString *const NSRefreshedObjectsKey;
COREDATA_EXTERN NSString *const NSInvalidatedObjectsKey;
COREDATA_EXTERN NSString *const NSInvalidatedAllObjectsKey;

/* Five opaque singletons, as 10.6 has them: there is no NSMergePolicy class in this era, so a policy is a value
 * the context switches on rather than a class a caller subclasses. */
COREDATA_EXTERN id NSErrorMergePolicy;
COREDATA_EXTERN id NSMergeByPropertyStoreTrumpMergePolicy;
COREDATA_EXTERN id NSMergeByPropertyObjectTrumpMergePolicy;
COREDATA_EXTERN id NSOverwriteMergePolicy;
COREDATA_EXTERN id NSRollbackMergePolicy;

@interface NSManagedObjectContext : NSObject <NSCoding, NSLocking>
{
	id _coordinator;			/* NSPersistentStoreCoordinator, NOT retained */
	NSUndoManager *_undoManager;		/* retained, created lazily */
	id _mergePolicy;			/* one of the five singletons, retained */
	NSMutableDictionary *_registered;	/* NSManagedObjectID -> NSManagedObject */
	NSMutableSet *_inserted;
	NSMutableSet *_updated;
	NSMutableSet *_deleted;
	NSMutableSet *_pendingInsertions;
	NSMutableSet *_pendingUpdates;
	NSMutableSet *_pendingDeletions;
	NSMutableDictionary *_storeAssignments;	/* object -> store, for -assignObject:toPersistentStore: */
	NSRecursiveLock *_lock;
	NSTimeInterval _stalenessInterval;
	BOOL _propagatesDeletesAtEndOfEvent;
	BOOL _retainsRegisteredObjects;
	BOOL _undoing;				/* set while -undo/-redo is replaying */
	BOOL _processing;			/* guards re-entrant -processPendingChanges */
	unsigned long _lockCount;
	unsigned long _lockOwner;
	unsigned long _owningThread;
}

- (void)setPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator;
- (NSPersistentStoreCoordinator *)persistentStoreCoordinator;

- (void)setUndoManager:(NSUndoManager *)undoManager;
- (NSUndoManager *)undoManager;

- (BOOL)hasChanges;

- (NSManagedObject *)objectRegisteredForID:(NSManagedObjectID *)objectID;
- (NSManagedObject *)objectWithID:(NSManagedObjectID *)objectID;
- (NSManagedObject *)existingObjectWithID:(NSManagedObjectID *)objectID error:(NSError **)error;

- (NSArray *)executeFetchRequest:(NSFetchRequest *)request error:(NSError **)error;
- (NSUInteger)countForFetchRequest:(NSFetchRequest *)request error:(NSError **)error;

- (void)insertObject:(NSManagedObject *)object;
- (void)deleteObject:(NSManagedObject *)object;

- (void)refreshObject:(NSManagedObject *)object mergeChanges:(BOOL)flag;
- (void)detectConflictsForObject:(NSManagedObject *)object;

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context;

- (void)processPendingChanges;
- (void)assignObject:(id)object toPersistentStore:(NSPersistentStore *)store;

- (NSSet *)insertedObjects;
- (NSSet *)updatedObjects;
- (NSSet *)deletedObjects;
- (NSSet *)registeredObjects;

- (void)undo;
- (void)redo;
- (void)reset;
- (void)rollback;

- (BOOL)save:(NSError **)error;

- (void)lock;
- (void)unlock;
- (BOOL)tryLock;

- (BOOL)propagatesDeletesAtEndOfEvent;
- (void)setPropagatesDeletesAtEndOfEvent:(BOOL)flag;

- (BOOL)retainsRegisteredObjects;
- (void)setRetainsRegisteredObjects:(BOOL)flag;

- (NSTimeInterval)stalenessInterval;
- (void)setStalenessInterval:(NSTimeInterval)expiration;

- (void)setMergePolicy:(id)mergePolicy;
- (id)mergePolicy;

- (BOOL)obtainPermanentIDsForObjects:(NSArray *)objects error:(NSError **)error;

- (void)mergeChangesFromContextDidSaveNotification:(NSNotification *)notification;

@end

/* THE DOORS THE OBJECT GRAPH OPENS INWARD. `-cd_registerManagedObject:` is what an object's initializer calls;
 * `-cd_fireFaultForObject:` is what `-willAccessValueForKey:` calls. Both are private because neither is a
 * caller's business, and both are declared here because W4's coordinator needs them too. */
@interface NSManagedObjectContext (CDPrivate)
- (void)cd_registerManagedObject:(NSManagedObject *)object;
- (void)cd_fireFaultForObject:(NSManagedObject *)object;
- (void)cd_objectDidChange:(NSManagedObject *)object;
- (NSUndoManager *)cd_undoManagerIfAny;
- (BOOL)cd_isUndoing;
- (void)cd_rekeyRegisteredObjects;
@end

#endif /* COREDATA_NSMANAGEDOBJECTCONTEXT_H */
