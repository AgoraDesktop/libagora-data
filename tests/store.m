/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * store — W4's gate (COREDATA-PLAN.md §12): the store registry, the metadata, the save round trip, and the first
 * time in this plan that an object ID MEANS something.
 *
 * THE TWO-CONTEXT FAULT IS THE TEST THAT MATTERS. One context saves a row; a second context is handed only the
 * permanent ID, gets a fault, and fires it by reading a property. That is the whole object graph working at once —
 * identity, the node cache, the fault door and the snapshot — and nothing short of it proves the wave.
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

static NSAttributeDescription *Attr(NSString *name, NSAttributeType type)
{
	NSAttributeDescription *a = [[[NSAttributeDescription alloc] init] autorelease];
	[a setName:name];
	[a setAttributeType:type];
	[a setOptional:YES];
	return a;
}

static NSManagedObjectModel *BuildModel(void)
{
	NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
	NSEntityDescription *person = [[[NSEntityDescription alloc] init] autorelease];

	[person setName:@"Person"];
	[person setProperties:[NSArray arrayWithObjects:Attr(@"name", NSStringAttributeType),
	                                                Attr(@"age", NSInteger32AttributeType), nil]];
	[model setEntities:[NSArray arrayWithObject:person]];
	return model;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSManagedObjectModel *model = BuildModel();
	NSEntityDescription *personEntity = [[model entitiesByName] objectForKey:@"Person"];
	NSPersistentStoreCoordinator *coordinator =
	    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
	NSPersistentStore *store;
	NSError *error = nil;

	/* 1. the registry, and the three types that are not there yet */
	{
		NSDictionary *types = [NSPersistentStoreCoordinator registeredStoreTypes];
		CHECK([types objectForKey:NSInMemoryStoreType] != nil, "the in-memory store is registered");
		/* W7 REGISTERED THE OTHER THREE, so the invalid-type test needs a type that names nothing at all. */
		CHECK([types objectForKey:NSSQLiteStoreType] != nil, "SQLite is registered (W7)");
		CHECK([coordinator addPersistentStoreWithType:@"NoSuchStoreType"
		                               configuration:nil URL:nil options:nil error:&error] == nil,
		      "adding an unregistered store type returns nil");
		CHECK([error code] == NSPersistentStoreInvalidTypeError, "with the invalid-type code");
		CHECK([[error userInfo] objectForKey:@"reason"] != nil, "and a reason that names the wave");
	}

	/* 2. adding the in-memory store, and the metadata a new store gets */
	store = [coordinator addPersistentStoreWithType:NSInMemoryStoreType
	                                 configuration:nil URL:nil options:nil error:&error];
	CHECK(store != nil, "the in-memory store is added");
	CHECK([[store type] isEqual:NSInMemoryStoreType], "it knows its type");
	CHECK([[coordinator persistentStores] count] == 1, "the coordinator lists it");
	CHECK([[store metadata] objectForKey:NSStoreUUIDKey] != nil, "it has a UUID");
	CHECK([[store metadata] objectForKey:NSStoreModelVersionHashesKey] != nil, "and the model's version hashes");
	CHECK([store isReadOnly] == NO, "it is writable");
	CHECK([store identifier] != nil, "and it has an identifier for object paths");

	/* 3. a save turns a temporary ID into a permanent one */
	{
		NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] init];
		NSManagedObject *person;
		NSManagedObjectID *permanent;

		[ctx setPersistentStoreCoordinator:coordinator];
		person = [[NSManagedObject alloc] initWithEntity:personEntity insertIntoManagedObjectContext:ctx];
		CHECK([[person objectID] isTemporaryID] == YES, "before the save the ID is temporary");
		[person setValue:@"alice" forKey:@"name"];
		[person setValue:[NSNumber numberWithInt:41] forKey:@"age"];
		CHECK([ctx save:&error] == YES, "the save succeeds against a real store");
		CHECK([[person objectID] isTemporaryID] == NO, "after it the ID is permanent");
		CHECK([[person objectID] persistentStore] == store, "and names the store it lives in");
		CHECK([[[person objectID] primaryKey] intValue] == 1, "the first row keyed by 1");
		CHECK([person isInserted] == NO, "the object is no longer inserted");

		permanent = [[person objectID] retain];

		/* 4. THE TWO-CONTEXT FAULT: another context is given only the ID */
		{
			NSManagedObjectContext *other = [[NSManagedObjectContext alloc] init];
			NSManagedObject *fault;

			[other setPersistentStoreCoordinator:coordinator];
			fault = [other objectWithID:permanent];
			CHECK(fault != nil, "the ID resolves to an object in a context that never saw it");
			CHECK(fault != person, "which is a different instance with the same identity");
			CHECK([fault isFault] == YES, "and it arrives as a fault");
			CHECK([[fault valueForKey:@"name"] isEqual:@"alice"], "reading fires the fault and returns the row");
			CHECK([fault isFault] == NO, "leaving it materialised");
			CHECK([[fault valueForKey:@"age"] intValue] == 41, "and the rest of the row is there");
			[other release];
		}

		/* 5. the URI form round-trips through the coordinator */
		{
			NSURL *uri = [permanent URIRepresentation];
			NSManagedObjectID *parsed = [coordinator managedObjectIDForURIRepresentation:uri];

			CHECK(uri != nil, "the ID has a URI");
			CHECK(parsed != nil, "and the coordinator parses it back");
			CHECK([parsed isEqual:permanent], "to the same ID");
		}

		/* 6. obtaining a permanent ID WITHOUT saving */
		{
			NSManagedObject *early = [[NSManagedObject alloc] initWithEntity:personEntity
			                                        insertIntoManagedObjectContext:ctx];
			[early setValue:@"pre-keyed" forKey:@"name"];
			CHECK([[early objectID] isTemporaryID] == YES, "a new object starts temporary");
			CHECK([ctx obtainPermanentIDsForObjects:[NSArray arrayWithObject:early] error:&error] == YES,
			      "permanent IDs can be obtained before a save");
			CHECK([[early objectID] isTemporaryID] == NO, "and the ID is permanent afterwards");
			[ctx deleteObject:early];
			[early release];
		}

		/* 7. a deletion reaches the store */
		[ctx deleteObject:(NSManagedObject *)person];
		CHECK([ctx save:&error] == YES, "the deletion saves");
		{
			NSManagedObjectContext *other = [[NSManagedObjectContext alloc] init];
			NSManagedObject *gone;

			[other setPersistentStoreCoordinator:coordinator];
			gone = [other objectWithID:permanent];
			/* THE ROW IS GONE, SO THE FAULT HAS NOTHING TO INSTALL: the object survives as an empty fault rather
			 * than inventing values, which is what a store that was asked for a missing row can honestly do. */
			CHECK([gone valueForKey:@"name"] == nil, "a deleted row's fault carries no values");
			[other release];
		}

		[permanent release];
		[ctx release];
	}

	/* 8. the doors that belong to later waves refuse by name */
	CHECK([coordinator migratePersistentStore:store toURL:nil options:nil
	                                 withType:NSInMemoryStoreType error:&error] == nil,
	      "migration refuses");
	CHECK([[error userInfo] objectForKey:@"reason"] != nil, "naming W6");
	CHECK([NSPersistentStoreCoordinator elementsDerivedFromExternalRecordURL:nil] == nil,
	      "external records are refused (D4)");
	CHECK([NSPersistentStoreCoordinator metadataForPersistentStoreOfType:NSInMemoryStoreType
	                                                                 URL:nil error:NULL] == nil,
	      "a store with no file has no metadata to read");

	/* 9. locking and removal */
	CHECK([coordinator tryLock] == YES, "the coordinator locks");
	[coordinator unlock];
	CHECK([coordinator removePersistentStore:store error:&error] == YES, "the store is removed");
	CHECK([[coordinator persistentStores] count] == 0, "and the coordinator lists none");

	[coordinator release];
	printf("store: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
