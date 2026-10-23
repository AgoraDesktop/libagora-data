/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * migration — W6's gate (COREDATA-PLAN.md §12, §9): the inference, the three passes, and the association table.
 *
 * THE INFERRED MAPPING IS THE PART CLIENTS ACTUALLY USE, so it is measured first and in both directions: an entity
 * in both models must come out as a copy or a transform, one only in the destination as an add, and one only in the
 * source as a remove. Then the same mapping model is RUN, which is the only way to tell a mapping model that
 * describes the change from one that performs it.
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

static NSAttributeDescription *Attr(NSString *name, NSAttributeType type)
{
	NSAttributeDescription *a = [[[NSAttributeDescription alloc] init] autorelease];
	[a setName:name];
	[a setAttributeType:type];
	[a setOptional:YES];
	return a;
}

static NSEntityDescription *Entity(NSString *name, NSArray *properties)
{
	NSEntityDescription *e = [[[NSEntityDescription alloc] init] autorelease];
	[e setName:name];
	[e setProperties:properties];
	return e;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	/* v1: Person(name, age).  v2: Person(name, age, nickname) — a transform — plus Note(text) — an add; and
	 * Department existed only in v1, so it is a remove. */
	NSManagedObjectModel *v1 = [[[NSManagedObjectModel alloc] init] autorelease];
	NSManagedObjectModel *v2 = [[[NSManagedObjectModel alloc] init] autorelease];
	NSArray *personV1 = [NSArray arrayWithObjects:Attr(@"name", NSStringAttributeType),
	                                              Attr(@"age", NSInteger32AttributeType), nil];
	NSArray *personV2 = [NSArray arrayWithObjects:Attr(@"name", NSStringAttributeType),
	                                              Attr(@"age", NSInteger32AttributeType),
	                                              Attr(@"nickname", NSStringAttributeType), nil];
	NSMappingModel *inferred;
	NSError *error = nil;

	[v1 setEntities:[NSArray arrayWithObjects:Entity(@"Person", personV1),
	                                          Entity(@"Department", [NSArray arrayWithObject:
	                                                                 Attr(@"title", NSStringAttributeType)]), nil]];
	[v2 setEntities:[NSArray arrayWithObjects:Entity(@"Person", personV2),
	                                          Entity(@"Note", [NSArray arrayWithObject:
	                                                           Attr(@"text", NSStringAttributeType)]), nil]];

	/* 1. the inference, in both directions */
	inferred = [NSMappingModel inferredMappingModelForSourceModel:v1 destinationModel:v2 error:&error];
	CHECK(inferred != nil, "a mapping model is inferred");
	CHECK([[inferred entityMappings] count] == 3, "three mappings: Person, Note and the removed Department");
	{
		NSDictionary *byName = [inferred entityMappingsByName];
		NSEntityMapping *person = [[byName allValues] objectAtIndex:0];
		NSUInteger i;

		CHECK([[inferred entityMappingsByName] count] == 3, "the by-name door agrees");
		for (i = 0; i < [[inferred entityMappings] count]; i++) {
			NSEntityMapping *m = [[inferred entityMappings] objectAtIndex:i];
			if ([[m destinationEntityName] isEqual:@"Person"]) { person = m; }
		}
		CHECK([person mappingType] == NSTransformEntityMappingType,
		      "Person changed shape, so it is a transform");
		CHECK([person sourceEntityVersionHash] != nil && [person destinationEntityVersionHash] != nil,
		      "and carries both entity hashes");
		/* TWO, NOT THREE: `nickname` exists only in the destination, so there is no source value to produce it from
		 * and it keeps its default. A mapping invented for it would be a mapping from nothing. */
		CHECK([[person attributeMappings] count] == 2, "one mapping per property the source also has");
		CHECK([[[person attributeMappings] objectAtIndex:0] valueExpression] != nil,
		      "each carrying a value expression");
	}
	{
		NSDictionary *byName = [inferred entityMappingsByName];
		NSArray *keys = [byName allKeys];
		NSUInteger i;
		BOOL sawAdd = NO;
		BOOL sawRemove = NO;

		for (i = 0; i < [keys count]; i++) {
			NSEntityMapping *m = [byName objectForKey:[keys objectAtIndex:i]];
			if ([m mappingType] == NSAddEntityMappingType && [[m destinationEntityName] isEqual:@"Note"]) {
				sawAdd = YES;
				CHECK([m sourceEntityName] == nil, "an added entity has no source");
			}
			if ([m mappingType] == NSRemoveEntityMappingType && [[m sourceEntityName] isEqual:@"Department"]) {
				sawRemove = YES;
				CHECK([m sourceEntityVersionHash] != nil, "a removed entity still carries its source hash");
			}
		}
		CHECK(sawAdd == YES, "Note is inferred as an add");
		CHECK(sawRemove == YES, "Department is inferred as a remove");
	}

	/* 2. a mapping model survives an archive, which is the shape a .cdm would take */
	{
		NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:inferred];
		NSMappingModel *restored = [NSKeyedUnarchiver unarchiveObjectWithData:archive];

		CHECK(archive != nil && [archive length] > 0, "the mapping model archives");
		CHECK([restored isKindOfClass:[NSMappingModel class]], "and unarchives as one");
		CHECK([[restored entityMappings] count] == 3, "with its three mappings");
		{
			NSEntityMapping *first = [[restored entityMappings] objectAtIndex:0];
			CHECK([[first attributeMappings] count] > 0, "and their attribute mappings");
		}
	}

	/* 3. the migration itself: seed a source context, run the passes, read the destination */
	{
		NSMigrationManager *manager = [[NSMigrationManager alloc] initWithSourceModel:v1
		                                                            destinationModel:v2];
		NSManagedObjectContext *source = [manager sourceContext];
		NSEntityDescription *personEntity = [[v1 entitiesByName] objectForKey:@"Person"];
		NSManagedObject *alice = [[NSManagedObject alloc] initWithEntity:personEntity
		                                   insertIntoManagedObjectContext:source];

		[alice setValue:@"alice" forKey:@"name"];
		[alice setValue:[NSNumber numberWithInt:40] forKey:@"age"];
		CHECK([source save:&error] == YES, "the source row saves");
		CHECK([manager migrationProgress] < 1.0f, "progress starts below 1");

		CHECK([manager migrateStoreFromURL:nil type:NSInMemoryStoreType options:nil
		                 withMappingModel:inferred
		                 toDestinationURL:nil destinationType:NSInMemoryStoreType
		                 destinationOptions:nil error:&error] == YES,
		      "the migration runs");
		CHECK([manager migrationProgress] == 1.0f, "and reports complete");
		CHECK([manager currentEntityMapping] == nil, "with no mapping left current");

		/* the destination row exists, and the default policy copied the values across */
		{
			NSManagedObjectContext *destination = [manager destinationContext];
			NSFetchRequest *request = [[NSFetchRequest alloc] init];
			NSArray *found;

			[request setEntity:[[v2 entitiesByName] objectForKey:@"Person"]];
			found = [destination executeFetchRequest:request error:&error];
			CHECK([found count] == 1, "the destination has one Person");
			CHECK([[[found objectAtIndex:0] valueForKey:@"name"] isEqual:@"alice"], "named alice");
			CHECK([[[found objectAtIndex:0] valueForKey:@"age"] intValue] == 40, "aged 40");
			[request release];
		}

		/* the association table is the record of what was created from what */
		{
			NSArray *destinations = [manager destinationInstancesForEntityMappingNamed:[[inferred entityMappings] count] > 0
			                                                                 ? @"PersonToPerson" : @""
			                                                      sourceInstances:[NSArray arrayWithObject:alice]];
			CHECK(destinations != nil, "the association table answers by mapping name and source");
		}

		[manager reset];
		CHECK([manager migrationProgress] == 0.0f, "reset clears the progress");
		[alice release];
		[manager release];
	}

	/* 4. the doors that are not ready refuse by name */
	CHECK(Raises(^{ (void)[NSMappingModel mappingModelFromBundles:nil
	                                              forSourceModel:v1
	                                           destinationModel:v2]; }) == YES,
	      "+mappingModelFromBundles: refuses (no .cdm reader yet)");

	/* 5. a mapping model built by hand, and the property mapping's own doors */
	{
		NSPropertyMapping *propertyMapping = [[[NSPropertyMapping alloc] init] autorelease];
		NSEntityMapping *mapping = [[[NSEntityMapping alloc] init] autorelease];
		NSMappingModel *handBuilt = [[[NSMappingModel alloc] init] autorelease];

		[propertyMapping setName:@"nickname"];
		[propertyMapping setValueExpression:[NSExpression expressionForKeyPath:@"name"]];
		CHECK([[propertyMapping name] isEqual:@"nickname"], "a property mapping names a destination property");
		CHECK([[propertyMapping valueExpression] keyPath] != nil, "and carries its expression");

		[mapping setName:@"PersonCopy"];
		[mapping setMappingType:NSCopyEntityMappingType];
		[mapping setAttributeMappings:[NSArray arrayWithObject:propertyMapping]];
		CHECK([mapping mappingType] == NSCopyEntityMappingType, "an entity mapping carries its type");
		CHECK([[mapping attributeMappings] count] == 1, "and its attribute mappings");

		[handBuilt setEntityMappings:[NSArray arrayWithObject:mapping]];
		CHECK([[handBuilt entityMappings] count] == 1, "a mapping model can be built in code");
		CHECK([[handBuilt entityMappingsByName] objectForKey:@"PersonCopy"] == mapping, "and indexed by name");
	}

	printf("migration: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
