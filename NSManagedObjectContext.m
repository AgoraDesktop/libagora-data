/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSManagedObjectContext.m — the six sets, the save pipeline, undo, merge, and 10.6's locking.
 *
 * THE PENDING/PUBLISHED SPLIT IS THE CLASS. A setter on an object tells the context "something changed"; it does
 * not tell the context WHICH SET to publish it in, because until `-processPendingChanges` runs there is no event
 * boundary. That is why `-insertedObjects` can legitimately be empty while an object is dirty, and why the
 * notification carries three sets rather than being posted per setter.
 *
 * D2 IS IMPLEMENTED AS A REFUSAL, NOT A HOPE. The context records the thread that owns it (the creator, or the
 * last thread to take the lock), and every mutating door checks that the caller is either that thread or holding
 * the recursive lock. A violation raises `NSManagedObjectContextLockingError` — a 10.6 code that otherwise never
 * fires — instead of corrupting the sets. A correctly written client never sees it.
 */

#import <CoreData/NSManagedObjectContext.h>
#import <CoreData/CoreDataErrors.h>
#import <CoreData/NSManagedObject.h>
#import <CoreData/NSManagedObjectID.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/NSRelationshipDescription.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSError.h>
#import <Foundation/NSException.h>
#import <Foundation/NSLock.h>
#import <Foundation/NSUndoManager.h>
#include <pthread.h>

NSString *const NSManagedObjectContextWillSaveNotification = @"NSManagedObjectContextWillSaveNotification";
NSString *const NSManagedObjectContextDidSaveNotification = @"NSManagedObjectContextDidSaveNotification";
NSString *const NSManagedObjectContextObjectsDidChangeNotification = @"NSManagedObjectContextObjectsDidChangeNotification";
NSString *const NSInsertedObjectsKey = @"NSInsertedObjectsKey";
NSString *const NSUpdatedObjectsKey = @"NSUpdatedObjectsKey";
NSString *const NSDeletedObjectsKey = @"NSDeletedObjectsKey";
NSString *const NSRefreshedObjectsKey = @"NSRefreshedObjectsKey";
NSString *const NSInvalidatedObjectsKey = @"NSInvalidatedObjectsKey";
NSString *const NSInvalidatedAllObjectsKey = @"NSInvalidatedAllObjectsKey";

id NSErrorMergePolicy = nil;
id NSMergeByPropertyStoreTrumpMergePolicy = nil;
id NSMergeByPropertyObjectTrumpMergePolicy = nil;
id NSOverwriteMergePolicy = nil;
id NSRollbackMergePolicy = nil;

/* A merge policy is a NAME rather than a class, because 10.6 has no NSMergePolicy class to subclass. */
@interface CDMergePolicy : NSObject
{
	NSString *_name;
}
- (id)initWithName:(NSString *)name;
- (NSString *)name;
@end

@implementation CDMergePolicy
- (id)initWithName:(NSString *)name
{
	self = [super init];
	if (self != nil) { _name = [name retain]; }
	return self;
}
- (void)dealloc { [_name release]; [super dealloc]; }
- (NSString *)name { return _name; }
- (NSString *)description { return _name; }
@end

static NSError *CDError(NSInteger code, NSString *why)
{
	NSDictionary *info = [NSDictionary dictionaryWithObject:why forKey:@"reason"];
	return [NSError errorWithDomain:@"NSCocoaErrorDomain" code:code userInfo:info];
}

@implementation NSManagedObjectContext

+ (void)initialize
{
	if (self == [NSManagedObjectContext class]) {
		NSErrorMergePolicy = [[CDMergePolicy alloc] initWithName:@"NSErrorMergePolicy"];
		NSMergeByPropertyStoreTrumpMergePolicy =
		    [[CDMergePolicy alloc] initWithName:@"NSMergeByPropertyStoreTrumpMergePolicy"];
		NSMergeByPropertyObjectTrumpMergePolicy =
		    [[CDMergePolicy alloc] initWithName:@"NSMergeByPropertyObjectTrumpMergePolicy"];
		NSOverwriteMergePolicy = [[CDMergePolicy alloc] initWithName:@"NSOverwriteMergePolicy"];
		NSRollbackMergePolicy = [[CDMergePolicy alloc] initWithName:@"NSRollbackMergePolicy"];
	}
}

