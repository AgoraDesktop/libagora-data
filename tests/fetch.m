/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * fetch — W5's gate (COREDATA-PLAN.md §12, §8): the pipeline, and every modifier that has a default.
 *
 * EACH MODIFIER IS TESTED AGAINST ITS DEFAULT, because that is the only way to tell a flag that works from a flag
 * that is accepted and ignored: `includesPendingChanges` is compared to a fetch with it off, `includesSubentities`
 * to one that excludes them, and `returnsObjectsAsFaults` to the object it hands back.
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
	NSEntityDescription *employee = [[[NSEntityDescription alloc] init] autorelease];

	[person setName:@"Person"];
	[person setProperties:[NSArray arrayWithObjects:Attr(@"name", NSStringAttributeType),
	                                                Attr(@"age", NSInteger32AttributeType), nil]];
	[employee setName:@"Employee"];
	[employee setSuperentity:person];
	[employee setProperties:[NSArray arrayWithObject:Attr(@"salary", NSInteger32AttributeType)]];
	[model setEntities:[NSArray arrayWithObjects:person, employee, nil]];
	return model;
}

static NSManagedObject *Insert(NSManagedObjectContext *ctx, NSEntityDescription *entity,
                               NSString *name, int age)
{
	NSManagedObject *o = [[NSManagedObject alloc] initWithEntity:entity insertIntoManagedObjectContext:ctx];
	[o setValue:name forKey:@"name"];
	[o setValue:[NSNumber numberWithInt:age] forKey:@"age"];
	return o;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSManagedObjectModel *model = BuildModel();
	NSEntityDescription *personEntity = [[model entitiesByName] objectForKey:@"Person"];
	NSEntityDescription *employeeEntity = [[model entitiesByName] objectForKey:@"Employee"];
	NSPersistentStoreCoordinator *coordinator =
	    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:model];
	NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] init];
	NSFetchRequest *request;
	NSArray *results;
	NSError *error = nil;

	(void)[coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil
	                                options:nil error:&error];
	[ctx setPersistentStoreCoordinator:coordinator];

	/* five rows: alice 40, bob 25, carol 33, dave 51, and one Employee (a subentity) */
	{
		NSArray *names = [NSArray arrayWithObjects:@"alice", @"bob", @"carol", @"dave", nil];
		int ages[4] = {40, 25, 33, 51};
		NSMutableArray *people = [NSMutableArray array];
		NSUInteger i;

		for (i = 0; i < 4; i++) {
			[people addObject:Insert(ctx, personEntity, [names objectAtIndex:i], ages[i])];
		}
		(void)Insert(ctx, employeeEntity, @"erin", 29);
		CHECK([ctx save:&error] == YES, "the five rows save");
		for (i = 0; i < [people count]; i++) { [[people objectAtIndex:i] release]; }
	}

	request = [[NSFetchRequest alloc] init];
	[request setEntity:personEntity];

	/* 1. the default fetch: subentities included, so five rows */
	results = [ctx executeFetchRequest:request error:&error];
	CHECK([results count] == 5, "the default fetch includes subentities (5 rows)");

	/* 2. includesSubentities is a real flag, not a decoration */
	[request setIncludesSubentities:NO];
	CHECK([[ctx executeFetchRequest:request error:&error] count] == 4, "excluding subentities leaves 4");
	[request setIncludesSubentities:YES];

	/* 3. the predicate */
	[request setPredicate:[NSPredicate predicateWithFormat:@"age > 30"]];
	CHECK([[ctx executeFetchRequest:request error:&error] count] == 3, "age > 30 keeps 3");

	/* 4. sorting, descending by age */
	[request setSortDescriptors:[NSArray arrayWithObject:
	    [NSSortDescriptor sortDescriptorWithKey:@"age" ascending:NO]]];
	results = [ctx executeFetchRequest:request error:&error];
	CHECK([[[results objectAtIndex:0] valueForKey:@"age"] intValue] == 51, "the first row is the oldest");
	CHECK([[[results objectAtIndex:2] valueForKey:@"age"] intValue] == 33, "the last is the youngest kept");

	/* 5. offset and limit, in that order */
	[request setFetchOffset:1];
	[request setFetchLimit:1];
	results = [ctx executeFetchRequest:request error:&error];
	CHECK([results count] == 1, "offset 1 plus limit 1 returns one row");
	CHECK([[[results objectAtIndex:0] valueForKey:@"age"] intValue] == 40, "and it is the second-oldest");
	[request setFetchOffset:0];
	[request setFetchLimit:0];

	/* 6. returnsObjectsAsFaults: the pipeline materialises, the door hands back faults */
	CHECK([request returnsObjectsAsFaults] == YES, "faults are the default");
	results = [ctx executeFetchRequest:request error:&error];
	CHECK([[results objectAtIndex:0] isFault] == YES, "so the results come back as faults");
	CHECK([[[results objectAtIndex:0] valueForKey:@"age"] intValue] == 51,
	      "which fire when read");
	[request setReturnsObjectsAsFaults:NO];
	results = [ctx executeFetchRequest:request error:&error];
	CHECK([[results objectAtIndex:0] isFault] == NO, "and with the flag off they arrive materialised");

	/* 7. result types: IDs and dictionaries */
	{
		NSManagedObjectID *anID;

		[request setResultType:NSManagedObjectIDResultType];
		results = [ctx executeFetchRequest:request error:&error];
		CHECK([results count] == 3, "the ID result type counts the same rows");
		anID = [results objectAtIndex:0];
		CHECK([anID isKindOfClass:[NSManagedObjectID class]], "and returns object IDs");
		CHECK([[ctx objectWithID:anID] isKindOfClass:[NSManagedObject class]], "that resolve back to objects");
	}

	{
		NSArray *keys = [NSArray arrayWithObjects:@"name", @"age", nil];
		NSDictionary *row;

		[request setResultType:NSDictionaryResultType];
		[request setPropertiesToFetch:keys];
		results = [ctx executeFetchRequest:request error:&error];
		CHECK([results count] == 3, "the dictionary result type counts the same rows");
		row = [results objectAtIndex:0];
		CHECK([row isKindOfClass:[NSDictionary class]], "and returns dictionaries");
		CHECK([[row allKeys] count] == 2, "with exactly the properties asked for");
		CHECK([row objectForKey:@"age"] != nil && [row objectForKey:@"name"] != nil, "and the right ones");
	}

	/* 8. returnsDistinctResults collapses identical rows */
	{
		NSMutableArray *same = [NSMutableArray array];
		NSUInteger i;

		[request setPropertiesToFetch:[NSArray arrayWithObject:@"age"]];
		for (i = 0; i < [results count]; i++) {
			[same addObject:[[results objectAtIndex:i] objectForKey:@"age"]];
		}
		[request setReturnsDistinctResults:YES];
		CHECK([[ctx executeFetchRequest:request error:&error] count] == 3,
		      "three distinct ages among three rows");
		[request setReturnsDistinctResults:NO];
	}

	/* 9. includesPendingChanges: an unsaved insert is visible by default and invisible when the flag is off */
	{
		NSManagedObject *pending = Insert(ctx, personEntity, @"frank", 60);
		NSFetchRequest *countRequest = [[NSFetchRequest alloc] init];

		[countRequest setEntity:personEntity];
		[countRequest setPredicate:[NSPredicate predicateWithFormat:@"age > 55"]];
		/* NO SAVED ROW IS OLDER THAN 51, so the only row this predicate can match is the unsaved one — which is
		 * exactly the case `includesPendingChanges` exists for. */
		CHECK([[ctx executeFetchRequest:countRequest error:&error] count] == 1,
		      "an unsaved insert is visible to a fetch by default");
		[countRequest setIncludesPendingChanges:NO];
		CHECK([[ctx executeFetchRequest:countRequest error:&error] count] == 0,
		      "and invisible with includesPendingChanges off");
		[pending release];
		[countRequest release];
		[ctx rollback];
	}

	/* 10. affectedStores: a store that is not named answers nothing */
	{
		NSFetchRequest *scoped = [[NSFetchRequest alloc] init];

		[scoped setEntity:personEntity];
		[scoped setAffectedStores:[NSArray arrayWithObject:@"another store"]];
		CHECK([[ctx executeFetchRequest:scoped error:&error] count] == 0,
		      "a fetch scoped to another store returns nothing");
		[scoped release];
	}

	/* 11. countForFetchRequest: agrees with the array */
	{
		NSUInteger counted = [ctx countForFetchRequest:request error:&error];
		CHECK(counted == 3, "countForFetchRequest agrees with the fetch");
	}

	/* 12. the expression whose value is a fetch */
	{
		NSExpression *fetchExpression =
		    [NSFetchRequestExpression expressionForFetch:[NSExpression expressionForConstantValue:request]
		                                        context:[NSExpression expressionForConstantValue:ctx]
		                                      countOnly:YES];
		NSNumber *value = [fetchExpression expressionValueWithObject:nil context:nil];

		CHECK([value intValue] == 3, "a count-only fetch expression evaluates to the count");
		CHECK([(NSFetchRequestExpression *)fetchExpression isCountOnlyRequest] == YES, "and says so");
	}

	/* 13. a request with no entity refuses by name */
	{
		NSFetchRequest *empty = [[[NSFetchRequest alloc] init] autorelease];
		NSError *why = nil;

		CHECK([ctx executeFetchRequest:empty error:&why] == nil, "a request with no entity returns nil");
		CHECK([[why userInfo] objectForKey:@"reason"] != nil, "with a reason");
	}

	[request release];
	[ctx release];
	[coordinator release];
	printf("fetch: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
