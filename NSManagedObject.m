/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSManagedObject.m — the value store, the diff, the fault state and the validation doors.
 *
 * TWO DICTIONARIES, ONE RULE. `_committed` is what the store is known to hold; `_changed` is what this object
 * has been told since. A read consults the diff first, so a change is visible immediately without the committed
 * snapshot being rewritten — which is what makes `-changedValues` a computation rather than a bookkeeping
 * problem, and what will let W3's `-rollback` throw the diff away.
 *
 * `NSNull` IS THE DIFF'S "EXPLICITLY NIL". A dictionary cannot store nil, and "this attribute was set to nil"
 * is a fact that has to survive: without it, `-changedValues` could not distinguish "never touched" from
 * "cleared", and a save would write nothing where it must write NULL.
 *
 * THE EQUALITY SUPPRESSION IS DELIBERATE: a key set to the value it already had is NOT a change and does not
 * appear in `-changedValues`. Apple's behaviour, and the reason an object can be re-stamped with a value from a
 * table view without every row turning dirty.
 */

#import <CoreData/NSManagedObject.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSAttributeDescription.h>
#import <CoreData/NSRelationshipDescription.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/CoreDataErrors.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSNull.h>
#import <Foundation/NSError.h>
#import <Foundation/NSException.h>
#import <Foundation/NSKeyValueObserving.h>

#import <Foundation/NSUndoManager.h>
#import <CoreData/NSManagedObjectContext.h>

/* One counter for temporary IDs, as Apple's own temporary keys are small integers. Locking is W3's problem: an
 * object cannot be created without a context, and a context is a lock. */
static NSUInteger CDTemporaryKeyCounter = 0;

@implementation NSManagedObject

+ (BOOL)contextShouldIgnoreUnmodeledPropertyChanges { return NO; }

- (id)init
{
	return [self initWithEntity:nil insertIntoManagedObjectContext:nil];
}

- (id)initWithEntity:(NSEntityDescription *)entity
    insertIntoManagedObjectContext:(NSManagedObjectContext *)context
{
	self = [super init];
	if (self != nil) {
		_entity = [entity retain];
		_committed = [[NSMutableDictionary alloc] init];
		_context = (id)context;
		if (context != nil) {
			_inserted = YES;
			if ([(id)context respondsToSelector:@selector(cd_registerManagedObject:)]) {
				[(id)context cd_registerManagedObject:self];
			}
		}
	}
	return self;
}

- (void)dealloc
{
	[_entity release];
	[_objectID release];
	[_committed release];
	[_changed release];
	[_mutableSets release];
	[super dealloc];
}

- (NSEntityDescription *)entity { return _entity; }
- (NSManagedObjectContext *)managedObjectContext { return _context; }
- (void)cd_setManagedObjectContext:(id)context { _context = context; }

- (NSManagedObjectID *)objectID
{
	if (_objectID == nil) {
		_objectID = [[NSManagedObjectID alloc] initWithEntity:_entity
		                                     persistentStore:nil
		                                         primaryKey:[NSNumber numberWithInteger:(NSInteger)(++CDTemporaryKeyCounter)]
		                                          temporary:YES];
	}
	return _objectID;
}

/* ---- state --------------------------------------------------------------------------------------- */

- (BOOL)isInserted { return _inserted; }
- (void)cd_setInserted:(BOOL)flag { _inserted = flag; }

- (BOOL)isDeleted { return _deleted; }
- (void)cd_setDeleted:(BOOL)flag { _deleted = flag; }

- (BOOL)cd_hasChanges
{
	NSDictionary *diff = [self changedValues];
	return ([diff count] > 0);
}

- (BOOL)isUpdated { return (!_inserted && !_deleted && [self cd_hasChanges]); }

- (BOOL)isFault { return _fault; }
- (NSUInteger)faultingState { return _faultingState; }

- (BOOL)hasFaultForRelationshipNamed:(NSString *)key
{
	NSPropertyDescription *p = [[_entity propertiesByName] objectForKey:key];

	/* A TO-ONE RELATIONSHIP WITH NO VALUE IS NOT A FAULT, it is a nil — the distinction is what stops a fault
	 * being fired for every optional relationship in the graph. */
	if (p == nil || ![p isKindOfClass:[NSRelationshipDescription class]]) {
		return NO;
	}
	return (_fault && [self primitiveValueForKey:key] == nil);
}

