/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * pushdown — §8's predicate-to-SQL translation, measured AGAINST THE SCAN IT REPLACES.
 *
 * THE TEST IS AN EQUIVALENCE, NOT A COUNT. Every predicate is asked twice: once through `-countForFetchRequest:`,
 * which asks SQLite, and once by fetching everything and counting in memory, which is the reference the whole engine
 * was before this slice. If the two disagree the translator is wrong, and no amount of speed makes that acceptable.
 *
 * AND AN UNTRANSLATABLE PREDICATE MUST STILL ANSWER: a quantifier or a FUNCTION falls back to the scan, and the test
 * checks that the fallback agrees too. §8.4's rule is that a refusal is named — here the "refusal" is the store
 * answering -1, and the context scanning instead.
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
	                                                Attr(@"age", NSInteger32AttributeType),
	                                                Attr(@"score", NSDoubleAttributeType), nil]];
	[model setEntities:[NSArray arrayWithObject:person]];
	return model;
}

/* Ask the SQL path and the scan path the same question, and hold them to the same answer. */
static void Agree(NSManagedObjectContext *ctx, NSEntityDescription *entity, NSPredicate *predicate,
                  const char *what)
{
	NSFetchRequest *request = [[NSFetchRequest alloc] init];
	NSUInteger bySQL;
	NSUInteger byScan;

	[request setEntity:entity];
	[request setPredicate:predicate];
	bySQL = [ctx countForFetchRequest:request error:NULL];
	byScan = [[ctx executeFetchRequest:request error:NULL] count];
	if (bySQL != byScan) {
		fprintf(stderr, "    [%s] sql=%lu scan=%lu  predicate=%s\n", what,
		        (unsigned long)bySQL, (unsigned long)byScan,
		        [[predicate description] UTF8String]);
	}
	CHECK(bySQL == byScan, what);
	[request release];
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSManagedObjectModel *model = Model();
	NSEntityDescription *personEntity = [[model entitiesByName] objectForKey:@"Person"];
	NSString *path = @"/tmp/libagora-data-pushdown.sqlite";
	NSPersistentStoreCoordinator *coordinator =
	    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
	NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] init];
	NSError *error = nil;
	NSUInteger i;
	double started;

	unlink([path fileSystemRepresentation]);
	(void)[coordinator addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
	                                  URL:[NSURL fileURLWithPath:path] options:nil error:&error];
	[ctx setPersistentStoreCoordinator:coordinator];

	for (i = 0; i < 5000; i++) {
		NSManagedObject *person = [[NSManagedObject alloc] initWithEntity:personEntity
		                                      insertIntoManagedObjectContext:ctx];

		[person setValue:[NSString stringWithFormat:@"person-%lu", (unsigned long)i] forKey:@"name"];
		[person setValue:[NSNumber numberWithInteger:(NSInteger)(i % 100)] forKey:@"age"];
		[person setValue:[NSNumber numberWithDouble:((double)i / 10.0)] forKey:@"score"];
		[person release];
	}
	CHECK([ctx save:&error] == YES, "5,000 rows save to SQLite");
	[ctx release];
	[coordinator release];

	/* a fresh stack, so the queries run against the FILE and not a warm cache */
	{
		NSPersistentStoreCoordinator *reader =
		    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
		NSManagedObjectContext *reading = [[NSManagedObjectContext alloc] init];
		NSUInteger expected;

		(void)[reader addPersistentStoreWithType:NSSQLiteStoreType configuration:nil
		                              URL:[NSURL fileURLWithPath:path] options:nil error:&error];
		[reading setPersistentStoreCoordinator:reader];

		/* 1. THE EQUIVALENCE, over the operators §8.2 lists */
		Agree(reading, personEntity, nil, "no predicate agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"age >= 50"], ">= agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"age < 10"], "< agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"age == 7"], "== agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"age != 7"], "!= agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"50 <= age"], "reversed operands agree");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"name BEGINSWITH \"person-1\""],
		      "BEGINSWITH agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"name ENDSWITH \"9\""], "ENDSWITH agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"name CONTAINS \"-49\""], "CONTAINS agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"name LIKE \"person-1%\""], "LIKE agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"age IN {1, 2, 3}"], "IN agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"age BETWEEN {20, 29}"], "BETWEEN agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"score > 100.5"], "a double agrees");
		Agree(reading, personEntity,
		      [NSPredicate predicateWithFormat:@"age >= 50 AND name BEGINSWITH \"person\""], "AND agrees");
		Agree(reading, personEntity,
		      [NSPredicate predicateWithFormat:@"age == 1 OR age == 2"], "OR agrees");
		Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"NOT (age < 90)"], "NOT agrees");

		/* 2. AND AN UNTRANSLATABLE PREDICATE STILL ANSWERS, through the scan */
		{
			NSPredicate *block = [NSPredicate predicateWithBlock:
			                      ^BOOL(id object, NSDictionary *bindings) {
				(void)bindings;
				return [[object valueForKey:@"age"] intValue] < 5;
			}];
			Agree(reading, personEntity, block, "a block predicate falls back to the scan and agrees");
			/* A COMPARISON BETWEEN TWO KEY PATHS: translatable only with a join per row, so the translator refuses
			 * and the scan answers. (`FUNCTION(...)` would be the natural example and is NOT in this tree's predicate
			 * grammar yet — the parser reads it as a function named `FUNCTION:` — which §0.15 records as a gap rather
			 * than hiding behind a test that avoids it.) */
			Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"age < score"],
			      "a key-path-to-key-path comparison falls back and agrees");
		}

		/* 3. THE REASON IT EXISTS: a count through SQL against a count through a scan */
		{
			NSFetchRequest *request = [[NSFetchRequest alloc] init];

			[request setEntity:personEntity];
			[request setPredicate:[NSPredicate predicateWithFormat:@"age >= 50"]];
			started = Now();
			expected = [reading countForFetchRequest:request error:NULL];
			printf("  count via SQL:    %6.3fs\n", Now() - started); fflush(stdout);
			started = Now();
			CHECK([[reading executeFetchRequest:request error:NULL] count] == expected,
			      "and the scan agrees about the number");
			printf("  count via scan:   %6.3fs\n", Now() - started); fflush(stdout);
			[request release];
		}

		[reading release];
		[reader release];
	}

	printf("pushdown: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
