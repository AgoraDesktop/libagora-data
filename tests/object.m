/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * object — W2's gate (COREDATA-PLAN.md §12): the value store, the diff, the fault state and validation.
 *
 * THE DIFF IS THE THING UNDER TEST, not KVC. `-changedValues` has to distinguish four cases — never touched,
 * changed, changed BACK, and cleared — and a suite that only checked "the value came back" would pass a class
 * that had no snapshot at all. So the object is given committed values by hand (the door W4's store will use),
 * and the diff is asked what it thinks after each edit.
 *
 * THE VALIDATION PREDICATES ARE EVALUATED AGAINST THE OBJECT, which is the subtle half: `SELF.age >= 0` names a
 * sibling property, so a suite that validated the bare value would prove nothing.
 */

#import <CoreData/CoreData.h>
#import <Foundation/NSAutoreleasePool.h>
#include <stdio.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond, what) do { \
	checks++; \
	if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, (what)); } \
} while (0)

static BOOL Raises(void (^block)(void))
{
	@try { block(); } @catch (NSException *e) { return YES; }
	return NO;
}

static int awakeFromFetchCount = 0;

@interface Person : NSManagedObject
@end

@implementation Person
- (void)awakeFromFetch { awakeFromFetchCount++; }
@end

static NSAttributeDescription *Attribute(NSString *name, NSAttributeType type, BOOL optional)
{
	NSAttributeDescription *a = [[[NSAttributeDescription alloc] init] autorelease];
	[a setName:name];
	[a setAttributeType:type];
	[a setOptional:optional];
	return a;
}