- (void)cd_setFault:(BOOL)flag { _fault = flag; }

- (void)cd_setObjectID:(NSManagedObjectID *)objectID
{
	[objectID retain];
	[_objectID release];
	_objectID = objectID;
}

- (NSDictionary *)cd_committedValues { return _committed; }

- (void)cd_turnIntoFault
{
	if (_fault) {
		return;
	}
	[self willTurnIntoFault];
	[_changed release];
	_changed = nil;
	[_committed removeAllObjects];
	_fault = YES;
	[self didTurnIntoFault];
}

/* ---- the access chokepoint ----------------------------------------------------------------------- */

- (void)willAccessValueForKey:(NSString *)key
{
	(void)key;
	if (_fault) {
		_faultingState++;
		_fault = NO;
		/* W4 puts the store behind this door. Until then a fault has nothing to fire from, and saying so is
		 * better than pretending it fired: the context door is asked only if it exists. */
		if ([_context respondsToSelector:@selector(cd_fireFaultForObject:)]) {
			[_context cd_fireFaultForObject:self];
		}
		_faultingState--;
		[self awakeFromFetch];
	}
}

- (void)didAccessValueForKey:(NSString *)key { (void)key; }

- (void)willChangeValueForKey:(NSString *)key { [super willChangeValueForKey:key]; }
- (void)didChangeValueForKey:(NSString *)key
{
	[super didChangeValueForKey:key];
	[_context cd_objectDidChange:self];
}

- (void)willChangeValueForKey:(NSString *)inKey
             withSetMutation:(NSKeyValueSetMutationKind)inMutationKind
                usingObjects:(NSSet *)inObjects
{
	[super willChangeValueForKey:inKey withSetMutation:inMutationKind usingObjects:inObjects];
}

- (void)didChangeValueForKey:(NSString *)inKey
            withSetMutation:(NSKeyValueSetMutationKind)inMutationKind
               usingObjects:(NSSet *)inObjects
{
	[super didChangeValueForKey:inKey withSetMutation:inMutationKind usingObjects:inObjects];
}

/* ---- the values ---------------------------------------------------------------------------------- */

- (NSRelationshipDescription *)cd_relationshipForKey:(NSString *)key
{
	NSPropertyDescription *property = [[_entity propertiesByName] objectForKey:key];

	return [property isKindOfClass:[NSRelationshipDescription class]]
	    ? (NSRelationshipDescription *)property : nil;
}

/* A TO-MANY VALUE IS A COLLECTION, NOT A VALUE, and a collection a caller cannot add to is not a relationship:
 * `-primitiveValueForKey:` answers a working NSMutableSet that IS the object's value, so `[dept.staff member]`
 * style access and `-addObject:` both do the expected thing. Mutations through the set do not yet fire KVO or
 * register undo — that needs a proxied collection, and it is the next slice rather than a claim made here. */
- (id)primitiveValueForKey:(NSString *)key
{
	NSRelationshipDescription *relationship = [self cd_relationshipForKey:key];
	id value = [_changed objectForKey:key];

	if (relationship != nil && [relationship isToMany]) {
		NSMutableSet *working = [_mutableSets objectForKey:key];

		if (working == nil) {
			working = [[NSMutableSet alloc] init];
			if (value == nil || value == [NSNull null]) {
				value = [_committed objectForKey:key];
			}
			/* A TO-MANY VALUE HAS TWO SHAPES: a set, in the object graph, and an ARRAY OF REFERENCES, which is what
			 * a store's node holds and what `-cd_applyCommittedValues:` installs after a save. Both are accepted
			 * here, because the alternative — refusing one — raised `-[AGArrayMutable allObjects] is not
			 * implemented` the first time a 10^5-row workload read a relationship back from its own save. */
			if (value != nil && value != [NSNull null]) {
				if ([value respondsToSelector:@selector(allObjects)]) {
					[working unionSet:value];
				} else if ([value respondsToSelector:@selector(count)]) {
					NSUInteger m;

					for (m = 0; m < [value count]; m++) {
						[working addObject:[value objectAtIndex:m]];
					}
				}
			}
			if (_mutableSets == nil) {
				_mutableSets = [[NSMutableDictionary alloc] init];
			}
			[_mutableSets setObject:working forKey:key];
			[working release];
		}
		return working;
	}

	if (value != nil) {
		return (value == [NSNull null]) ? nil : value;
	}
	value = [_committed objectForKey:key];
	if (value != nil) {
		return value;
	}
	/* AN UNFETCHED ATTRIBUTE ANSWERS ITS DEFAULT, which is what makes a newly inserted object usable before it
	 * has ever been saved. */
	{
		NSPropertyDescription *p = [[_entity propertiesByName] objectForKey:key];
		if ([p isKindOfClass:[NSAttributeDescription class]]) {
			return [(NSAttributeDescription *)p defaultValue];
		}
	}
	return nil;
}

