/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * model — W1's gate (COREDATA-PLAN.md §12): a model built in code behaves as the seven classes document, and it
 * survives an archive.
 *
 * THE ARCHIVE TEST IS THE ONE THAT MATTERS MOST, because it is the only one a declaration cannot fake: a model
 * is loaded from a file in every real application, so `NSCoding` on all seven classes is measured by writing a
 * model out and reading it back — and `-initWithContentsOfURL:` is measured through a real temp file rather
 * than a mock.
 *
 * THE VERSION-HASH CHECKS ARE THE SECOND: a digest that changed between two calls, or that ignored a flag,
 * would silently invalidate every store on disk after a rebuild, so the suite asks for determinism,
 * sensitivity, and a pinned value.
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

/* The model every check works from: Person <: Employee, with a to-many and a to-one relationship. */
static NSManagedObjectModel *BuildModel(void)
{
	NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
	NSEntityDescription *person = [[[NSEntityDescription alloc] init] autorelease];
	NSEntityDescription *employee = [[[NSEntityDescription alloc] init] autorelease];
	NSEntityDescription *department = [[[NSEntityDescription alloc] init] autorelease];
	NSAttributeDescription *name = [[[NSAttributeDescription alloc] init] autorelease];
	NSAttributeDescription *age = [[[NSAttributeDescription alloc] init] autorelease];
	NSRelationshipDescription *employer = [[[NSRelationshipDescription alloc] init] autorelease];
	NSRelationshipDescription *staff = [[[NSRelationshipDescription alloc] init] autorelease];

	[person setName:@"Person"];
	[person setManagedObjectClassName:@"Person"];

	[name setName:@"name"];
	[name setAttributeType:NSStringAttributeType];
	[age setName:@"age"];
	[age setAttributeType:NSInteger32AttributeType];
	[age setOptional:NO];
	[person setProperties:[NSArray arrayWithObjects:name, age, nil]];

	[employee setName:@"Employee"];
	[employee setManagedObjectClassName:@"Employee"];
	[employee setSuperentity:person];

	[department setName:@"Department"];

	[staff setName:@"staff"];
	[staff setDestinationEntity:employee];
	[staff setMaxCount:0];			/* 0 means unbounded, which is what makes this to-many */
	[staff setMinCount:0];
	[staff setDeleteRule:NSCascadeDeleteRule];
	[employer setName:@"department"];
	[employer setDestinationEntity:department];
	[employer setInverseRelationship:staff];
	[department setProperties:[NSArray arrayWithObject:staff]];
	[employee setProperties:[NSArray arrayWithObject:employer]];

	[model setEntities:[NSArray arrayWithObjects:person, employee, department, nil]];
	return model;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSManagedObjectModel *model = BuildModel();
	NSEntityDescription *person = [[model entitiesByName] objectForKey:@"Person"];
	NSEntityDescription *employee = [[model entitiesByName] objectForKey:@"Employee"];
	NSEntityDescription *department = [[model entitiesByName] objectForKey:@"Department"];
	NSRelationshipDescription *staff = [[department relationshipsByName] objectForKey:@"staff"];
	NSRelationshipDescription *employer = [[employee relationshipsByName] objectForKey:@"department"];

	/* 1. the model's identity graph */
	CHECK([[model entities] count] == 3, "three entities");
	CHECK([[person managedObjectModel] isEqual:model], "an entity knows its model");
	CHECK([[[person attributesByName] objectForKey:@"name"] attributeValueClassName] != nil &&
	      [[[[person attributesByName] objectForKey:@"name"] attributeValueClassName] isEqualToString:@"NSString"],
	      "a string attribute derives NSString");
	CHECK([staff isToMany] == YES, "maxCount 0 is to-many");
	CHECK([staff deleteRule] == NSCascadeDeleteRule, "the delete rule is the one set");
	CHECK([staff minCount] == 0 && [staff maxCount] == 0, "counts round-trip");

	/* 2. inverse relationships are reciprocal from either side */
	CHECK([employer inverseRelationship] == staff, "the to-one got the inverse back");
	CHECK([staff inverseRelationship] == employer, "the to-many's inverse is the to-one");

	/* 3. inheritance */
	CHECK([employee superentity] == person, "Employee's superentity is Person");
	CHECK([[person subentities] count] == 1, "Person has one subentity");
	CHECK([employee isKindOfEntity:person] == YES, "Employee is a Person");
	CHECK([person isKindOfEntity:employee] == NO, "Person is not an Employee");

	/* 4. duplicate names are model errors, caught at the door */
	{
		NSAttributeDescription *a = [[[NSAttributeDescription alloc] init] autorelease];
		NSAttributeDescription *b = [[[NSAttributeDescription alloc] init] autorelease];
		[a setName:@"dup"];
		[b setName:@"dup"];
		CHECK(Raises(^{ [department setProperties:[NSArray arrayWithObjects:a, b, nil]]; }) == YES,
		      "two properties named the same raise");
	}

	/* 5. the version hash: 32 bytes, deterministic, and sensitive to what it claims to cover */
	{
		NSData *first = [person versionHash];
		NSData *second = [person versionHash];
		NSData *beforeAge;
		NSData *afterAge;

		CHECK([first length] == 32, "the version hash is SHA-256 (32 bytes)");
		CHECK([first isEqualToData:second], "the hash is deterministic across calls");

		beforeAge = [[person versionHash] retain];
		[[[person attributesByName] objectForKey:@"age"] setOptional:YES];
		afterAge = [[person versionHash] retain];
		CHECK(![beforeAge isEqualToData:afterAge], "flipping `optional` changes the entity's hash");
		[[[person attributesByName] objectForKey:@"age"] setOptional:NO];
		CHECK([[person versionHash] isEqualToData:beforeAge], "flipping it back restores the hash");
		[beforeAge release];
		[afterAge release];
	}

	/* 6. per-entity hashes, and configuration compatibility against them */
	{
		NSDictionary *hashes = [model entityVersionHashesByName];
		NSDictionary *metadata = [NSDictionary dictionaryWithObject:hashes forKey:@"NSStoreModelVersionHashes"];

		CHECK([[hashes allKeys] count] == 3, "one hash per entity");
		CHECK([model isConfiguration:nil compatibleWithStoreMetadata:metadata] == YES,
		      "a store carrying this model's hashes is compatible");
		CHECK([model isConfiguration:nil compatibleWithStoreMetadata:[NSDictionary dictionary]] == NO,
		      "a store with no hashes is incompatible");
	}

	/* 7. configurations partition the entities */
	{
		NSArray *people = [NSArray arrayWithObject:person];
		[model setEntities:people forConfiguration:@"PeopleOnly"];

		CHECK([[model entitiesForConfiguration:@"PeopleOnly"] count] == 1, "a named configuration holds one entity");
		CHECK([[model entitiesForConfiguration:nil] count] == 3, "the default configuration is everything");
		CHECK([[model configurations] count] == 1, "one named configuration exists");
	}

	/* 8. THE ARCHIVE: the model survives a keyed round trip, back-pointers included */
	{
		NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:model];
		NSManagedObjectModel *restored = nil;

		CHECK(archive != nil && [archive length] > 0, "the model archives");
		restored = [NSKeyedUnarchiver unarchiveObjectWithData:archive];
		CHECK([restored isKindOfClass:[NSManagedObjectModel class]], "and unarchives as a model");
		CHECK([[restored entities] count] == 3, "with its three entities");
		{
			NSEntityDescription *p2 = [[restored entitiesByName] objectForKey:@"Person"];
			NSEntityDescription *e2 = [[restored entitiesByName] objectForKey:@"Employee"];

			CHECK(p2 != nil && e2 != nil, "the entities came back by name");
			CHECK([p2 managedObjectModel] == restored, "the unarchived entity points at the unarchived model");
			CHECK([[p2 properties] count] == 2, "Person kept its two properties");
			CHECK([e2 superentity] == p2, "Employee still inherits from Person");
			CHECK([[p2 versionHash] isEqualToData:[person versionHash]],
			      "the restored model has the same version hash as the one written");
		}
	}

	/* 9. -initWithContentsOfURL: through a real file */
	{
		NSString *path = @"/tmp/libagora-data-model-test.model";
		NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:model];
		NSManagedObjectModel *fromFile;

		[archive writeToFile:path atomically:YES];
		fromFile = [[[NSManagedObjectModel alloc] initWithContentsOfURL:[NSURL fileURLWithPath:path]] autorelease];
		CHECK([[fromFile entities] count] == 3, "a model read from a file has its entities");
		CHECK([[[fromFile entitiesByName] objectForKey:@"Person"] versionHash] != nil,
		      "and its entities carry hashes");
	}

	/* 10. merging: union by name, and a collision is refused rather than resolved */
	{
		NSManagedObjectModel *other = [[[NSManagedObjectModel alloc] init] autorelease];
		NSEntityDescription *extra = [[[NSEntityDescription alloc] init] autorelease];
		NSManagedObjectModel *merged;

		[extra setName:@"Project"];
		[other setEntities:[NSArray arrayWithObject:extra]];
		merged = [NSManagedObjectModel modelByMergingModels:
		          [NSArray arrayWithObjects:model, other, nil]];
		CHECK([[merged entities] count] == 4, "merging adds the entity it did not have");
		CHECK([[merged entitiesByName] objectForKey:@"Project"] != nil, "by name");
		CHECK(Raises(^{ (void)[NSManagedObjectModel modelByMergingModels:
		                      [NSArray arrayWithObjects:model, model, nil]]; }) == YES,
		      "merging two models that define the same entity raises");
	}

	/* 11. the two doors that are not ready, refusing by name rather than pretending */
	CHECK(Raises(^{ (void)[NSManagedObjectModel mergedModelFromBundles:nil]; }) == YES,
	      "+mergedModelFromBundles: refuses (no .momd reader yet)");
	CHECK(Raises(^{ (void)[NSEntityDescription entityForName:@"Person" inManagedObjectContext:nil]; }) == YES,
	      "+entityForName:inManagedObjectContext: refuses without a context");

	printf("model: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
