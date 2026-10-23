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
	[person setProperties:properties];
	[model setEntities:[NSArray arrayWithObject:person]];
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
		CHECK([ctx save:&error] == YES, "three rows save");
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

	/* the schema is the one the document describes, not whatever the code emitted */
	if (system("sqlite3 /tmp/libagora-data-test.sqlite '.tables' > /tmp/agora-tables.txt 2>/dev/null") == 0) {
		FILE *tables = fopen("/tmp/agora-tables.txt", "r");
		if (tables != NULL) {
			char line[512];
			BOOL sawValue = NO;

			while (fgets(line, sizeof line, tables) != NULL) {
				if (strstr(line, "agora_value") != NULL) { sawValue = YES; }
			}
			fclose(tables);
			CHECK(sawValue == YES, "the SQLite file has the schema's table names, readable by sqlite3");
		}
	}

	printf("serialisation: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
