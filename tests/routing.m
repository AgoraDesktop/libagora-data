/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * routing — the two doors the census scored and nothing used (COREDATA-PLAN.md §7.5, and §0.11).
 *
 * `-assignObject:toPersistentStore:` RECORDED AN ASSIGNMENT THAT NOTHING READ, and `-addPersistentStoreWithType:
 * configuration:` stored a name that nothing consulted: every save went to `_stores[0]` and every fetch read the
 * first store's nodes. Both looked implemented because they are declared, implemented, and never asked. This suite
 * asks them.
 *
 * THE FOUR RULES ARE TESTED IN ORDER, because their PRECEDENCE is the whole contract: an explicit assignment wins;
 * an object that already lives in a store stays there; otherwise the configuration decides; and an entity that no
 * store's configuration names is an ERROR rather than a quiet write to the wrong file.
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

static NSAttributeDescription *Attr(NSString *name)
{
	NSAttributeDescription *a = [[[NSAttributeDescription alloc] init] autorelease];
	[a setName:name];
	[a setAttributeType:NSStringAttributeType];
	[a setOptional:YES];
	return a;
}

static NSEntityDescription *Entity(NSString *name)
{
	NSEntityDescription *e = [[[NSEntityDescription alloc] init] autorelease];
	[e setName:name];
	[e setProperties:[NSArray arrayWithObject:Attr(@"text")]];
	return e;
}

/* `Orphan` IS IN NO CONFIGURATION, which is what makes rule four reachable. */
static NSManagedObjectModel *Model(void)
{
	NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
	NSEntityDescription *person = Entity(@"Person");
	NSEntityDescription *note = Entity(@"Note");
	NSEntityDescription *orphan = Entity(@"Orphan");

	[model setEntities:[NSArray arrayWithObjects:person, note, orphan, nil]];
	[model setEntities:[NSArray arrayWithObject:person] forConfiguration:@"People"];
	[model setEntities:[NSArray arrayWithObject:note] forConfiguration:@"Notes"];
	return model;
}

static NSManagedObject *Insert(NSManagedObjectContext *ctx, NSEntityDescription *entity, NSString *text)
{
	NSManagedObject *o = [[[NSManagedObject alloc] initWithEntity:entity
	                                     insertIntoManagedObjectContext:ctx] autorelease];
	[o setValue:text forKey:@"text"];
	return o;
}

