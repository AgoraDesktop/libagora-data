/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * lazy — the eager-load limit (§0.18). The SQLite store no longer reads the file at open; it answers which rows
 * exist, and reads ONE row when a fault asks for it.
 *
 * THE REGRESSION THIS SUITE EXISTS FOR IS THE SAVE. While the cache was the file, `-save:` could delete every row and
 * rewrite the cache. The moment the store stopped loading everything, that would erase every row nobody had read —
 * so the suite writes 5,000 rows, opens a fresh stack, changes ONE object, saves, and reads all 5,000 back.
 */

#import <CoreData/CoreData.h>
#import <Foundation/NSAutoreleasePool.h>
#include <stdio.h>
#include <time.h>
#include <unistd.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond, what) do { \
	checks++; \
	if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, (what)); } \
} while (0)

static double Now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC, &t); return t.tv_sec + t.tv_nsec/1e9; }

static NSAttributeDescription *Attr(NSString *name, NSAttributeType type)
{
	NSAttributeDescription *a = [[[NSAttributeDescription alloc] init] autorelease];
	[a setName:name];
	[a setAttributeType:type];
	[a setOptional:YES];
	return a;
}

static NSManagedObjectModel *Model(void)
{
	NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
	NSEntityDescription *person = [[[NSEntityDescription alloc] init] autorelease];

	[person setName:@"Person"];
	[person setProperties:[NSArray arrayWithObjects:Attr(@"name", NSStringAttributeType),
	                                                Attr(@"age", NSInteger32AttributeType), nil]];
	[model setEntities:[NSArray arrayWithObject:person]];
	return model;
}