- (id)init
{
	self = [super init];
	if (self != nil) {
		_registered = [[NSMutableDictionary alloc] init];
		_inserted = [[NSMutableSet alloc] init];
		_updated = [[NSMutableSet alloc] init];
		_deleted = [[NSMutableSet alloc] init];
		_pendingInsertions = [[NSMutableSet alloc] init];
		_pendingUpdates = [[NSMutableSet alloc] init];
		_pendingDeletions = [[NSMutableSet alloc] init];
		_storeAssignments = [[NSMutableDictionary alloc] init];
		_lock = [[NSRecursiveLock alloc] init];
		_mergePolicy = [NSErrorMergePolicy retain];
		_propagatesDeletesAtEndOfEvent = YES;
		_owningThread = (unsigned long)pthread_self();
	}
	return self;
}

- (void)dealloc
{
	[_undoManager release];
	[_mergePolicy release];
	[_registered release];
	[_inserted release];
	[_updated release];
	[_deleted release];
	[_pendingInsertions release];
	[_pendingUpdates release];
	[_pendingDeletions release];
	[_storeAssignments release];
	[_lock release];
	[super dealloc];
}

/* ---- locking ------------------------------------------------------------------------------------- */

- (void)_claim
{
	_lockCount++;
	_lockOwner = (unsigned long)pthread_self();
	_owningThread = _lockOwner;
}

- (void)lock { [_lock lock]; [self _claim]; }

- (void)unlock
{
	if (_lockCount > 0) { _lockCount--; }
	if (_lockCount == 0) { _lockOwner = 0; }
	[_lock unlock];
}

- (BOOL)tryLock
{
	if ([_lock tryLock]) { [self _claim]; return YES; }
	return NO;
}

/* D2: the door every mutating method walks through. */
- (void)_checkThread
{
	unsigned long me = (unsigned long)pthread_self();

	if (_lockCount > 0 && _lockOwner == me) {
		return;			/* holding the lock: legal from any thread */
	}
	if (_owningThread == me) {
		return;
	}
	[NSException raise:NSInvalidArgumentException
	            format:@"NSError code %d: the context is owned by thread %lu and used from thread %lu without "
	                   @"the lock (COREDATA-PLAN.md D2)",
	                   NSManagedObjectContextLockingError, _owningThread, me];
}

/* ---- coordinator and undo manager ---------------------------------------------------------------- */

