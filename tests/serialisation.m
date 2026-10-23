/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * serialisation — W7's gate (COREDATA-PLAN.md §12, §7): the same object graph written to, and read back from, three
 * different files.
 *
 * THE TEST IS ONE LOOP OVER THE STORE TYPES, ON PURPOSE. §7.3 claims that a store is a serialisation format over the
 * node cache W4 wrote, and the only way to test a claim like that is to run the SAME fixture through all of them: if
 * a store needed different application code to make it work, the claim would be false and this suite would show it
 * by having to special-case one.
 *
 * THE INCOMPATIBLE-MODEL CASE IS D1-b's REFUSAL MADE REAL: a store written by one model must fail to open under a
 * model whose version hashes differ, with `NSPersistentStoreIncompatibleVersionHashError` — by name, not by
 * half-reading the file.
 */

#import <CoreData/CoreData.h>
#import <Foundation/NSAutoreleasePool.h>
#include <stdio.h>
#include <unistd.h>

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

static NSManagedObjectModel *Model(BOOL withExtra)
{
	NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
	NSEntityDescription *person = [[[NSEntityDescription alloc] init] autorelease];
	NSMutableArray *properties = [NSMutableArray array];

	[properties addObject:Attr(@"name", NSStringAttributeType)];
	[properties addObject:Attr(@"age", NSInteger32AttributeType)];
	[properties addObject:Attr(@"score", NSDoubleAttributeType)];
	if (withExtra) {
		[properties addObject:Attr(@"extra", NSStringAttributeType)];
	}
	[person setName:@"Person"];

	{
		/* A TO-ONE AND ITS TO-MANY INVERSE, because a store that persists attributes and drops relationships would
		 * pass every other check in this file. */
		NSEntityDescription *department = [[[NSEntityDescription alloc] init] autorelease];
		NSRelationshipDescription *staff = [[[NSRelationshipDescription alloc] init] autorelease];
		NSRelationshipDescription *belongs = [[[NSRelationshipDescription alloc] init] autorelease];

		[staff setName:@"staff"];
		[staff setMaxCount:0];
		[staff setDestinationEntity:person];
		[belongs setName:@"department"];
		[belongs setDestinationEntity:department];
		[belongs setInverseRelationship:staff];
		[properties addObject:belongs];

		[department setName:@"Department"];
		[department setProperties:[NSArray arrayWithObjects:Attr(@"title", NSStringAttributeType), staff, nil]];
		/* THE PERSON'S PROPERTIES ARE INSTALLED AFTER THE RELATIONSHIP EXISTS, because `-setProperties:` COPIES the
		 * array: adding to it afterwards was the first version of this fixture and it produced an object that could
		 * not be sent `department`. */
		[person setProperties:properties];
		[model setEntities:[NSArray arrayWithObjects:person, department, nil]];
	}
	return model;
}