- (void)setPrimitiveValue:(id)value forKey:(NSString *)key
{
	if ([_entity propertiesByName] == nil ||
	    [[_entity propertiesByName] objectForKey:key] == nil) {
		/* NOT A MODELLED KEY: Apple's `+contextShouldIgnoreUnmodeledPropertyChanges` exists for exactly this
		 * case, and this class's answer is NO, so an unmodelled write is routed to KVC and not kept here. */
		[super setValue:value forKey:key];
		return;
	}
	if (_changed == nil) {
		_changed = [[NSMutableDictionary alloc] init];
	}
	{
		NSRelationshipDescription *relationship = [self cd_relationshipForKey:key];

		if (relationship != nil && [relationship isToMany]) {
			NSMutableSet *working = [(value != nil) ? value : (id)[NSSet set] mutableCopy];

			if (_mutableSets == nil) {
				_mutableSets = [[NSMutableDictionary alloc] init];
			}
			[_mutableSets setObject:working forKey:key];
			[_changed setObject:working forKey:key];
			[working release];
			return;
		}
	}
	[_changed setObject:(value != nil) ? value : (id)[NSNull null] forKey:key];
}

- (id)valueForKey:(NSString *)key
{
	id value;

	/* `SELF` IS KVC'S NAME FOR THE OBJECT, and a managed object must answer it: a validation predicate is written
	 * `SELF.age >= 0`, and that key path is resolved by asking this object for "SELF" and then for "age". Apple's
	 * NSManagedObject answers it for the same reason, and without it every SELF-qualified predicate raises. */
	if ([key isEqualToString:@"SELF"]) {
		return self;
	}
	if ([[_entity propertiesByName] objectForKey:key] == nil) {
		return [super valueForKey:key];
	}
	[self willAccessValueForKey:key];
	value = [self primitiveValueForKey:key];
	[self didAccessValueForKey:key];
	return value;
}

- (void)setValue:(id)value forKey:(NSString *)key
{
	if ([[_entity propertiesByName] objectForKey:key] == nil) {
		[super setValue:value forKey:key];
		return;
	}
	/* UNDO IS REGISTERED BEFORE THE CHANGE, capturing the value being replaced: that is the only moment the old
	 * value is still there. IT IS REGISTERED DURING AN UNDO TOO — NSUndoManager routes a registration made while
	 * it is undoing into the REDO stack, which is the whole mechanism. Suppressing it there was the first attempt
	 * and it made -redo a no-op: there was nothing on the stack to redo. The context's `_undoing` flag exists to
	 * keep the change-tracking quiet, not to stop this. */
	{
		id previous = [self primitiveValueForKey:key];
		NSUndoManager *undo = [_context undoManager];

		if (undo != nil) {
			[undo registerUndoWithTarget:self handler:^(id target) {
				[target setValue:previous forKey:key];
			}];
		}
	}
	[self willChangeValueForKey:key];
	[self cd_maintainInverseForRelationship:key oldValue:[self primitiveValueForKey:key]];
	[self setPrimitiveValue:value forKey:key];
	[self cd_maintainInverseForRelationship:key newValue:value];
	[self didChangeValueForKey:key];
}

/* THE OTHER SIDE OF A RELATIONSHIP IS UPDATED WHEN ONE SIDE IS SET, which is what makes the graph a graph rather
 * than two independent edges. `_maintaining` stops the update from recursing: the reverse write calls this method
 * again through `-setValue:forKey:`'s primitives, and only one direction should unlink first.
 *
 * A DELETED OR UNREGISTERED OBJECT IS NOT LINKED: an inverse pointing at an object the context has forgotten is the
 * dangling reference the delete rules exist to prevent. */