- (void)setPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator
{
	_coordinator = (id)coordinator;
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator { return _coordinator; }

- (NSUndoManager *)undoManager
{
	if (_undoManager == nil) {
		_undoManager = [[NSUndoManager alloc] init];
	}
	return _undoManager;
}

- (void)setUndoManager:(NSUndoManager *)undoManager
{
	id previous = _undoManager;

	_undoManager = [undoManager retain];
	[previous release];
}

- (NSUndoManager *)cd_undoManagerIfAny { return _undoManager; }

- (void)cd_rekeyRegisteredObjects
{
	NSArray *objects = [_registered allValues];
	NSUInteger i;

	/* A SAVE REPLACES TEMPORARY IDS WITH PERMANENT ONES, so the registry's keys go stale the moment the store
	 * names a row. Rebuilding from the objects' current IDs is cheaper than tracking each rename, and it is the
	 * only place the mapping is allowed to change. */
	[_registered removeAllObjects];
	for (i = 0; i < [objects count]; i++) {
		NSManagedObject *object = [objects objectAtIndex:i];
		if ([object managedObjectContext] == self) {
			[_registered setObject:object forKey:[object objectID]];
		}
	}
}
- (BOOL)cd_isUndoing { return _undoing; }

/* ---- registration -------------------------------------------------------------------------------- */

- (void)cd_registerManagedObject:(NSManagedObject *)object
{
	[_registered setObject:object forKey:[object objectID]];
	/* AN OBJECT CREATED INTO A CONTEXT IS AN INSERTION. Without this the context would answer `-hasChanges` NO
	 * for a brand-new object, because nothing had been *changed* yet — and the object exists. */
	if ([object isInserted]) {
		[_pendingInsertions addObject:object];
	}
}

- (NSManagedObject *)objectRegisteredForID:(NSManagedObjectID *)objectID
{
	[self _checkThread];
	return [_registered objectForKey:objectID];
}

- (NSManagedObject *)objectWithID:(NSManagedObjectID *)objectID
{
	NSManagedObject *object = [_registered objectForKey:objectID];
	NSEntityDescription *entity;
	Class cls;

	[self _checkThread];
	if (object != nil) {
		return object;
	}
	entity = [objectID entity];
	if (entity == nil) {
		return nil;
	}
	cls = NSClassFromString([entity managedObjectClassName]);
	if (cls == Nil) {
		cls = [NSManagedObject class];
	}
	object = [[cls alloc] initWithEntity:entity insertIntoManagedObjectContext:nil];
	[object cd_setManagedObjectContext:self];
	[object cd_setObjectID:objectID];
	/* A ROW NOTHING HAS READ YET IS A FAULT: reading any property fires it through -willAccessValueForKey:. */
	[object cd_setFault:YES];
	[_registered setObject:object forKey:objectID];
	return [object autorelease];
}

- (NSManagedObject *)existingObjectWithID:(NSManagedObjectID *)objectID error:(NSError **)error
{
	NSManagedObject *object = [self objectWithID:objectID];

	if (object == nil) {
		if (error != NULL) {
			*error = CDError(NSCoreDataError, @"no object for that ID");
		}
		return nil;
	}
	/* "-existing" MEANS THE ROW MUST EXIST IN THE STORE, so the fault is fired here rather than on first access. */
	(void)[object valueForKey:@"SELF"];
	return object;
}

- (void)cd_fireFaultForObject:(NSManagedObject *)object
{
	(void)object;
	/* W4 reads the row here. Until then a fired fault has no values to install, which is why W4's coordinator is
	 * asked through a door rather than reached through a type: the wiring exists, the store does not. */
	if ([(id<CDStoreDoors>)_coordinator respondsToSelector:@selector(cd_faultObject:inContext:)]) {
		[(id<CDStoreDoors>)_coordinator cd_faultObject:object inContext:self];
	}
}

/* ---- inserting and deleting ---------------------------------------------------------------------- */

- (void)insertObject:(NSManagedObject *)object
{
	[self _checkThread];
	if (object == nil) {
		return;
	}
	if ([_registered objectForKey:[object objectID]] == object) {
		return;
	}
	[object cd_setManagedObjectContext:self];
	[object cd_setInserted:YES];
	[object cd_setDeleted:NO];
	[_registered setObject:object forKey:[object objectID]];
	[_pendingInsertions addObject:object];
}

- (void)deleteObject:(NSManagedObject *)object
{
	[self _checkThread];
	if (object == nil) {
		return;
	}
	if ([object isInserted] && [_pendingInsertions containsObject:object]) {
		/* AN UNSAVED OBJECT IS FORGOTTEN RATHER THAN DELETED: there is no row to delete, and a DidSave that
		 * named it would be describing something that never existed. */
		[_pendingInsertions removeObject:object];
		[_registered removeObjectForKey:[object objectID]];
		[object cd_setInserted:NO];
		[object cd_setManagedObjectContext:nil];
		return;
	}
	[object prepareForDeletion];
	[object cd_setDeleted:YES];
	[_pendingUpdates removeObject:object];
	[_pendingDeletions addObject:object];
}

- (void)mergeChangesFromContextDidSaveNotification:(NSNotification *)notification
{
	NSDictionary *info = [notification userInfo];
	/* THE USER INFO CARRIES SETS, as Apple's own notification does — so they are normalised to arrays here rather
	 * than indexed, which is what a set would refuse to do at run time. */
	NSArray *inserted = [[info objectForKey:NSInsertedObjectsKey] allObjects];
	NSArray *updated = [[info objectForKey:NSUpdatedObjectsKey] allObjects];
	NSArray *deleted = [[info objectForKey:NSDeletedObjectsKey] allObjects];
	NSUInteger i;

	[self _checkThread];
	for (i = 0; i < [inserted count]; i++) {
		NSManagedObject *theirs = [inserted objectAtIndex:i];
		/* FAULT IT IN, DO NOT COPY IT: identity is the ID, and a second object for the same row would give the
		 * graph two answers to one question. */
		(void)[self objectWithID:[theirs objectID]];
	}
	for (i = 0; i < [deleted count]; i++) {
		NSManagedObject *mine = [_registered objectForKey:[[deleted objectAtIndex:i] objectID]];
		if (mine != nil && ![mine isDeleted]) {
			[self deleteObject:mine];
		}
	}
	for (i = 0; i < [updated count]; i++) {
		NSManagedObject *mine = [_registered objectForKey:[[updated objectAtIndex:i] objectID]];
		if (mine == nil || [mine cd_hasChanges]) {
			continue;	/* local work wins until a conflict is actually detected */
		}
		[ mine awakeFromSnapshotEvents:NSSnapshotEventMergePolicy];
	}
	[[NSNotificationCenter defaultCenter] postNotificationName:NSManagedObjectContextObjectsDidChangeNotification
	                                                    object:self
	                                                  userInfo:info];
}

/* ---- change tracking ----------------------------------------------------------------------------- */

- (void)cd_objectDidChange:(NSManagedObject *)object
{
	if (_undoing) {
		return;
	}
	if (object == nil) {
		return;
	}
	if ([object isInserted]) {
		[_pendingInsertions addObject:object];
	} else {
		[_pendingUpdates addObject:object];
	}
}

- (void)observeValueForKeyPath:(NSString *)keyPath
                      ofObject:(id)object
                        change:(NSDictionary *)change
                       context:(void *)context
{
	(void)keyPath; (void)change; (void)context;
	if ([object isKindOfClass:[NSManagedObject class]]) {
		[self cd_objectDidChange:object];
	}
}

- (BOOL)hasChanges
{
	NSArray *registered;

	[self _checkThread];
	NSUInteger i;

	if ([_pendingInsertions count] > 0 || [_pendingUpdates count] > 0 || [_pendingDeletions count] > 0) {
		return YES;
	}
	if ([_inserted count] > 0 || [_updated count] > 0 || [_deleted count] > 0) {
		return YES;
	}
	registered = [_registered allValues];
	for (i = 0; i < [registered count]; i++) {
		if ([[registered objectAtIndex:i] cd_hasChanges]) {
			return YES;
		}
	}
	return NO;
}

- (void)processPendingChanges
{
	NSMutableDictionary *info;
	NSArray *insertions, *updates, *deletions;
	NSUInteger i;

	[self _checkThread];
	if (_processing) {
		return;
	}
	_processing = YES;

	insertions = [_pendingInsertions allObjects];
	updates = [_pendingUpdates allObjects];
	deletions = [_pendingDeletions allObjects];

	for (i = 0; i < [insertions count]; i++) { [_inserted addObject:[insertions objectAtIndex:i]]; }
	for (i = 0; i < [updates count]; i++) { [_updated addObject:[updates objectAtIndex:i]]; }
	for (i = 0; i < [deletions count]; i++) { [_deleted addObject:[deletions objectAtIndex:i]]; }
	[_pendingInsertions removeAllObjects];
	[_pendingUpdates removeAllObjects];
	[_pendingDeletions removeAllObjects];

	if (_propagatesDeletesAtEndOfEvent) {
		[self _propagateDeletes];
	}

	if ([insertions count] + [updates count] + [deletions count] > 0) {
		info = [[NSMutableDictionary alloc] init];
		if ([insertions count] > 0) { [info setObject:[NSSet setWithArray:insertions] forKey:NSInsertedObjectsKey]; }
		if ([updates count] > 0) { [info setObject:[NSSet setWithArray:updates] forKey:NSUpdatedObjectsKey]; }
		if ([deletions count] > 0) { [info setObject:[NSSet setWithArray:deletions] forKey:NSDeletedObjectsKey]; }
		[[NSNotificationCenter defaultCenter] postNotificationName:NSManagedObjectContextObjectsDidChangeNotification
		                                                    object:self
		                                                  userInfo:info];
		[info release];
	}
	_processing = NO;
}

- (void)_propagateDeletes
{
	NSMutableArray *worklist = [[NSMutableArray alloc] initWithArray:[_deleted allObjects]];
	NSUInteger i;

	/* THE RULE LIVES ON THE RELATIONSHIP OF THE OBJECT BEING DELETED, not on the other side: `Department.staff`
	 * with `NSCascadeDeleteRule` is what makes deleting a Department delete its Employees, and reading the rule
	 * from `Employee.department` would answer a different question. The worklist runs to closure so a cascade
	 * chain settles in one pass.
	 *
	 * TO-ONE INVERSE NULLIFY IS DONE; TO-MANY INVERSE NULLIFY IS W4's, because removing a member from a
	 * relationship collection needs the mutable set a fetch installs, which does not exist yet. */
	while ([worklist count] > 0) {
		NSManagedObject *gone = [worklist objectAtIndex:0];
		NSArray *relationships = [[[gone entity] relationshipsByName] allValues];

		[worklist removeObjectAtIndex:0];
		for (i = 0; i < [relationships count]; i++) {
			NSRelationshipDescription *rel = [relationships objectAtIndex:i];
			NSRelationshipDescription *inverse = [rel inverseRelationship];
			id value = [gone primitiveValueForKey:[rel name]];
			NSArray *related;
			NSUInteger r;

			if (value == nil) { continue; }
			related = ([value respondsToSelector:@selector(allObjects)])
			    ? [value allObjects] : [NSArray arrayWithObject:value];

			for (r = 0; r < [related count]; r++) {
				NSManagedObject *other = [related objectAtIndex:r];
				if (other == nil || other == gone || [other isDeleted]) { continue; }

				switch ([rel deleteRule]) {
				case NSCascadeDeleteRule:
					[self deleteObject:other];
					/* MOVE IT NOW rather than on a second -processPendingChanges: "at the end of the event" is
					 * this event, and a caller that asked for one pass should get one pass. */
					[_pendingDeletions removeObject:other];
					[_deleted addObject:other];
					[worklist addObject:other];
					break;
				case NSNullifyDeleteRule:
					if (inverse != nil && ![inverse isToMany]) {
						NSString *key = [inverse name];
						[other willChangeValueForKey:key];
						[other setPrimitiveValue:nil forKey:key];
						[other didChangeValueForKey:key];
					}
					break;
				case NSDenyDeleteRule:
					/* THE STORE'S CHECK (W4): denying a delete needs the rows the context never fetched. */
					break;
				case NSNoActionDeleteRule:
					break;
				}
			}
		}
	}
	[worklist release];
}

- (NSSet *)insertedObjects { [self processPendingChanges]; return [[_inserted copy] autorelease]; }
- (NSSet *)updatedObjects { [self processPendingChanges]; return [[_updated copy] autorelease]; }
- (NSSet *)deletedObjects { [self processPendingChanges]; return [[_deleted copy] autorelease]; }
- (NSSet *)registeredObjects
{
	[self _checkThread];
	return [NSSet setWithArray:[_registered allValues]];
}

/* ---- refreshing, resetting, rolling back ---------------------------------------------------------- */

- (void)refreshObject:(NSManagedObject *)object mergeChanges:(BOOL)flag
{
	[self _checkThread];
	if (flag) {
		/* WITHOUT A STORE, "MERGE" IS "DISCARD THE DIFF": the committed snapshot is the only truth there is. W4
		 * re-reads the row first and merges into what came back. */
		[object cd_applyCommittedValues:[object cd_committedValues]];
		[object awakeFromSnapshotEvents:NSSnapshotEventRefresh];
	} else {
		[object cd_turnIntoFault];
	}
}

- (void)detectConflictsForObject:(NSManagedObject *)object
{
	(void)object;
	/* A CONFLICT IS A DISAGREEMENT WITH A STORE. There is no store until W4, so there is nothing to disagree
	 * with — an honest no-op rather than a fabricated merge. */
}

- (void)reset
{
	NSArray *registered = [_registered allValues];
	NSUInteger i;

	[self _checkThread];
	for (i = 0; i < [registered count]; i++) {
		NSManagedObject *object = [registered objectAtIndex:i];
		[object cd_turnIntoFault];
		[object cd_setInserted:NO];
		[object cd_setDeleted:NO];
		[object cd_setManagedObjectContext:nil];
	}
	[_registered removeAllObjects];
	[_inserted removeAllObjects];
	[_updated removeAllObjects];
	[_deleted removeAllObjects];
	[_pendingInsertions removeAllObjects];
	[_pendingUpdates removeAllObjects];
	[_pendingDeletions removeAllObjects];
	[[NSNotificationCenter defaultCenter] postNotificationName:NSManagedObjectContextObjectsDidChangeNotification
	                                                    object:self
	                                                  userInfo:[NSDictionary dictionaryWithObject:[NSNull null]
	                                                                                       forKey:NSInvalidatedAllObjectsKey]];
}

- (void)rollback
{
	NSArray *registered = [_registered allValues];
	NSArray *doomed = [_deleted allObjects];
	NSUInteger i;

	[self _checkThread];
	for (i = 0; i < [doomed count]; i++) {
		[[doomed objectAtIndex:i] cd_setDeleted:NO];
	}
	for (i = 0; i < [registered count]; i++) {
		NSManagedObject *object = [registered objectAtIndex:i];
		if ([object isInserted]) {
			[_registered removeObjectForKey:[object objectID]];
			[object cd_setInserted:NO];
			[object cd_setManagedObjectContext:nil];
		} else {
			[object cd_applyCommittedValues:[object cd_committedValues]];
		}
	}
	[_inserted removeAllObjects];
	[_updated removeAllObjects];
	[_deleted removeAllObjects];
	[_pendingInsertions removeAllObjects];
	[_pendingUpdates removeAllObjects];
	[_pendingDeletions removeAllObjects];
	[[NSNotificationCenter defaultCenter] postNotificationName:NSManagedObjectContextObjectsDidChangeNotification
	                                                    object:self
	                                                  userInfo:nil];
}

- (void)undo
{
	_undoing = YES;
	[self.undoManager undo];
	_undoing = NO;
	[self processPendingChanges];
}

- (void)redo
{
	_undoing = YES;
	[self.undoManager redo];
	_undoing = NO;
	[self processPendingChanges];
}

/* ---- save ----------------------------------------------------------------------------------------- */

- (BOOL)save:(NSError **)error
{
	NSArray *insertions;
	NSArray *updates;
	NSArray *deletions;
	NSDictionary *payload;
	NSUInteger i;

	[self _checkThread];
	[self lock];
	[self processPendingChanges];

	[[NSNotificationCenter defaultCenter] postNotificationName:NSManagedObjectContextWillSaveNotification
	                                                    object:self
	                                                  userInfo:nil];

	insertions = [_inserted allObjects];
	updates = [_updated allObjects];
	deletions = [_deleted allObjects];

	for (i = 0; i < [insertions count]; i++) {
		if (![[insertions objectAtIndex:i] validateForInsert:error]) {
			[self unlock];
			return NO;
		}
	}
	for (i = 0; i < [updates count]; i++) {
		if (![[updates objectAtIndex:i] validateForUpdate:error]) {
			[self unlock];
			return NO;
		}
	}
	for (i = 0; i < [deletions count]; i++) {
		if (![[deletions objectAtIndex:i] validateForDelete:error]) {
			[self unlock];
			return NO;
		}
	}

	if ([(id<CDStoreDoors>)_coordinator respondsToSelector:@selector(cd_saveContext:error:)]) {
		if (![(id<CDStoreDoors>)_coordinator cd_saveContext:self error:error]) {
			[self unlock];
			return NO;
		}
		[self cd_rekeyRegisteredObjects];
	} else {
		/* IN-MEMORY (documented in the header): adopt the diff, so the object graph believes the save happened.
		 * No durability is claimed and W4 replaces this branch with the store's round trip. */
		for (i = 0; i < [insertions count]; i++) {
			NSManagedObject *object = [insertions objectAtIndex:i];
			[object cd_applyCommittedValues:[self _currentValuesOfObject:object]];
			[object cd_setInserted:NO];
		}
		for (i = 0; i < [updates count]; i++) {
			NSManagedObject *object = [updates objectAtIndex:i];
			[object cd_applyCommittedValues:[self _currentValuesOfObject:object]];
		}
	}
	for (i = 0; i < [deletions count]; i++) {
		NSManagedObject *object = [deletions objectAtIndex:i];
		[object cd_setDeleted:NO];
		[_registered removeObjectForKey:[object objectID]];
		[object cd_setManagedObjectContext:nil];
	}

	payload = [NSDictionary dictionaryWithObjectsAndKeys:
	           [NSSet setWithArray:insertions], NSInsertedObjectsKey,
	           [NSSet setWithArray:updates], NSUpdatedObjectsKey,
	           [NSSet setWithArray:deletions], NSDeletedObjectsKey, nil];
	[_inserted removeAllObjects];
	[_updated removeAllObjects];
	[_deleted removeAllObjects];

	if (_undoManager != nil) {
		[_undoManager removeAllActions];
	}
	/* THE ASSIGNMENTS ARE CONSUMED BY THE SAVE: afterwards an object's ID names the store it went to, which is rule
	 * two of the coordinator's routing, so keeping the table would only let a stale entry outvote a fact. */
	[_storeAssignments removeAllObjects];
	[self unlock];

	[[NSNotificationCenter defaultCenter] postNotificationName:NSManagedObjectContextDidSaveNotification
	                                                    object:self
	                                                  userInfo:payload];
	return YES;
}

- (NSDictionary *)_currentValuesOfObject:(NSManagedObject *)object
{
	NSMutableDictionary *values = [[NSMutableDictionary alloc] init];
	NSArray *properties = [[object entity] properties];
	NSUInteger i;

	for (i = 0; i < [properties count]; i++) {
		NSString *key = [[properties objectAtIndex:i] name];
		id value = [object primitiveValueForKey:key];
		if (value != nil) {
			[values setObject:value forKey:key];
		}
	}
	return [values autorelease];
}

- (BOOL)obtainPermanentIDsForObjects:(NSArray *)objects error:(NSError **)error
{
	if ([(id<CDStoreDoors>)_coordinator
	     respondsToSelector:@selector(cd_obtainPermanentIDsForObjects:inContext:error:)]) {
		return [(id<CDStoreDoors>)_coordinator cd_obtainPermanentIDsForObjects:objects
		                                                            inContext:self
		                                                                error:error];
	}
	if (error != NULL) {
		*error = CDError(NSPersistentStoreOperationError,
		                 @"permanent IDs need a persistent store; NSPersistentStoreCoordinator arrives in "
		                 @"COREDATA-PLAN.md W4");
	}
	return NO;
}

/* ---- fetching ------------------------------------------------------------------------------------- */

- (NSArray *)executeFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
	[self _checkThread];
	if ([(id<CDStoreDoors>)_coordinator respondsToSelector:@selector(cd_executeFetchRequest:inContext:error:)]) {
		return [(id<CDStoreDoors>)_coordinator cd_executeFetchRequest:request inContext:self error:error];
	}
	if (error != NULL) {
		*error = CDError(NSCoreDataError,
		                 @"a fetch needs a store: NSPersistentStoreCoordinator is W4 and the fetch engine is W5");
	}
	return nil;
}