static NSUInteger NodesFor(NSAtomicStore *store, NSString *entityName)
{
	NSArray *nodes = [[store cacheNodes] allObjects];
	NSUInteger i, count = 0;

	for (i = 0; i < [nodes count]; i++) {
		NSManagedObjectID *objectID = [[nodes objectAtIndex:i] objectID];

		if ([[[objectID entity] name] isEqual:entityName]) { count++; }
	}
	return count;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSManagedObjectModel *model = Model();
	NSEntityDescription *personEntity = [[model entitiesByName] objectForKey:@"Person"];
	NSEntityDescription *noteEntity = [[model entitiesByName] objectForKey:@"Note"];
	NSPersistentStoreCoordinator *coordinator =
	    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
	NSAtomicStore *peopleStore;
	NSAtomicStore *notesStore;
	NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] init];
	NSError *error = nil;

	peopleStore = (NSAtomicStore *)[coordinator addPersistentStoreWithType:NSInMemoryStoreType
	                                                       configuration:@"People"
	                                                                 URL:nil options:nil error:&error];
	notesStore = (NSAtomicStore *)[coordinator addPersistentStoreWithType:NSInMemoryStoreType
	                                                      configuration:@"Notes"
	                                                                URL:nil options:nil error:&error];
	CHECK(peopleStore != nil && notesStore != nil, "two stores open, one per configuration");
	[ctx setPersistentStoreCoordinator:coordinator];

	/* 1. THE CONFIGURATION DECIDES */
	{
		NSManagedObject *person = Insert(ctx, personEntity, @"alice");
		NSManagedObject *note = Insert(ctx, noteEntity, @"remember");
		NSManagedObjectID *personID;
		NSManagedObjectID *noteID;

		CHECK([ctx save:&error] == YES, "a Person and a Note save through one context");
		CHECK(NodesFor(peopleStore, @"Person") == 1, "the Person reached the People store");
		CHECK(NodesFor(peopleStore, @"Note") == 0, "and not the Note");
		CHECK(NodesFor(notesStore, @"Note") == 1, "the Note reached the Notes store");
		CHECK(NodesFor(notesStore, @"Person") == 0, "and not the Person");

		personID = [person objectID];
		noteID = [note objectID];
		CHECK([personID persistentStore] == (id)peopleStore, "the Person's ID names the People store");
		CHECK([noteID persistentStore] == (id)notesStore, "the Note's ID names the Notes store");

		/* 2. AN EXPLICIT ASSIGNMENT WINS, even against the configuration */
		{
			NSManagedObject *second = Insert(ctx, personEntity, @"bob");

			[ctx assignObject:second toPersistentStore:(NSPersistentStore *)notesStore];
			CHECK([ctx save:&error] == YES, "a Person assigned to the Notes store saves");
			CHECK(NodesFor(notesStore, @"Person") == 1, "and lands there, not in its configuration's store");
			CHECK(NodesFor(peopleStore, @"Person") == 1, "leaving the People store unchanged");

			/* 3. AND `nil` CLEARS THE ASSIGNMENT, so the next save obeys the configuration again */
			[ctx assignObject:second toPersistentStore:nil];
			[second setValue:@"bob again" forKey:@"text"];
			CHECK([ctx save:&error] == YES, "clearing the assignment saves");
			CHECK(NodesFor(notesStore, @"Person") == 1 && NodesFor(peopleStore, @"Person") == 1,
			      "and an object that already lives in a store stays there (rule two)");
		}

		/* 4. A FETCH SEES EVERY STORE, and `affectedStores` scopes it */
		{
			NSFetchRequest *request = [[NSFetchRequest alloc] init];
			NSArray *all;
			NSArray *scoped;

			[request setEntity:personEntity];
			all = [ctx executeFetchRequest:request error:&error];
			CHECK([all count] == 2, "a fetch with no scope reads both stores");

			[request setAffectedStores:[NSArray arrayWithObject:(NSPersistentStore *)peopleStore]];
			scoped = [ctx executeFetchRequest:request error:&error];
			CHECK([scoped count] == 1, "and a scoped fetch reads only the store it names");
			[request setAffectedStores:nil];

			[request setEntity:noteEntity];
			CHECK([[ctx executeFetchRequest:request error:&error] count] == 1, "the Note is where it was put");
			[request release];
		}

		/* 5. A FAULT COMES FROM THE STORE THE ID NAMES — not from the first one */
		{
			NSManagedObjectContext *other = [[NSManagedObjectContext alloc] init];
			NSFetchRequest *request = [[NSFetchRequest alloc] init];
			NSArray *found;
			NSManagedObject *fault;

			[other setPersistentStoreCoordinator:coordinator];
			[request setEntity:personEntity];
			[request setPredicate:[NSPredicate predicateWithFormat:@"text BEGINSWITH \"bob\""]];
			found = [other executeFetchRequest:request error:&error];
			CHECK([found count] == 1, "the second context finds the Person that lives in the second store");
			fault = [other objectWithID:[[found objectAtIndex:0] objectID]];
			CHECK([fault isFault] == YES, "which arrives as a fault");
			CHECK([[fault valueForKey:@"text"] isEqual:@"bob again"], "and fires from the right store");
			[request release];
			[other release];
		}
	}

	/* 6. AN ENTITY NO CONFIGURATION NAMES IS AN ERROR, not a write to the first store */
	{
		NSManagedObjectContext *own = [[NSManagedObjectContext alloc] init];
		NSError *refusal = nil;

		[own setPersistentStoreCoordinator:coordinator];
		(void)Insert(own, [[model entitiesByName] objectForKey:@"Orphan"], @"nowhere");
		CHECK([own save:&refusal] == NO, "an entity no store is configured for refuses to save");
		CHECK([refusal code] == NSPersistentStoreOperationError, "with the operation error");
		CHECK([[refusal userInfo] objectForKey:@"reason"] != nil, "naming the entity in its reason");
		[own release];
	}

	/* 7. A CONFIGURATION ALSO FILTERS ON LOAD: one file, two halves of the model */
	{
		NSString *path = @"/tmp/libagora-data-routing.store";
		unlink([path fileSystemRepresentation]);
		{
			NSPersistentStoreCoordinator *writer =
			    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
			NSManagedObjectContext *writing = [[NSManagedObjectContext alloc] init];

			(void)[writer addPersistentStoreWithType:NSBinaryStoreType configuration:nil
			                                URL:[NSURL fileURLWithPath:path] options:nil error:&error];
			[writing setPersistentStoreCoordinator:writer];
			(void)Insert(writing, personEntity, @"carol");
			(void)Insert(writing, noteEntity, @"kept");
			CHECK([writing save:&error] == YES, "both entities are written to one unconfigured file");
			[writing release];
			[writer release];
		}
		{
			NSPersistentStoreCoordinator *reader =
			    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
			NSManagedObjectContext *reading = [[NSManagedObjectContext alloc] init];
			NSFetchRequest *request = [[NSFetchRequest alloc] init];

			CHECK([reader addPersistentStoreWithType:NSBinaryStoreType configuration:@"People"
			                               URL:[NSURL fileURLWithPath:path] options:nil error:&error] != nil,
			      "the file reopens under the People configuration");
			[reading setPersistentStoreCoordinator:reader];
			[request setEntity:personEntity];
			CHECK([[reading executeFetchRequest:request error:&error] count] == 1,
			      "the Person in its half is visible");
			[request setEntity:noteEntity];
			CHECK([[reading executeFetchRequest:request error:&error] count] == 0,
			      "and the Note outside it is not");
			[request release];
			[reading release];
			[reader release];
		}
	}

	[ctx release];
	[coordinator release];
	printf("routing: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
