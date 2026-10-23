/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * context — W3's gate (COREDATA-PLAN.md §12): the six sets, the save pipeline, undo, rollback, delete propagation,
 * merge, and decision D2's cross-thread refusal.
 *
 * THE THREAD CHECK IS THE ONE THAT NEEDS A REAL THREAD. D2 says a context touched from a foreign thread without the
 * lock raises `NSManagedObjectContextLockingError` rather than corrupting its sets — and a claim like that is only
 * measured by actually making the call from another thread and catching what comes back.
 */

#import <CoreData/CoreData.h>
#import <Foundation/NSAutoreleasePool.h>
#include <pthread.h>
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

static int changeNotifications = 0;

@interface Watcher : NSObject
@end

@implementation Watcher
- (void)changed:(NSNotification *)note { (void)note; changeNotifications++; }
@end

static NSAttributeDescription *Attr(NSString *name, NSAttributeType type)
{
	NSAttributeDescription *a = [[[NSAttributeDescription alloc] init] autorelease];
	[a setName:name];
	[a setAttributeType:type];
	[a setOptional:YES];
	return a;
}

static NSRelationshipDescription *Rel(NSString *name, NSUInteger maxCount, NSDeleteRule rule)
{
	NSRelationshipDescription *r = [[[NSRelationshipDescription alloc] init] autorelease];
	[r setName:name];
	[r setMaxCount:maxCount];
	[r setDeleteRule:rule];
	return r;
}

/* Person.department -> Department.staff (to-many, CASCADE)
 * Department.head    -> Person.headOf      (to-one,  NULLIFY) */
static NSManagedObjectModel *BuildModel(void)
{
	NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
	NSEntityDescription *person = [[[NSEntityDescription alloc] init] autorelease];
	NSEntityDescription *dept = [[[NSEntityDescription alloc] init] autorelease];
	NSRelationshipDescription *department = Rel(@"department", 1, NSNullifyDeleteRule);
	NSRelationshipDescription *staff = Rel(@"staff", 0, NSCascadeDeleteRule);
	NSRelationshipDescription *head = Rel(@"head", 1, NSNullifyDeleteRule);
	NSRelationshipDescription *headOf = Rel(@"headOf", 1, NSNullifyDeleteRule);

	[person setName:@"Person"];
	[dept setName:@"Department"];

	[department setDestinationEntity:dept];
	[department setInverseRelationship:staff];
	[staff setDestinationEntity:person];
	[head setDestinationEntity:person];
	[head setInverseRelationship:headOf];
	[headOf setDestinationEntity:dept];

	[person setProperties:[NSArray arrayWithObjects:Attr(@"name", NSStringAttributeType),
	                                                Attr(@"age", NSInteger32AttributeType),
	                                                department, headOf, nil]];
	[dept setProperties:[NSArray arrayWithObjects:Attr(@"name", NSStringAttributeType),
	                                              staff, head, nil]];
	[model setEntities:[NSArray arrayWithObjects:person, dept, nil]];
	return model;
}

/* ---- D2: a foreign thread ---- */

static int foreignRaised = 0;
static int foreignLockedWorked = 0;
static NSManagedObjectContext *foreignContext = nil;

static void *TouchWithoutLock(void *arg)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	@try {
		(void)[(NSManagedObjectContext *)arg registeredObjects];
		foreignRaised = 0;
	} @catch (NSException *e) {
		foreignRaised = 1;
	}
	[pool release];
	return NULL;
}