- (void)cd_maintainInverseForRelationship:(NSString *)key oldValue:(id)oldValue
{
	NSRelationshipDescription *relationship = [self cd_relationshipForKey:key];
	NSRelationshipDescription *inverse;
	NSArray *members;
	NSUInteger i;

	if (relationship == nil || (inverse = [relationship inverseRelationship]) == nil) {
		return;
	}
	if (oldValue == nil) {
		return;
	}
	members = [oldValue respondsToSelector:@selector(allObjects)]
	    ? [oldValue allObjects] : [NSArray arrayWithObject:oldValue];
	for (i = 0; i < [members count]; i++) {
		id other = [members objectAtIndex:i];
		if (![other isKindOfClass:[NSManagedObject class]] || other == self) { continue; }
		if ([inverse isToMany]) {
			[[other primitiveValueForKey:[inverse name]] removeObject:self];
		} else if ([other primitiveValueForKey:[inverse name]] == self) {
			[other setPrimitiveValue:nil forKey:[inverse name]];
		}
	}
}

- (void)cd_maintainInverseForRelationship:(NSString *)key newValue:(id)newValue
{
	NSRelationshipDescription *relationship = [self cd_relationshipForKey:key];
	NSRelationshipDescription *inverse;
	NSArray *members;
	NSUInteger i;

	if (relationship == nil || (inverse = [relationship inverseRelationship]) == nil) {
		return;
	}
	if (newValue == nil) {
		return;
	}
	members = [newValue respondsToSelector:@selector(allObjects)]
	    ? [newValue allObjects] : [NSArray arrayWithObject:newValue];
	for (i = 0; i < [members count]; i++) {
		id other = [members objectAtIndex:i];
		if (![other isKindOfClass:[NSManagedObject class]] || other == self) { continue; }
		if ([inverse isToMany]) {
			[[other primitiveValueForKey:[inverse name]] addObject:self];
		} else {
			[other setPrimitiveValue:self forKey:[inverse name]];
		}
	}
}

/* ---- the diff ------------------------------------------------------------------------------------ */

- (NSDictionary *)committedValuesForKeys:(NSArray *)keys
{
	NSMutableDictionary *out = [[NSMutableDictionary alloc] init];
	NSUInteger i;

	for (i = 0; i < [keys count]; i++) {
		NSString *key = [keys objectAtIndex:i];
		id value = [_committed objectForKey:key];
		if (value != nil) {
			[out setObject:value forKey:key];
		}
	}
	return [out autorelease];
}

- (NSDictionary *)changedValues
{
	NSMutableDictionary *out = [[NSMutableDictionary alloc] init];
	NSArray *keys = [_changed allKeys];
	NSUInteger i;

	for (i = 0; i < [keys count]; i++) {
		NSString *key = [keys objectAtIndex:i];
		id now = [_changed objectForKey:key];
		id before = [_committed objectForKey:key];

		if (before == nil) {
			/* A key the store has never seen IS a change unless it is being cleared to a value it never had. */
			if (now == [NSNull null]) {
				continue;
			}
			[out setObject:now forKey:key];
			continue;
		}
		if (now == before || [now isEqual:before]) {
			continue;	/* equality suppression: re-stamping the same value is not a change */
		}
		[out setObject:now forKey:key];
	}
	return [out autorelease];
}

- (void)cd_applyCommittedValues:(NSDictionary *)values
{
	NSMutableDictionary *fresh = [[NSMutableDictionary alloc] initWithDictionary:values];
	NSMutableDictionary *previous = _committed;
	NSUInteger i;

	/* THE INPUT MAY BE `_committed` ITSELF — `-rollback` hands it back — so the new snapshot is built FIRST and
	 * swapped in. Clearing in place read from the dictionary it was emptying, which silently produced an empty
	 * snapshot and a rollback that forgot everything. */
	_committed = fresh;
	[previous release];
	/* THE WORKING COLLECTIONS ARE DERIVED, so they are dropped rather than merged: the next read rebuilds each one
	 * from the snapshot that was just installed. */
	[_mutableSets release];
	_mutableSets = nil;
	(void)i;
	/* A SAVE CLEARS THE DIFF AFTER ADOPTING IT: what was changed is now what the store holds. */
	[_changed release];
	_changed = nil;
}

