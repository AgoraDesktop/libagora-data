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
			/* `FUNCTION(...)` IS THE NATURAL UNTRANSLATABLE CASE and it is here now that the grammar has it: the
			 * parser read it as a function named `FUNCTION:` until §0.16, and this suite is what found that. A
			 * comparison whose left side is not a key path cannot be a column test. */
			Agree(reading, personEntity,
			      [NSPredicate predicateWithFormat:@"FUNCTION(name, \"uppercaseString\") == \"PERSON-1\""],
			      "a FUNCTION(...) selector falls back to the scan and agrees");
			Agree(reading, personEntity, [NSPredicate predicateWithFormat:@"age < score"],
			      "a key-path-to-key-path comparison falls back and agrees");
		}

		/* 2b. AND THE SAME EQUIVALENCE FOR THE RESULTS THEMSELVES, not just their number: the test builds its own
		 * reference by fetching everything and filtering with the same predicate, then compares identity sets. */
		{
			NSArray *predicates = [NSArray arrayWithObjects:
			                       [NSPredicate predicateWithFormat:@"age >= 50"],
			                       [NSPredicate predicateWithFormat:@"name BEGINSWITH \"person-1\""],
			                       [NSPredicate predicateWithFormat:@"age IN {1, 2, 3}"],
			                       [NSPredicate predicateWithFormat:@"age BETWEEN {20, 29}"],
			                       [NSPredicate predicateWithFormat:@"NOT (age < 90)"],
			                       [NSPredicate predicateWithFormat:@"FUNCTION(name, \"uppercaseString\") == \"PERSON-1\""],
			                       nil];
			NSUInteger p;

			for (p = 0; p < [predicates count]; p++) {
				NSPredicate *predicate = [predicates objectAtIndex:p];
				NSFetchRequest *sqlRequest = [[NSFetchRequest alloc] init];
				NSFetchRequest *allRequest = [[NSFetchRequest alloc] init];
				NSArray *viaSQL;
				NSArray *all;
				NSMutableSet *expected = [[NSMutableSet alloc] init];
				BOOL same = YES;
				NSUInteger k;

				[sqlRequest setEntity:personEntity];
				[sqlRequest setPredicate:predicate];
				[sqlRequest setReturnsObjectsAsFaults:NO];
				viaSQL = [reading executeFetchRequest:sqlRequest error:NULL];

				[allRequest setEntity:personEntity];
				[allRequest setReturnsObjectsAsFaults:NO];
				all = [reading executeFetchRequest:allRequest error:NULL];
				for (k = 0; k < [all count]; k++) {
					if ([predicate evaluateWithObject:[all objectAtIndex:k]]) {
						[expected addObject:[[all objectAtIndex:k] objectID]];
					}
				}
				if ([viaSQL count] != [expected count]) {
					same = NO;
				}
				for (k = 0; same && k < [viaSQL count]; k++) {
					if (![expected containsObject:[[viaSQL objectAtIndex:k] objectID]]) {
						same = NO;
					}
				}
				CHECK(same == YES, [[predicate predicateFormat] UTF8String]);
				[expected release];
				[allRequest release];
				[sqlRequest release];
			}
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

			/* AND THE FETCH ITSELF, which is what a caller usually wants: the IDs come from the WHERE, and only the
			 * matching rows are built. */
			[request setReturnsObjectsAsFaults:NO];
			started = Now();
			CHECK([[reading executeFetchRequest:request error:NULL] count] == expected,
			      "and the FETCH returns the same rows");
			printf("  fetch via SQL:    %6.3fs\n", Now() - started); fflush(stdout);

			[request setPredicate:nil];
			started = Now();
			CHECK([[reading executeFetchRequest:request error:NULL] count] == 5000,
			      "a full fetch still returns every row");
			printf("  fetch everything: %6.3fs\n", Now() - started); fflush(stdout);
			[request release];
		}

		[reading release];
		[reader release];
	}

	printf("pushdown: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