static NSEntityDescription *PersonEntity(void)
{
	NSEntityDescription *e = [[[NSEntityDescription alloc] init] autorelease];
	NSAttributeDescription *name = Attribute(@"name", NSStringAttributeType, NO);
	NSAttributeDescription *age = Attribute(@"age", NSInteger32AttributeType, NO);
	NSRelationshipDescription *department = [[[NSRelationshipDescription alloc] init] autorelease];

	[department setName:@"department"];
	[department setMaxCount:1];
	[age setValidationPredicates:[NSArray arrayWithObject:[NSPredicate predicateWithFormat:@"SELF.age >= 0"]]
	      withValidationWarnings:[NSArray arrayWithObject:@"age must not be negative"]];
	[e setName:@"Person"];
	[e setManagedObjectClassName:@"Person"];
	[e setProperties:[NSArray arrayWithObjects:name, age, department, nil]];
	return e;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSEntityDescription *entity = PersonEntity();
	NSEntityDescription *otherEntity = [[[NSEntityDescription alloc] init] autorelease];
	Person *person = [[Person alloc] initWithEntity:entity insertIntoManagedObjectContext:nil];

	[otherEntity setName:@"Other"];

	/* 1. identity, before any store exists */
	CHECK([person entity] == entity, "the object knows its entity");
	CHECK([[person objectID] isTemporaryID] == YES, "an unsaved object's ID is temporary");
	CHECK([person isInserted] == NO, "an object created with no context is not inserted");
	CHECK([[[person objectID] URIRepresentation] absoluteString] != nil, "the ID has a URI form");

	/* 2. two IDs naming the same row agree, and one naming a different row does not */
	{
		NSManagedObjectID *a = [[NSManagedObjectID alloc] initWithEntity:entity persistentStore:nil
		                                                    primaryKey:[NSNumber numberWithInt:7] temporary:NO];
		NSManagedObjectID *b = [[NSManagedObjectID alloc] initWithEntity:entity persistentStore:nil
		                                                    primaryKey:[NSNumber numberWithInt:7] temporary:NO];
		NSManagedObjectID *c = [[NSManagedObjectID alloc] initWithEntity:entity persistentStore:nil
		                                                    primaryKey:[NSNumber numberWithInt:8] temporary:NO];
		NSManagedObjectID *temporary = [[NSManagedObjectID alloc] initWithEntity:entity persistentStore:nil
		                                                           primaryKey:[NSNumber numberWithInt:7] temporary:YES];

		CHECK([a isEqual:b] == YES && [a hash] == [b hash], "the same row's IDs are equal and hash alike");
		CHECK([a isEqual:c] == NO, "a different key is a different row");
		CHECK([a isEqual:temporary] == NO, "a temporary ID never equals a permanent one");
		[a release]; [b release]; [c release]; [temporary release];
	}

	/* 3. the value store and the snapshot */
	[person setValue:@"alice" forKey:@"name"];
	CHECK([[person valueForKey:@"name"] isEqual:@"alice"], "a value written is a value read");
	CHECK([[[person changedValues] allKeys] containsObject:@"name"], "and it is in the diff");
	CHECK([[[person committedValuesForKeys:[NSArray arrayWithObject:@"name"]] allKeys] count] == 0,
	      "with nothing committed behind it");
	CHECK([person isUpdated] == YES, "a changed, non-inserted object is updated");

	/* 4. W4's door: adopting what the store holds clears the diff */
	[person cd_applyCommittedValues:[NSDictionary dictionaryWithObjectsAndKeys:
	                                 @"alice", @"name",
	                                 [NSNumber numberWithInt:40], @"age", nil]];
	CHECK([[person changedValues] count] == 0, "adopting committed values clears the diff");
	CHECK([person isUpdated] == NO, "and the object is clean again");
	CHECK([[[person committedValuesForKeys:[NSArray arrayWithObject:@"age"]] objectForKey:@"age"] intValue] == 40,
	      "the committed snapshot is readable");

	/* 5. equality suppression: re-stamping what the store already holds is not a change */
	[person setValue:@"alice" forKey:@"name"];
	CHECK([[person changedValues] count] == 0, "writing back the same value is not a change");
	[person setValue:@"bob" forKey:@"name"];
	CHECK([[[person changedValues] objectForKey:@"name"] isEqual:@"bob"], "writing a new one is");

	/* 6. clearing is a change, and it survives the dictionary's inability to hold nil */
	[person setPrimitiveValue:nil forKey:@"age"];
	CHECK([[person changedValues] objectForKey:@"age"] == [NSNull null],
	      "clearing a value records NSNull rather than disappearing");
	CHECK([person primitiveValueForKey:@"age"] == nil, "and reads back as nil");

	/* 7. faulting: the access chokepoint fires the fault and tells the subclass */
	awakeFromFetchCount = 0;
	[person cd_setFault:YES];
	CHECK([person isFault] == YES, "a fault is a fault");
	CHECK([person hasFaultForRelationshipNamed:@"department"] == YES,
	      "a faulted object has a fault for its unfetched relationship");
	(void)[person valueForKey:@"name"];
	CHECK([person isFault] == NO, "reading fires the fault");
	CHECK(awakeFromFetchCount == 1, "and calls -awakeFromFetch exactly once");

	/* 8. validation: mandatory, and a predicate that names a sibling property */
	{
		id nilValue = nil;
		id badAge = [NSNumber numberWithInt:-1];
		id goodAge = [NSNumber numberWithInt:5];
		NSError *error = nil;

		CHECK([person validateValue:&nilValue forKey:@"name" error:&error] == NO,
		      "a non-optional attribute refuses nil");
		CHECK([error code] == NSValidationMissingMandatoryPropertyError, "with the mandatory-key code");

		error = nil;
		CHECK([person validateValue:&badAge forKey:@"age" error:&error] == NO,
		      "a validation predicate refuses -1");
		CHECK([error code] == NSManagedObjectValidationError, "with the validation code");
		CHECK([person validateValue:&goodAge forKey:@"age" error:NULL] == YES, "and accepts 5");
	}

	/* 9. the aggregate door: one bad property fails the insert */
	{
		NSError *error = nil;
		[person setValue:nil forKey:@"name"];
		[person setValue:[NSNumber numberWithInt:-5] forKey:@"age"];
		CHECK([person validateForInsert:&error] == NO, "validateForInsert walks every property");
		CHECK(error != nil, "and reports which one failed");
	}

	/* 10. the hooks and the identity that cannot be copied */
	[person setObservationInfo:(id)0x1234];
	CHECK([person observationInfo] == (id)0x1234, "observationInfo round-trips");
	CHECK(Raises(^{ (void)[person copy]; }) == YES, "a managed object cannot be copied");
	CHECK([NSManagedObject contextShouldIgnoreUnmodeledPropertyChanges] == NO,
	      "unmodelled property changes are not ignored by default");

	[person release];
	printf("object: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
