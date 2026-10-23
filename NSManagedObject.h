/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSManagedObject — the object in the graph. W2 of COREDATA-PLAN.md §12.
 *
 * A MANAGED OBJECT IS NEVER ITS OWN SOURCE OF TRUTH. Its values live in a dictionary the store refreshes, and a
 * change is recorded as a DIFFERENCE from that dictionary rather than as a mutation of it. Everything the class
 * answers follows from those two facts:
 *
 *   `-changedValues`      is the diff, computed on demand;
 *   `-committedValuesForKeys:` is the dictionary;
 *   `-hasChanges`-style state is "the diff is non-empty";
 *   `-isDeleted`/`-isInserted` are context bookkeeping, not value states.
 *
 * THE ACCESSORS ARE A CHOKEPOINT PAIR, NOT KVC FOR ITS OWN SAKE. `-valueForKey:`/`-setValue:forKey:` route every
 * modelled property through `-willAccessValueForKey:` and `-willChangeValueForKey:`, and it is those two doors a
 * fault fires from and KVO observes from. A subclass's `@dynamic` accessors reach the same place through
 * `-primitiveValueForKey:`, so there is exactly one place a value can be read or written — which is why W4 can
 * add a store behind it without touching this class.
 *
 * `-copy` IS REFUSED BY OMISSION, AS IT IS IN COCOA: a managed object has one identity in one context, and a copy
 * would be a second object claiming the same row. The suite asserts the refusal.
 */

#ifndef COREDATA_NSMANAGEDOBJECT_H
#define COREDATA_NSMANAGEDOBJECT_H

#import <Foundation/Foundation.h>
#import <CoreData/CoreDataDefines.h>
#import <CoreData/NSManagedObjectID.h>

typedef NSUInteger NSSnapshotEventType;

enum {
	NSSnapshotEventUndoInsertion = 1 << 1,
	NSSnapshotEventUndoDeletion = 1 << 2,
	NSSnapshotEventUndoUpdate = 1 << 3,
	NSSnapshotEventRollback = 1 << 4,
	NSSnapshotEventRefresh = 1 << 5,
	NSSnapshotEventMergePolicy = 1 << 6
};

@class NSEntityDescription;
@class NSManagedObjectContext;
@class NSError;

@interface NSManagedObject : NSObject
{
	NSEntityDescription *_entity;		/* retained */
	NSManagedObjectID *_objectID;		/* retained, created on demand */
	NSManagedObjectContext *_context;	/* NOT retained: the context owns the registered objects */
	NSMutableDictionary *_committed;	/* the last values the store is known to hold */
	NSMutableDictionary *_changed;		/* the diff, or nil when there is none */
	NSMutableDictionary *_mutableSets;	/* to-many relationship values, kept mutable so they can be added to */
	id _observationInfo;
	BOOL _inserted;
	BOOL _deleted;
	BOOL _fault;
	NSUInteger _faultingState;
}

+ (BOOL)contextShouldIgnoreUnmodeledPropertyChanges;

- (id)initWithEntity:(NSEntityDescription *)entity
    insertIntoManagedObjectContext:(NSManagedObjectContext *)context;

- (NSManagedObjectContext *)managedObjectContext;
- (NSEntityDescription *)entity;
- (NSManagedObjectID *)objectID;

- (BOOL)isInserted;
- (BOOL)isUpdated;
- (BOOL)isDeleted;
- (BOOL)isFault;

- (BOOL)hasFaultForRelationshipNamed:(NSString *)key;
- (NSUInteger)faultingState;

- (void)willAccessValueForKey:(NSString *)key;
- (void)didAccessValueForKey:(NSString *)key;
- (void)willChangeValueForKey:(NSString *)key;
- (void)didChangeValueForKey:(NSString *)key;
- (void)willChangeValueForKey:(NSString *)inKey
             withSetMutation:(NSKeyValueSetMutationKind)inMutationKind
                usingObjects:(NSSet *)inObjects;
- (void)didChangeValueForKey:(NSString *)inKey
            withSetMutation:(NSKeyValueSetMutationKind)inMutationKind
               usingObjects:(NSSet *)inObjects;

- (void)setObservationInfo:(id)inObservationInfo;
- (id)observationInfo;

- (void)awakeFromFetch;
- (void)awakeFromInsert;
- (void)awakeFromSnapshotEvents:(NSSnapshotEventType)flags;
- (void)prepareForDeletion;
- (void)willSave;
- (void)didSave;
- (void)willTurnIntoFault;
- (void)didTurnIntoFault;

- (id)valueForKey:(NSString *)key;
- (void)setValue:(id)value forKey:(NSString *)key;
- (id)primitiveValueForKey:(NSString *)key;
- (void)setPrimitiveValue:(id)value forKey:(NSString *)key;

- (NSDictionary *)committedValuesForKeys:(NSArray *)keys;
- (NSDictionary *)changedValues;

- (BOOL)validateValue:(id *)value forKey:(NSString *)key error:(NSError **)error;
- (BOOL)validateForDelete:(NSError **)error;
- (BOOL)validateForInsert:(NSError **)error;
- (BOOL)validateForUpdate:(NSError **)error;

@end

#endif /* COREDATA_NSMANAGEDOBJECT_H */