- (NSUInteger)countForFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
	/* THE STORE IS ASKED FIRST (§8). A count is the one door where the answer can come from SQL without any object
	 * ever existing, and on a 10^5-row file that is the difference between one query and 10^5 faults. A store that
	 * cannot translate answers -1 and the scan below is the reference it is measured against. */
	if ([(id<CDStoreDoors>)_coordinator respondsToSelector:
	     @selector(cd_countForFetchRequest:inContext:error:)]) {
		NSInteger counted = [(id<CDStoreDoors>)_coordinator cd_countForFetchRequest:request
		                                                                 inContext:self
		                                                                     error:error];
		if (counted >= 0) {
			return (NSUInteger)counted;
		}
	}
	{
		NSArray *results = [self executeFetchRequest:request error:error];

		return (results == nil) ? NSNotFound : [results count];
	}
}

/* ---- assignment, policy and the 10.6 properties ---------------------------------------------------- */

- (void)assignObject:(id)object toPersistentStore:(NSPersistentStore *)store
{
	if (object == nil) { return; }
	/* THE KEY IS THE OBJECT'S ID, NOT THE OBJECT: a managed object deliberately does not conform to NSCopying (one
	 * identity, one context, and a copy is a second object claiming the same row), so it cannot be a dictionary key
	 * — which the first version of this door found at run time, in a message from NSDictionary rather than from a
	 * compiler. The ID is stable while the object is unsaved and copyable, which is exactly what is needed.
	 *
	 * NIL CLEARS THE ASSIGNMENT rather than recording "assigned to nothing": a caller who passes nil means "let the
	 * coordinator decide again". */
	if (store == nil) {
		[_storeAssignments removeObjectForKey:[object objectID]];
		return;
	}
	[_storeAssignments setObject:store forKey:[object objectID]];
}