/* One store type, end to end: write three rows, open a fresh stack on the same file, read them back. */
static void Exercise(NSString *storeType, NSString *path)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSManagedObjectModel *model = Model(NO);
	NSEntityDescription *personEntity = [[model entitiesByName] objectForKey:@"Person"];
	NSURL *url = [NSURL fileURLWithPath:path];
	NSError *error = nil;
	NSArray *names = [NSArray arrayWithObjects:@"alice", @"bob", @"carol", nil];
	int ages[3] = {40, 25, 33};
	NSUInteger i;

	unlink([path fileSystemRepresentation]);

	/* write */
	{
		NSPersistentStoreCoordinator *coordinator =
		    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
		NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] init];
		NSPersistentStore *store = [coordinator addPersistentStoreWithType:storeType
		                                                    configuration:nil URL:url
		                                                            options:nil error:&error];

		if (store == nil) {
			fprintf(stderr, "  [%s] open failed: %s\n", [storeType UTF8String],
			        [[error description] UTF8String]);
		}
		CHECK(store != nil, "the store opens for writing");
		[ctx setPersistentStoreCoordinator:coordinator];
		for (i = 0; i < 3; i++) {
			NSManagedObject *person = [[NSManagedObject alloc] initWithEntity:personEntity
			                                      insertIntoManagedObjectContext:ctx];
			[person setValue:[names objectAtIndex:i] forKey:@"name"];
			[person setValue:[NSNumber numberWithInt:ages[i]] forKey:@"age"];
			[person setValue:[NSNumber numberWithDouble:1.5] forKey:@"score"];
			[person release];
		}
		if (![ctx save:&error]) {
			fprintf(stderr, "  [%s] save failed: %s\n", [storeType UTF8String],
			        [[error description] UTF8String]);
		}
		{
			NSEntityDescription *departmentEntity = [[model entitiesByName] objectForKey:@"Department"];
			NSManagedObject *engineering = [[NSManagedObject alloc] initWithEntity:departmentEntity
			                                           insertIntoManagedObjectContext:ctx];
			NSArray *everyone = [[ctx registeredObjects] allObjects];
			NSUInteger p;

			[engineering setValue:@"Engineering" forKey:@"title"];
			/* SETTING THE TO-ONE IS ENOUGH: the inverse is maintained by the object graph, which is the point of
			 * this check — the store only ever sees the result. */
			for (p = 0; p < [everyone count]; p++) {
				NSManagedObject *member = [everyone objectAtIndex:p];
				if ([[member entity] isKindOfClass:[NSEntityDescription class]] &&
				    [[[member entity] name] isEqual:@"Person"]) {
					[member setValue:engineering forKey:@"department"];
				}
			}
			CHECK([[engineering valueForKey:@"staff"] count] == 3,
			      "the inverse to-many was filled by setting each to-one");
			[engineering release];
		}
		CHECK([ctx save:&error] == YES, "three rows and a department save");
		[ctx release];
		[coordinator release];
	}

	/* the file exists, and its metadata can be read WITHOUT a stack */
	{
		NSDictionary *metadata = [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:storeType
		                                                                                     URL:url
		                                                                                   error:&error];
		CHECK(metadata != nil, "the metadata is readable without opening a stack");
		CHECK([metadata objectForKey:NSStoreUUIDKey] != nil, "and carries the store's UUID");
		CHECK([metadata objectForKey:NSStoreModelVersionHashesKey] != nil, "and the model's version hashes");
	}

	/* read it back through a fresh coordinator */
	{
		NSPersistentStoreCoordinator *coordinator =
		    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
		NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] init];
		NSFetchRequest *request = [[NSFetchRequest alloc] init];
		NSArray *found;

		CHECK([coordinator addPersistentStoreWithType:storeType configuration:nil URL:url
		                               options:nil error:&error] != nil,
		      "a fresh stack opens the store it just wrote");
		[ctx setPersistentStoreCoordinator:coordinator];
		[request setEntity:personEntity];
		[request setSortDescriptors:[NSArray arrayWithObject:
		    [NSSortDescriptor sortDescriptorWithKey:@"age" ascending:YES]]];
		found = [ctx executeFetchRequest:request error:&error];
		if ([found count] != 3) {
			fprintf(stderr, "  [%s] fetched %lu rows\n", [storeType UTF8String],
			        (unsigned long)[found count]);
		}
		CHECK([found count] == 3, "and reads the three rows back");
		if ([found count] == 3) {
			CHECK([[[found objectAtIndex:0] valueForKey:@"name"] isEqual:@"bob"], "the youngest is bob");
			CHECK([[[found objectAtIndex:1] valueForKey:@"age"] intValue] == 33, "then carol at 33");
			CHECK([[[found objectAtIndex:2] valueForKey:@"score"] doubleValue] == 1.5,
			      "a double survived the round trip");
			/* THE RELATIONSHIP: the stored reference is resolved into an object when the fault fires, and reading
			 * THROUGH it fires a second fault — two hops, both from the file. */
			{
				NSManagedObject *department = [[found objectAtIndex:1] valueForKey:@"department"];

				CHECK(department != nil, "the to-one came back as an object, not as a stored string");
				CHECK([[[department valueForKey:@"title"] description] isEqual:@"Engineering"],
				      "and reading through it gets the related row's value");
			}
		}
		/* AND THE OTHER DIRECTION: the to-many side names all three rows */
		{
			NSFetchRequest *departments = [[NSFetchRequest alloc] init];
			NSArray *foundDepartments;

			[departments setEntity:[[model entitiesByName] objectForKey:@"Department"]];
			foundDepartments = [ctx executeFetchRequest:departments error:&error];
			CHECK([foundDepartments count] == 1, "the department was stored");
			if ([foundDepartments count] == 1) {
				CHECK([[[foundDepartments objectAtIndex:0] valueForKey:@"staff"] count] == 3,
				      "and its to-many resolved all three members");
			}
			[departments release];
		}
		[request release];
		[ctx release];
		[coordinator release];
	}

	/* D1-b's refusal: the same file under a model whose hashes differ */
	{
		NSManagedObjectModel *changed = Model(YES);
		NSPersistentStoreCoordinator *coordinator =
		    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:changed];
		NSError *refusal = nil;

		CHECK([coordinator addPersistentStoreWithType:storeType configuration:nil URL:url
		                               options:nil error:&refusal] == nil,
		      "a store written by another model is refused");
		if ([refusal code] != NSPersistentStoreIncompatibleVersionHashError) {
			fprintf(stderr, "  [%s] refusal code %ld: %s\n", [storeType UTF8String], (long)[refusal code],
			        [[refusal description] UTF8String]);
		}
		CHECK([refusal code] == NSPersistentStoreIncompatibleVersionHashError,
		      "with the version-hash code (D1-b)");
		[coordinator release];
	}
	[pool release];
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];

	Exercise(NSBinaryStoreType, @"/tmp/libagora-data-test.store");
	Exercise(NSXMLStoreType, @"/tmp/libagora-data-test.xmlstore");
	Exercise(NSSQLiteStoreType, @"/tmp/libagora-data-test.sqlite");

	/* THE SCHEMA IS THE ONE THE DOCUMENT DESCRIBES, CHECKED BY A STANDARD SQLITE CLIENT — which is D1-b's whole
	 * promise: a developer can open the file and read the data.
	 *
	 * THE CHECK IS NOW A SCRIPT RATHER THAN A ONE-LINER, because it grew a second question: not just that the tables
	 * are there and the rows are typed, but that a to-many relationship is legible as an `array` row. And when
	 * python3 is absent the check SKIPS LOUDLY: an earlier version shelled out to a binary this machine does not
	 * have, and passed by doing nothing. */
	if (system("command -v python3 > /dev/null 2>&1") == 0) {
		FILE *script = fopen("/tmp/libagora-data-schema-check.py", "w");

		if (script != NULL) {
			fputs("import sqlite3, sys\n"
			      "db = sqlite3.connect('/tmp/libagora-data-test.sqlite')\n"
			      "tables = {r[0] for r in db.execute(\"SELECT name FROM sqlite_master WHERE type='table'\")}\n"
			      "types = {r[0] for r in db.execute('SELECT DISTINCT type FROM agora_value')}\n"
			      "rows = db.execute('SELECT COUNT(*) FROM agora_value').fetchone()[0]\n"
			      "want = {'agora_entity', 'agora_metadata', 'agora_object', 'agora_value'}\n"
			      "ok = want <= tables and {'integer', 'real', 'string', 'array'} <= types and rows >= 14\n"
			      "sys.exit(0 if ok else 1)\n", script);
			fclose(script);
			CHECK(system("python3 /tmp/libagora-data-schema-check.py > /dev/null 2>&1") == 0,
			      "a standard client reads the tables, the typed values and a relationship's array row");
		}
	} else {
		fprintf(stderr, "  (no python3: the SQLite readability check was SKIPPED, not passed)\n");
	}

	printf("serialisation: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
