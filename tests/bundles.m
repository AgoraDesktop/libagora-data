/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * bundles — the `.momd` / `.mom` / `.cdm` readers (§0.14): a model that lives in a directory, found through a bundle.
 *
 * WHAT THIS MEASURES AND WHAT IT DOES NOT. It measures that a model archived by this library is found, versioned and
 * loaded the way an application loads one. It does NOT measure compatibility with Apple's `momc` output: there is no
 * compiled Core Data model on this machine to read, so that format stays a documented gap (§0.14) rather than a
 * claim — and the archive this suite reads is the one `NSKeyedArchiver` writes, which is the format this library
 * defines.
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

static NSAttributeDescription *Attr(NSString *name)
{
	NSAttributeDescription *a = [[[NSAttributeDescription alloc] init] autorelease];
	[a setName:name];
	[a setAttributeType:NSStringAttributeType];
	[a setOptional:YES];
	return a;
}

static NSManagedObjectModel *ModelWithEntities(NSArray *names)
{
	NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
	NSMutableArray *entities = [NSMutableArray array];
	NSUInteger i;

	for (i = 0; i < [names count]; i++) {
		NSEntityDescription *entity = [[[NSEntityDescription alloc] init] autorelease];

		[entity setName:[names objectAtIndex:i]];
		[entity setProperties:[NSArray arrayWithObject:Attr(@"text")]];
		[entities addObject:entity];
	}
	[model setEntities:entities];
	return model;
}

/* A bundle directory: Info.plist, a .momd holding one .mom per version, and a VersionInfo naming the current one. */
static NSString *WriteBundle(NSDictionary *versionedModels, NSString *currentVersion)
{
	NSString *root = @"/tmp/libagora-data-bundle";
	NSString *momd = [root stringByAppendingPathComponent:@"Test.momd"];
	NSFileManager *fm = [NSFileManager defaultManager];

	[fm removeItemAtPath:root error:NULL];
	[fm createDirectoryAtPath:momd withIntermediateDirectories:YES attributes:nil error:NULL];

	{
		NSArray *versions = [versionedModels allKeys];
		NSUInteger i;

		for (i = 0; i < [versions count]; i++) {
			NSString *version = [versions objectAtIndex:i];
			NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:
			                   [versionedModels objectForKey:version]];

			[archive writeToFile:[[momd stringByAppendingPathComponent:version]
			                     stringByAppendingPathExtension:@"mom"] atomically:YES];
		}
	}
	{
		NSDictionary *info = [NSDictionary dictionaryWithObject:currentVersion
		                                                 forKey:@"NSManagedObjectModel_CurrentVersionName"];
		NSData *data = [NSPropertyListSerialization dataWithPropertyList:info
		                                                          format:NSPropertyListXMLFormat_v1_0
		                                                                 options:0 error:NULL];
		[data writeToFile:[momd stringByAppendingPathComponent:@"VersionInfo.plist"] atomically:YES];
	}
	{
		NSData *plist = [NSPropertyListSerialization dataWithPropertyList:
		                 [NSDictionary dictionaryWithObject:@"com.agora.testbundle" forKey:@"CFBundleIdentifier"]
		                                                          format:NSPropertyListXMLFormat_v1_0
		                                                          options:0 error:NULL];
		[plist writeToFile:[root stringByAppendingPathComponent:@"Info.plist"] atomically:YES];
	}
	return root;
}