- (id)cd_persistentStoreForObject:(id)object
{
	return (object != nil) ? [_storeAssignments objectForKey:[object objectID]] : nil;
}

- (void)setMergePolicy:(id)mergePolicy
{
	id previous = _mergePolicy;
	_mergePolicy = [mergePolicy retain];
	[previous release];
}

- (id)mergePolicy { return _mergePolicy; }

- (BOOL)propagatesDeletesAtEndOfEvent { return _propagatesDeletesAtEndOfEvent; }
- (void)setPropagatesDeletesAtEndOfEvent:(BOOL)flag { _propagatesDeletesAtEndOfEvent = flag; }

- (BOOL)retainsRegisteredObjects { return _retainsRegisteredObjects; }
- (void)setRetainsRegisteredObjects:(BOOL)flag { _retainsRegisteredObjects = flag; }

- (NSTimeInterval)stalenessInterval { return _stalenessInterval; }
- (void)setStalenessInterval:(NSTimeInterval)expiration { _stalenessInterval = expiration; }

/* ---- coding -------------------------------------------------------------------------------------- */

- (id)copyWithZone:(NSZone *)zone
{
	(void)zone;
	return [self retain];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:[_mergePolicy description] forKey:@"mergePolicy"];
	[coder encodeDouble:_stalenessInterval forKey:@"stalenessInterval"];
	[coder encodeBool:_propagatesDeletesAtEndOfEvent forKey:@"propagatesDeletes"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [self init];
	if (self != nil) {
		_stalenessInterval = [coder decodeDoubleForKey:@"stalenessInterval"];
		_propagatesDeletesAtEndOfEvent = [coder decodeBoolForKey:@"propagatesDeletes"];
	}
	return self;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<NSManagedObjectContext: %lu registered, changes %@>",
	         (unsigned long)[_registered count], [self hasChanges] ? @"YES" : @"NO"];
}

@end