/* ---- validation ---------------------------------------------------------------------------------- */

static NSError *CDValidationError(NSString *key, NSPropertyDescription *property, NSInteger code)
{
	NSMutableDictionary *info = [[NSMutableDictionary alloc] init];
	NSError *error;

	[info setObject:key forKey:NSValidationKeyErrorKey];
	if (property != nil) {
		[info setObject:property forKey:NSValidationPredicateErrorKey];
	}
	error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:code userInfo:info];
	[info release];
	return error;
}

- (BOOL)validateValue:(id *)value forKey:(NSString *)key error:(NSError **)error
{
	NSPropertyDescription *property = [[_entity propertiesByName] objectForKey:key];
	NSArray *predicates;
	NSUInteger i;

	if (property == nil) {
		return YES;
	}
	/* MANDATORY FIRST: it is the condition a caller can fix without reading a message. */
	if (![property isOptional] && (*value == nil) && ![property isTransient]) {
		if (error != NULL) {
			*error = CDValidationError(key, property, NSValidationMissingMandatoryPropertyError);
		}
		return NO;
	}
	/* THE PREDICATES ARE EVALUATED AGAINST THE OBJECT *WITH THE CANDIDATE IN PLACE*. Apple's validation
	 * predicates are written `SELF.startDate <= SELF.endDate`: they name sibling properties, so a bare value
	 * cannot answer them — but the object's own value is the OLD one, so evaluating against it would validate the
	 * wrong thing. The candidate is swapped into the diff, judged, and the diff is restored exactly, which is why
	 * this door takes `id *` rather than `id` at all. */
	predicates = [property validationPredicates];
	if ([predicates count] > 0) {
		id previous = [_changed objectForKey:key];
		BOOL hadPrevious = (previous != nil);
		BOOL ok = YES;

		[self setPrimitiveValue:*value forKey:key];
		for (i = 0; i < [predicates count]; i++) {
			if (![[predicates objectAtIndex:i] evaluateWithObject:self]) {
				ok = NO;
				break;
			}
		}
		if (hadPrevious) {
			[_changed setObject:previous forKey:key];
		} else if (_changed != nil) {
			[_changed removeObjectForKey:key];
		}
		if (!ok) {
			if (error != NULL) {
				*error = CDValidationError(key, property, NSManagedObjectValidationError);
			}
			return NO;
		}
	}
	return YES;
}

- (BOOL)validateForDelete:(NSError **)error
{
	(void)error;
	/* THE RELATIONSHIP CARDINALITY AND DELETE RULES ARE THE STORE'S BUSINESS (W4): a delete is refused by the
	 * context that knows what points at this object, not by the object that cannot see it. */
	return YES;
}

- (BOOL)_validateAllProperties:(NSError **)error
{
	NSDictionary *byName = [_entity propertiesByName];
	NSArray *keys = [byName allKeys];
	NSUInteger i;

	for (i = 0; i < [keys count]; i++) {
		NSString *key = [keys objectAtIndex:i];
		id value = [self primitiveValueForKey:key];
		NSError *one = nil;

		if (![self validateValue:&value forKey:key error:&one]) {
			if (error != NULL) {
				*error = one;
			}
			return NO;
		}
	}
	return YES;
}

- (BOOL)validateForInsert:(NSError **)error { return [self _validateAllProperties:error]; }
- (BOOL)validateForUpdate:(NSError **)error { return [self _validateAllProperties:error]; }

/* ---- hooks, all no-ops that a subclass overrides -------------------------------------------------- */

- (void)awakeFromFetch { }
- (void)awakeFromInsert { }
- (void)awakeFromSnapshotEvents:(NSSnapshotEventType)flags { (void)flags; }
- (void)prepareForDeletion { }
- (void)willSave { }
- (void)didSave { }
- (void)willTurnIntoFault { }
- (void)didTurnIntoFault { }

- (void)setObservationInfo:(id)inObservationInfo { _observationInfo = inObservationInfo; }
- (id)observationInfo { return _observationInfo; }

- (NSString *)description
{
	return [NSString stringWithFormat:@"<NSManagedObject: %@ (%@)>", [_entity name], [self objectID]];
}

@end