static void *TouchWithLock(void *arg)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSManagedObjectContext *ctx = (NSManagedObjectContext *)arg;
	@try {
		[ctx lock];
		(void)[ctx registeredObjects];
		[ctx unlock];
		foreignLockedWorked = 1;
	} @catch (NSException *e) {
		foreignLockedWorked = 0;
	}
	[pool release];
	return NULL;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSManagedObjectModel *model = BuildModel();
	NSEntityDescription *personEntity = [[model entitiesByName] objectForKey:@"Person"];
	NSEntityDescription *deptEntity = [[model entitiesByName] objectForKey:@"Department"];
	NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] init];
	Watcher *watcher = [[Watcher alloc] init];
	NSError *error = nil;

	[[NSNotificationCenter defaultCenter] addObserver:watcher
	                                         selector:@selector(changed:)
	                                             name:NSManagedObjectContextObjectsDidChangeNotification
	                                           object:ctx];

	/* 1. an empty context */
	CHECK([[ctx registeredObjects] count] == 0, "a new context has nothing registered");
	CHECK([ctx hasChanges] == NO, "and no changes");
	CHECK([ctx propagatesDeletesAtEndOfEvent] == YES, "deletes propagate at end of event by default");
	CHECK([ctx mergePolicy] == NSErrorMergePolicy, "the default merge policy refuses conflicts");

	/* 2. inserting, and the pending/published split */
	{
		NSManagedObject *person = [[NSManagedObject alloc] initWithEntity:personEntity
		                                  insertIntoManagedObjectContext:ctx];

		CHECK([person isInserted] == YES, "an object created into a context is inserted");
		CHECK([person managedObjectContext] == ctx, "and knows its context");
		CHECK([ctx hasChanges] == YES, "which makes the context dirty");
		CHECK([[ctx registeredObjects] count] == 1, "the object is registered");

		changeNotifications = 0;
		[person setValue:@"alice" forKey:@"name"];
		[person setValue:[NSNumber numberWithInt:40] forKey:@"age"];
		[ctx processPendingChanges];
		CHECK(changeNotifications == 1, "one ObjectsDidChange per processing, not per setter");
		CHECK([[ctx insertedObjects] count] == 1, "and the object is in the inserted set");

		/* 3. save adopts the diff */
		CHECK([ctx save:&error] == YES, "an in-memory save succeeds");
		CHECK([ctx hasChanges] == NO, "the context is clean afterwards");
		CHECK([[ctx insertedObjects] count] == 0, "and the inserted set is empty");
		CHECK([person isInserted] == NO, "the object is no longer inserted");
		CHECK([[person valueForKey:@"name"] isEqual:@"alice"], "the values are still there");

		/* 4. undo and redo, registered before the change */
		[person setValue:@"bob" forKey:@"name"];
		CHECK([[person valueForKey:@"name"] isEqual:@"bob"], "the new value is written");
		[ctx undo];
		CHECK([[person valueForKey:@"name"] isEqual:@"alice"], "undo restores the replaced value");
		[ctx redo];
		CHECK([[person valueForKey:@"name"] isEqual:@"bob"], "redo re-applies it");

		/* 5. rollback throws the diff away instead of replaying it */
		[person setValue:@"carol" forKey:@"name"];
		[ctx rollback];
		CHECK([[person valueForKey:@"name"] isEqual:@"alice"], "rollback restores the committed value");
		CHECK([ctx hasChanges] == NO, "and leaves nothing pending");

		/* 6. refreshing: with merge it keeps identity, without it becomes a fault */
		[ctx refreshObject:person mergeChanges:YES];
		CHECK([person isFault] == NO, "mergeChanges:YES keeps the object materialised");
		[ctx refreshObject:person mergeChanges:NO];
		CHECK([person isFault] == YES, "mergeChanges:NO turns it into a fault");

		[person release];
	}

	/* 7. delete propagation: CASCADE down staff, NULLIFY up the inverse */
	{
		NSManagedObject *dept = [[NSManagedObject alloc] initWithEntity:deptEntity
		                                insertIntoManagedObjectContext:ctx];
		NSManagedObject *employee = [[NSManagedObject alloc] initWithEntity:personEntity
		                                    insertIntoManagedObjectContext:ctx];

		[dept setValue:@"Engineering" forKey:@"name"];
		[employee setValue:@"dave" forKey:@"name"];
		/* BOTH SIDES ARE WRITTEN EXPLICITLY. Automatic inverse maintenance is not implemented yet: a to-many
		 * relationship needs the mutable collection a fetch installs, so setting one side does not update the
		 * other. The plan records this as the next wave's work rather than pretending the graph is symmetric. */
		[dept setValue:[NSSet setWithObject:employee] forKey:@"staff"];
		[employee setValue:dept forKey:@"department"];
		[dept setValue:employee forKey:@"head"];
		[employee setValue:dept forKey:@"headOf"];
		CHECK([ctx save:&error] == YES, "the department and its employee save");

		/* deleting a Person nullifies the Department that pointed at it, because Department.head's rule is on the
		 * relationship being traversed — Person.headOf — whose inverse is the to-one Department.head. */
		[ctx deleteObject:employee];
		[ctx processPendingChanges];
		CHECK([dept valueForKey:@"head"] == nil, "the to-one inverse was nullified");

		/* and deleting the Department cascades to its staff */
		[dept setValue:[NSSet setWithObject:employee] forKey:@"staff"];
		[ctx save:&error];
		[ctx deleteObject:dept];
		[ctx processPendingChanges];
		CHECK([employee isDeleted] == YES, "CASCADE deleted the staff member");

		CHECK([ctx save:&error] == YES, "the deletions save");
		CHECK([[ctx registeredObjects] count] == 1, "the deleted objects leave the registry, the survivor stays");
		[dept release];
		[employee release];
	}

	/* 8. D2: a foreign thread without the lock is refused, and with it is allowed */
	{
		pthread_t thread;

		foreignContext = ctx;
		pthread_create(&thread, NULL, TouchWithoutLock, ctx);
		pthread_join(thread, NULL);
		CHECK(foreignRaised == 1, "a foreign thread without the lock gets an exception");

		pthread_create(&thread, NULL, TouchWithLock, ctx);
		pthread_join(thread, NULL);
		CHECK(foreignLockedWorked == 1, "and one that takes the lock first is allowed");
		CHECK([ctx tryLock] == YES, "tryLock takes an uncontended lock");
		[ctx unlock];
	}

	/* 9. merge: another context's save is folded in by IDENTITY, not by copying */
	{
		NSManagedObjectContext *other = [[[NSManagedObjectContext alloc] init] autorelease];
		NSManagedObject *theirs = [[[NSManagedObject alloc] initWithEntity:personEntity
		                                  insertIntoManagedObjectContext:other] autorelease];
		NSDictionary *info = [NSDictionary dictionaryWithObject:[NSSet setWithObject:theirs]
		                                                forKey:NSInsertedObjectsKey];
		NSNotification *note = [NSNotification notificationWithName:NSManagedObjectContextDidSaveNotification
		                                                    object:other
		                                                  userInfo:info];

		[theirs setValue:@"erin" forKey:@"name"];
		[other save:&error];
		[theirs setValue:@"frank" forKey:@"name"];
		[ctx mergeChangesFromContextDidSaveNotification:note];
		CHECK([ctx objectWithID:[theirs objectID]] != nil, "the merged object is registered by ID");
		CHECK([ctx objectWithID:[theirs objectID]] != theirs, "as a different object with the same identity");
	}

	/* 10. the doors that need a store refuse by name */
	{
		/* NSFetchRequest is W5's, so the request here is nil: the door refuses because there is no coordinator,
		 * which is the condition under test — the request's own contents cannot change that. */
		NSError *fetchError = nil;

		CHECK([ctx executeFetchRequest:nil error:&fetchError] == nil, "a fetch without a store returns nil");
		CHECK([[fetchError userInfo] objectForKey:@"reason"] != nil, "with an error that says why");
		CHECK([ctx obtainPermanentIDsForObjects:[NSArray array] error:NULL] == NO,
		      "and permanent IDs cannot be obtained");
	}

	/* 11. accessors and reset */
	[ctx setStalenessInterval:2.5];
	CHECK([ctx stalenessInterval] == 2.5, "stalenessInterval round-trips");
	[ctx setMergePolicy:NSOverwriteMergePolicy];
	CHECK([ctx mergePolicy] == NSOverwriteMergePolicy, "the merge policy is one of the five singletons");
	[ctx setRetainsRegisteredObjects:YES];
	CHECK([ctx retainsRegisteredObjects] == YES, "retainsRegisteredObjects round-trips");

	[ctx reset];
	CHECK([[ctx registeredObjects] count] == 0, "reset empties the registry");
	CHECK([ctx hasChanges] == NO, "and leaves no changes");

	[[NSNotificationCenter defaultCenter] removeObserver:watcher];
	[watcher release];
	[ctx release];
	printf("context: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