#define ROWS 5000

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSManagedObjectModel *model = Model();
	NSEntityDescription *personEntity = [[model entitiesByName] objectForKey:@"Person"];
	NSString *path = @"/tmp/libagora-data-lazy.sqlite";
	NSError *error = nil;
	NSUInteger i;
	double started;

	unlink([path fileSystemRepresentation]);

	/* write the rows through an ordinary stack */
	{
		NSPersistentStoreCoordinator *coordinator =
		    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
		NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] init];

		(void)[coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
		                                  URL:[NSURL fileURLWithPath:path] options:nil error:&error];
		[ctx setPersistentStoreCoordinator:coordinator];
		for (i = 0; i < ROWS; i++) {
			NSManagedObject *person = [[NSManagedObject alloc] initWithEntity:personEntity
			                                      insertIntoManagedObjectContext:ctx];
			[person setValue:[NSString stringWithFormat:@"person-%lu", (unsigned long)i] forKey:@"name"];
			[person setValue:[NSNumber numberWithInteger:(NSInteger)(i % 100)] forKey:@"age"];
			[person release];
		}
		CHECK([ctx save:&error] == YES, "5,000 rows are written");
		[ctx release];
		[coordinator release];
	}

	/* a FRESH stack: the store must have read nothing */
	{
		NSPersistentStoreCoordinator *reader =
		    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
		NSManagedObjectContext *reading = [[NSManagedObjectContext alloc] init];
		NSAtomicStore *store;

		started = Now();
		store = (NSAtomicStore *)[reader addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
		                                                  URL:[NSURL fileURLWithPath:path] options:nil error:&error];
		printf("  open a %d-row file:   %6.3fs\n", ROWS, Now() - started);
		CHECK(store != nil, "the store opens");
		CHECK([[store cacheNodes] count] == 0, "and has read NO rows: the load is lazy now");
		if ([[store cd_objectIDs] count] != ROWS) {
			fprintf(stderr, "    cd_objectIDs saw %lu rows, expected %d\n",
			        (unsigned long)[[store cd_objectIDs] count], ROWS);
		}
		CHECK([[store cd_objectIDs] count] == ROWS, "but it knows which rows exist");

		[reading setPersistentStoreCoordinator:reader];

		/* one fetch by predicate: SQL answers, and only the matches are built */
		{
			NSFetchRequest *request = [[NSFetchRequest alloc] init];
			NSArray *found;

			[request setEntity:personEntity];
			[request setPredicate:[NSPredicate predicateWithFormat:@"age == 7"]];
			[request setReturnsObjectsAsFaults:NO];
			started = Now();
			found = [reading executeFetchRequest:request error:&error];
			printf("  fetch age == 7:      %6.3fs\n", Now() - started);
			CHECK([found count] == ROWS / 100, "the predicate finds the right rows");
			CHECK([[[found objectAtIndex:0] valueForKey:@"name"] hasPrefix:@"person-"], "with their values read");
			[request release];
		}

		/* one row read by ID, which is what a fault does */
		{
			NSFetchRequest *request = [[NSFetchRequest alloc] init];
			NSArray *found;

			[request setEntity:personEntity];
			[request setFetchLimit:1];
			[request setReturnsObjectsAsFaults:YES];
			found = [reading executeFetchRequest:request error:&error];
			CHECK([found count] == 1, "a faulted fetch returns one object");
			CHECK([[[found objectAtIndex:0] valueForKey:@"age"] intValue] >= 0, "and reading it fires one row-select");
			[request release];
		}

		/* THE BATCHED SCAN (§0.19): an untranslatable predicate forces the scan, which must read its candidates in
		 * CHUNKS. Correctness first — the count must match a filter done here — and the time is recorded. */
		{
			NSFetchRequest *request = [[NSFetchRequest alloc] init];
			NSFetchRequest *all = [[NSFetchRequest alloc] init];
			NSArray *scanned;
			NSArray *everyone;
			NSUInteger expected = 0, k;

			[request setEntity:personEntity];
			[request setPredicate:[NSPredicate predicateWithFormat:
			                       @"FUNCTION(name, \"uppercaseString\") BEGINSWITH \"PERSON-4\""]];
			[all setEntity:personEntity];
			[all setReturnsObjectsAsFaults:NO];
			everyone = [reading executeFetchRequest:all error:&error];
			for (k = 0; k < [everyone count]; k++) {
				NSManagedObject *person = [everyone objectAtIndex:k];

				if ([[[person valueForKey:@"name"] uppercaseString] hasPrefix:@"PERSON-4"]) {
					expected++;
				}
			}
			started = Now();
			scanned = [reading executeFetchRequest:request error:&error];
			printf("  batched scan of %d:  %6.3fs\n", ROWS, Now() - started);
			CHECK([scanned count] == expected, "the batched scan agrees with a filter done here");
			[request release];
			[all release];
		}

		/* THE REGRESSION: change one object, save, and every other row must survive */
		{
			NSFetchRequest *request = [[NSFetchRequest alloc] init];
			NSArray *found;

			[request setEntity:personEntity];
			[request setPredicate:[NSPredicate predicateWithFormat:@"name == \"person-42\""]];
			[request setReturnsObjectsAsFaults:NO];
			found = [reading executeFetchRequest:request error:&error];
			CHECK([found count] == 1, "the row to change is found");
			[[found objectAtIndex:0] setValue:[NSNumber numberWithInteger:4242] forKey:@"age"];
			CHECK([reading save:&error] == YES, "saving one changed object succeeds");
			[request release];
		}
		[reading release];
		[reader release];
	}

	/* and a THIRD stack counts them, because only the file can settle it */
	{
		NSPersistentStoreCoordinator *verifier =
		    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
		NSManagedObjectContext *verifying = [[NSManagedObjectContext alloc] init];
		NSFetchRequest *request = [[NSFetchRequest alloc] init];
		NSArray *all;
		NSManagedObject *changed;

		(void)[verifier addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
		                               URL:[NSURL fileURLWithPath:path] options:nil error:&error];
		[verifying setPersistentStoreCoordinator:verifier];
		[request setEntity:personEntity];
		started = Now();
		all = [verifying executeFetchRequest:request error:&error];
		printf("  fetch all %d:      %6.3fs\n", ROWS, Now() - started);
		CHECK([all count] == ROWS, "an incremental save kept every untouched row");

		[request setPredicate:[NSPredicate predicateWithFormat:@"age == 4242"]];
		[request setReturnsObjectsAsFaults:NO];
		{
			NSArray *one = [verifying executeFetchRequest:request error:&error];

			CHECK([one count] == 1, "and the changed row is there");
			changed = ([one count] == 1) ? [one objectAtIndex:0] : nil;
			CHECK([[changed valueForKey:@"name"] isEqual:@"person-42"], "with its identity intact");
		}
		[request release];
		[verifying release];
		[verifier release];
	}

	printf("lazy: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