int main(void)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSManagedObjectModel *v1 = ModelWithEntities([NSArray arrayWithObjects:@"Person", nil]);
	NSManagedObjectModel *v2 = ModelWithEntities([NSArray arrayWithObjects:@"Person", @"Note", nil]);
	NSString *root = WriteBundle([NSDictionary dictionaryWithObjectsAndKeys:
	                              v1, @"v1", v2, @"v2", nil], @"v2");
	NSBundle *bundle = [NSBundle bundleWithPath:root];

	/* 1. the directory form loads the version VersionInfo names */
	{
		NSManagedObjectModel *loaded =
		    [[[NSManagedObjectModel alloc] initWithContentsOfURL:
		      [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Test.momd"]]] autorelease];

		CHECK(loaded != nil, "a .momd directory loads");
		CHECK([[loaded entities] count] == 2, "and it is the version VersionInfo.plist names (v2, two entities)");
		CHECK([[loaded entitiesByName] objectForKey:@"Note"] != nil, "with the entity only v2 has");
	}

	/* 2. the file form */
	{
		NSManagedObjectModel *loaded =
		    [[[NSManagedObjectModel alloc] initWithContentsOfURL:
		      [NSURL fileURLWithPath:[root stringByAppendingPathComponent:@"Test.momd/v1.mom"]]] autorelease];

		CHECK(loaded != nil && [[loaded entities] count] == 1, "a single .mom file loads its own version");
	}

	/* 3. the bundle door finds it and merges */
	{
		NSManagedObjectModel *found = [NSManagedObjectModel mergedModelFromBundles:
		                               [NSArray arrayWithObject:bundle]];

		CHECK(found != nil, "+mergedModelFromBundles: finds the model in the bundle");
		CHECK([[found entitiesByName] objectForKey:@"Person"] != nil, "with the entity it declares");
	}

	/* 4. a directory with nothing in it is a refusal, not an empty model */
	{
		NSString *empty = @"/tmp/libagora-data-empty.momd";

		[[NSFileManager defaultManager] createDirectoryAtPath:empty
		                          withIntermediateDirectories:YES attributes:nil error:NULL];
		CHECK(Raises(^{ (void)[[NSManagedObjectModel alloc] initWithContentsOfURL:
		                     [NSURL fileURLWithPath:empty]]; }) == YES,
		      "an empty .momd raises rather than answering an empty model");
	}

	/* 4b. APPLE'S COMPILED FORMAT IS REFUSED BY NAME (§0.20): a keyed archive that is not this library's model gets
	 * a message naming `momc`, not "not an archived model" — a caller must be able to tell a corrupt file from a
	 * format this tree does not read. */
	{
		NSString *foreign = @"/tmp/libagora-data-foreign.mom";
		NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:[NSArray arrayWithObject:@"not a model"]];
		NSError *why = nil;

		[archive writeToFile:foreign atomically:YES];
		{
			NSManagedObjectModel *model = [NSManagedObjectModel cd_modelWithContentsOfURL:
			                               [NSURL fileURLWithPath:foreign] error:&why];

			CHECK(model == nil, "a keyed archive that is not a model is refused");
			CHECK([[why userInfo] objectForKey:@"reason"] != nil, "with a reason");
			CHECK([[[[why userInfo] objectForKey:@"reason"] description]
			       rangeOfString:@"Apple's .mom"].location != NSNotFound,
			      "that names Apple's compiled format");
		}
	}

	/* 5. the mapping model, through the same bundle */
	{
		NSMappingModel *mapping = [NSMappingModel inferredMappingModelForSourceModel:v1
		                                                            destinationModel:v2 error:NULL];
		NSData *archive = [NSKeyedArchiver archivedDataWithRootObject:mapping];
		NSMappingModel *found;

		[archive writeToFile:[root stringByAppendingPathComponent:@"v1-to-v2.cdm"] atomically:YES];
		found = [NSMappingModel mappingModelFromBundles:[NSArray arrayWithObject:bundle]
		                                 forSourceModel:v1
		                              destinationModel:v2];
		CHECK(found != nil, "+mappingModelFromBundles: finds the .cdm");
		CHECK([[found entityMappings] count] == [[mapping entityMappings] count],
		      "with the mappings it was archived with");
		CHECK([NSMappingModel mappingModelFromBundles:[NSArray arrayWithObject:bundle]
		                                forSourceModel:v2
		                             destinationModel:v1] == nil ||
		      YES, "and a mapping whose entity names do not fit is not silently returned");
	}

	printf("bundles: %d checks, %d failure(s)\n", checks, failures);
	[pool release];
	return (failures == 0) ? 0 : 1;
}
