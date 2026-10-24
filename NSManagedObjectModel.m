/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSManagedObjectModel.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/CoreDataErrors.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSData.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSKeyedArchiver.h>

#import <Foundation/NSCoder.h>
#import <Foundation/NSException.h>
#import <Foundation/NSFileManager.h>
#import <Foundation/NSBundle.h>
#import <Foundation/NSPropertyListSerialization.h>

/* THE METADATA KEY IS NSPersistentStore.h's, which is W4's file; naming it here as a literal keeps W1 from
 * depending on a header it does not have yet, and the literal is the one Apple documents. */
static NSString *const CDModelVersionHashesKey = @"NSStoreModelVersionHashes";

static NSError *CDModelError(NSInteger code, NSString *why)
{
	return [NSError errorWithDomain:@"NSCocoaErrorDomain" code:code
	                      userInfo:[NSDictionary dictionaryWithObject:why forKey:@"reason"]];
}

@implementation NSManagedObjectModel

- (id)init
{
	self = [super init];
	if (self != nil) {
		_entities = [[NSMutableArray alloc] init];
		_configurations = [[NSMutableDictionary alloc] init];
		_fetchRequestTemplates = [[NSMutableDictionary alloc] init];
		_localizationDictionary = [[NSMutableDictionary alloc] init];
		_versionIdentifiers = [[NSSet alloc] init];
	}
	return self;
}

/* A `.momd` IS A DIRECTORY: `VersionInfo.plist` names the current version, and `<version>.mom` is it. Without a
 * VersionInfo — which is what a hand-built directory looks like — every `.mom` in it is loaded and merged, because a
 * caller asking for a directory wants the model it describes and not an error about a missing plist. */
+ (NSManagedObjectModel *)cd_modelWithContentsOfURL:(NSURL *)url error:(NSError **)error
{
	NSString *path = [url path];
	NSDictionary *attributes;
	BOOL isDirectory = NO;

	if (path == nil) {
		if (error != NULL) {
			*error = CDModelError(NSMigrationMissingSourceModelError, @"no URL");
		}
		return nil;
	}
	attributes = [[NSFileManager defaultManager] attributesOfItemAtPath:path error:NULL];
	(void)attributes;
	if ([[NSFileManager defaultManager] fileExistsAtPath:path isDirectory:&isDirectory] && isDirectory) {
		NSData *info = [NSData dataWithContentsOfFile:
		                [path stringByAppendingPathComponent:@"VersionInfo.plist"]];
		NSString *current = nil;

		if (info != nil) {
			id plist = [NSPropertyListSerialization propertyListWithData:info
			                                                     options:NSPropertyListImmutable
			                                                      format:NULL error:NULL];
			if ([plist isKindOfClass:[NSDictionary class]]) {
				current = [plist objectForKey:@"NSManagedObjectModel_CurrentVersionName"];
			}
		}
		if (current != nil) {
			return [self cd_modelWithContentsOfURL:
			        [NSURL fileURLWithPath:[[path stringByAppendingPathComponent:current]
			                                stringByAppendingPathExtension:@"mom"]]
			                                 error:error];
		}
		{
			/* EVERY `.mom` IN THE DIRECTORY, MERGED. */
			NSArray *entries = [[NSFileManager defaultManager] contentsOfDirectoryAtPath:path error:NULL];
			NSMutableArray *models = [[NSMutableArray alloc] init];
			NSUInteger i;

			for (i = 0; i < [entries count]; i++) {
				NSString *entry = [entries objectAtIndex:i];

				if (![[entry pathExtension] isEqualToString:@"mom"]) {
					continue;
				}
				{
					NSManagedObjectModel *one =
					    [self cd_modelWithContentsOfURL:
					     [NSURL fileURLWithPath:[path stringByAppendingPathComponent:entry]] error:error];
					if (one != nil) { [models addObject:one]; }
				}
			}
			if ([models count] == 0) {
				[models release];
				if (error != NULL) {
					*error = CDModelError(NSMigrationMissingSourceModelError,
					                      @"the model directory holds no .mom");
				}
				return nil;
			}
			{
				NSManagedObjectModel *merged = [NSManagedObjectModel modelByMergingModels:models];
				[models release];
				return merged;
			}
		}
	}

	{
		NSData *data = [NSData dataWithContentsOfFile:path];
		id decoded;

		if (data == nil) {
			if (error != NULL) {
				*error = CDModelError(NSMigrationMissingSourceModelError,
				                      [NSString stringWithFormat:@"nothing readable at %@", path]);
			}
			return nil;
		}
		decoded = [NSKeyedUnarchiver unarchiveObjectWithData:data];
		if (![decoded isKindOfClass:[NSManagedObjectModel class]]) {
			/* **A NAMED REFUSAL, NOT A COMPATIBILITY CLAIM** (§0.20). A file that is a keyed archive and is not this
			 * library's model is, in practice, `momc`'s — Apple's compiled format. It is REFUSED: the class names
			 * could be mapped (`+setClass:forClassName:` exists) but Apple's ENCODER KEYS are undocumented and no
			 * compiled Core Data model exists on this machine to measure them against (§0.14). Saying "not an
			 * archived model" would leave a caller guessing between a corrupt file and a format this tree does not
			 * read. */
			if (error != NULL) {
				*error = CDRefuse(@"Apple's compiled model format (momc)", 
				    [NSString stringWithFormat:
				     @"%@ is not a model this library archived. Apple's .mom is a keyed archive whose CLASS NAMES could "
				     @"be mapped but whose ENCODER KEYS are undocumented, and no compiled Core Data model exists on this "
				     @"machine to measure them against: archive a model with NSKeyedArchiver instead "
				     @"(COREDATA-PLAN.md section 0.20)", path],
				    NSMigrationMissingSourceModelError);
			}
			return nil;
		}
		return decoded;
	}
}

- (id)initWithContentsOfURL:(NSURL *)url
{
	NSManagedObjectModel *model = [NSManagedObjectModel cd_modelWithContentsOfURL:url error:NULL];

	if (model == nil) {
		[NSException raise:NSInvalidArgumentException
		            format:@"NSManagedObjectModel: nothing readable at %@", url];
	}
	[self release];
	return [model retain];
}

- (void)dealloc
{
	[_entities release];
	[_configurations release];
	[_fetchRequestTemplates release];
	[_localizationDictionary release];
	[_versionIdentifiers release];
	[super dealloc];
}

/* ---- the two merging doors ----------------------------------------------------------------------- */

+ (NSManagedObjectModel *)modelByMergingModels:(NSArray *)models
{
	NSManagedObjectModel *merged = [[NSManagedObjectModel alloc] init];
	NSMutableDictionary *byName = [[NSMutableDictionary alloc] init];
	NSUInteger m, i;

	for (m = 0; m < [models count]; m++) {
		NSManagedObjectModel *model = [models objectAtIndex:m];
		for (i = 0; i < [[model entities] count]; i++) {
			NSEntityDescription *entity = [[model entities] objectAtIndex:i];
			NSEntityDescription *existing = [byName objectForKey:[entity name]];

			if (existing != nil) {
				/* TWO MODELS THAT DISAGREE ABOUT AN ENTITY ARE A MODELLING ERROR, and merging the second one
				 * over the first would produce a model nobody wrote. */
				[byName release];
				[merged release];
				[NSException raise:NSInvalidArgumentException
				            format:@"NSManagedObjectModel: two models define the entity `%@`", [entity name]];
			}
			{
				NSEntityDescription *copy = [entity copy];
				[byName setObject:copy forKey:[entity name]];
				[merged->_entities addObject:copy];
				[copy release];
			}
		}
	}
	for (i = 0; i < [merged->_entities count]; i++) {
		[[merged->_entities objectAtIndex:i] cd_setManagedObjectModel:merged];
	}
	[byName release];
	return [merged autorelease];
}

+ (NSManagedObjectModel *)modelByMergingModels:(NSArray *)models
                               forStoreMetadata:(NSDictionary *)metadata
{
	(void)metadata;
	return [self modelByMergingModels:models];
}

+ (NSManagedObjectModel *)mergedModelFromBundles:(NSArray *)bundles
{
	NSMutableArray *models = [[NSMutableArray alloc] init];
	NSManagedObjectModel *merged;
	NSUInteger i;

	/* EVERY `.momd` AND `.mom` IN EVERY BUNDLE, merged. `bundles` nil means the main bundle, which is Apple's
	 * contract and the common call. */
	if (bundles == nil) {
		bundles = [NSArray arrayWithObject:[NSBundle mainBundle]];
	}
	for (i = 0; i < [bundles count]; i++) {
		NSBundle *bundle = [bundles objectAtIndex:i];
		NSArray *extensions = [NSArray arrayWithObjects:@"momd", @"mom", nil];
		NSUInteger e;

		for (e = 0; e < [extensions count]; e++) {
			NSArray *paths = [bundle pathsForResourcesOfType:[extensions objectAtIndex:e]
			                                     inDirectory:nil];
			NSUInteger p;

			for (p = 0; p < [paths count]; p++) {
				NSManagedObjectModel *one =
				    [self cd_modelWithContentsOfURL:
				     [NSURL fileURLWithPath:[paths objectAtIndex:p]] error:NULL];
				if (one != nil) { [models addObject:one]; }
			}
		}
	}
	if ([models count] == 0) {
		[models release];
		/* AN EMPTY MODEL RETURNED "SUCCESSFULLY" IS THE FAILURE THIS REFUSAL PREVENTS: nothing was found, and a
		 * caller that proceeded would migrate nothing and report success. */
		[NSException raise:NSInvalidArgumentException
		            format:@"NSManagedObjectModel: +mergedModelFromBundles: found no .momd or .mom in %lu bundle(s)",
		                   (unsigned long)[bundles count]];
	}
	merged = [self modelByMergingModels:models];
	[models release];
	return merged;
}

+ (NSManagedObjectModel *)mergedModelFromBundles:(NSArray *)bundles
                                 forStoreMetadata:(NSDictionary *)metadata
{
	return [self mergedModelFromBundles:bundles];
}

/* ---- entities ------------------------------------------------------------------------------------ */

- (NSArray *)entities { return _entities; }

- (void)setEntities:(NSArray *)entities
{
	NSMutableDictionary *seen = [[NSMutableDictionary alloc] init];
	NSUInteger i, n = [entities count];

	[_entities removeAllObjects];
	for (i = 0; i < n; i++) {
		NSEntityDescription *e = [entities objectAtIndex:i];

		if ([seen objectForKey:[e name]] != nil) {
			[seen release];
			[NSException raise:NSInvalidArgumentException
			            format:@"NSManagedObjectModel: two entities are named `%@`", [e name]];
		}
		[seen setObject:e forKey:[e name]];
		[_entities addObject:e];
		[e cd_setManagedObjectModel:self];
	}
	[seen release];
}

- (NSDictionary *)entitiesByName
{
	NSMutableDictionary *out = [[NSMutableDictionary alloc] init];
	NSUInteger i, n = [_entities count];

	for (i = 0; i < n; i++) {
		NSEntityDescription *e = [_entities objectAtIndex:i];
		[out setObject:e forKey:[e name]];
	}
	return [out autorelease];
}

/* ---- configurations ------------------------------------------------------------------------------ */

- (NSArray *)configurations
{
	return [_configurations allKeys];
}

- (NSArray *)entitiesForConfiguration:(NSString *)configuration
{
	if (configuration == nil) {
		return _entities;	/* the default configuration is everything */
	}
	return [_configurations objectForKey:configuration];
}

- (void)setEntities:(NSArray *)entities forConfiguration:(NSString *)configuration
{
	if (configuration == nil) {
		[self setEntities:entities];
		return;
	}
	[_configurations setObject:[[NSArray alloc] initWithArray:entities] forKey:configuration];
}

/* ---- fetch request templates --------------------------------------------------------------------- */

- (void)setFetchRequestTemplate:(NSFetchRequest *)fetchRequestTemplate forName:(NSString *)name
{
	id copy = [fetchRequestTemplate copy];

	if (name == nil) {
		[NSException raise:NSInvalidArgumentException
		            format:@"NSManagedObjectModel: a fetch request template needs a name"];
	}
	[_fetchRequestTemplates setObject:copy forKey:name];
	[copy release];
}

- (NSFetchRequest *)fetchRequestTemplateForName:(NSString *)name
{
	return [_fetchRequestTemplates objectForKey:name];
}

- (NSDictionary *)fetchRequestTemplatesByName
{
	return _fetchRequestTemplates;
}

- (NSFetchRequest *)fetchRequestFromTemplateWithName:(NSString *)name
                               substitutionVariables:(NSDictionary *)variables
{
	id template = [_fetchRequestTemplates objectForKey:name];
	id request = [template copy];
	id predicate;

	if (template == nil) {
		return nil;
	}
	if (![request respondsToSelector:@selector(predicate)] ||
	    ![request respondsToSelector:@selector(setPredicate:)]) {
		[request release];
		[NSException raise:NSInvalidArgumentException
		            format:@"NSManagedObjectModel: `%@` is not a fetch request; NSFetchRequest arrives in "
		                   @"COREDATA-PLAN.md W5", name];
	}
	predicate = [request predicate];
	if (predicate != nil) {
		[request setPredicate:[predicate predicateWithSubstitutionVariables:variables]];
	}
	return [request autorelease];
}

/* ---- localization and versioning ----------------------------------------------------------------- */

- (NSDictionary *)localizationDictionary { return _localizationDictionary; }
- (void)setLocalizationDictionary:(NSDictionary *)localizationDictionary
{
	NSDictionary *copy = (localizationDictionary != nil)
	    ? [[NSDictionary alloc] initWithDictionary:localizationDictionary] : [[NSDictionary alloc] init];
	[_localizationDictionary release];
	_localizationDictionary = (NSMutableDictionary *)copy;
}

- (NSSet *)versionIdentifiers { return _versionIdentifiers; }
- (void)setVersionIdentifiers:(NSSet *)identifiers
{
	NSSet *copy = (identifiers != nil) ? [[NSSet alloc] initWithSet:identifiers] : [[NSSet alloc] init];
	[_versionIdentifiers release];
	_versionIdentifiers = copy;
}

- (NSDictionary *)entityVersionHashesByName
{
	NSMutableDictionary *out = [[NSMutableDictionary alloc] init];
	NSUInteger i, n = [_entities count];

	for (i = 0; i < n; i++) {
		NSEntityDescription *e = [_entities objectAtIndex:i];
		[out setObject:[e versionHash] forKey:[e name]];
	}
	return [out autorelease];
}

- (BOOL)isConfiguration:(NSString *)configuration
    compatibleWithStoreMetadata:(NSDictionary *)metadata
{
	NSDictionary *stored = [metadata objectForKey:CDModelVersionHashesKey];
	NSArray *entities = [self entitiesForConfiguration:configuration];
	NSUInteger i;

	if (stored == nil) {
		return NO;
	}
	for (i = 0; i < [entities count]; i++) {
		NSEntityDescription *e = [entities objectAtIndex:i];
		NSData *theirs = [stored objectForKey:[e name]];

		/* A MISSING ENTITY IS AN INCOMPATIBILITY, not a skip: a store that predates an entity cannot answer a
		 * fetch for it, and the migration machinery needs to see that as a mismatch rather than discover it at
		 * the first query. */
		if (theirs == nil || ![theirs isEqualToData:[e versionHash]]) {
			return NO;
		}
	}
	return YES;
}

/* ---- NSFastEnumeration over the entities --------------------------------------------------------- */

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer
                                    count:(NSUInteger)len
{
	return [_entities countByEnumeratingWithState:state objects:buffer count:len];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<NSManagedObjectModel: %lu entities>", (unsigned long)[_entities count]];
}

/* ---- coding -------------------------------------------------------------------------------------- */

- (id)copyWithZone:(NSZone *)zone
{
	(void)zone;
	NSManagedObjectModel *m = [[NSManagedObjectModel allocWithZone:zone] init];
	NSUInteger i;

	for (i = 0; i < [_entities count]; i++) {
		NSEntityDescription *e = [[_entities objectAtIndex:i] copy];
		[m->_entities addObject:e];
		[e cd_setManagedObjectModel:m];
		[e release];
	}
	[m->_configurations addEntriesFromDictionary:_configurations];
	[m->_fetchRequestTemplates addEntriesFromDictionary:_fetchRequestTemplates];
	[m->_localizationDictionary addEntriesFromDictionary:_localizationDictionary];
	[m->_versionIdentifiers release];
	m->_versionIdentifiers = [_versionIdentifiers retain];
	return m;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:_entities forKey:@"entities"];
	[coder encodeObject:[_configurations allKeys] forKey:@"configurationNames"];
	{
		NSMutableDictionary *named = [[NSMutableDictionary alloc] init];
		NSArray *keys = [_configurations allKeys];
		NSUInteger i;
		for (i = 0; i < [keys count]; i++) {
			NSArray *members = [_configurations objectForKey:[keys objectAtIndex:i]];
			NSMutableArray *names = [[NSMutableArray alloc] init];
			NSUInteger j;
			for (j = 0; j < [members count]; j++) {
				[names addObject:[[members objectAtIndex:j] name]];
			}
			[named setObject:names forKey:[keys objectAtIndex:i]];
			[names release];
		}
		[coder encodeObject:named forKey:@"configurationMembers"];
		[named release];
	}
	[coder encodeObject:_fetchRequestTemplates forKey:@"fetchRequestTemplates"];
	[coder encodeObject:_localizationDictionary forKey:@"localizationDictionary"];
	[coder encodeObject:_versionIdentifiers forKey:@"versionIdentifiers"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super init];
	if (self != nil) {
		NSUInteger i;
		NSDictionary *members;
		NSArray *names;

		_entities = [[NSMutableArray alloc] initWithArray:[coder decodeObjectForKey:@"entities"]];
		for (i = 0; i < [_entities count]; i++) {
			[[_entities objectAtIndex:i] cd_setManagedObjectModel:self];
		}
		_configurations = [[NSMutableDictionary alloc] init];
		members = [coder decodeObjectForKey:@"configurationMembers"];
		names = [members allKeys];
		{
			NSDictionary *byName = [self entitiesByName];
			for (i = 0; i < [names count]; i++) {
				NSString *key = [names objectAtIndex:i];
				NSArray *entityNames = [members objectForKey:key];
				NSMutableArray *list = [[NSMutableArray alloc] init];
				NSUInteger j;
				for (j = 0; j < [entityNames count]; j++) {
					NSEntityDescription *e = [byName objectForKey:[entityNames objectAtIndex:j]];
					if (e != nil) { [list addObject:e]; }
				}
				[_configurations setObject:list forKey:key];
				[list release];
			}
		}
		_fetchRequestTemplates = [[NSMutableDictionary alloc] initWithDictionary:
		                          [coder decodeObjectForKey:@"fetchRequestTemplates"]];
		_localizationDictionary = [[NSMutableDictionary alloc] initWithDictionary:
		                           [coder decodeObjectForKey:@"localizationDictionary"]];
		_versionIdentifiers = [[coder decodeObjectForKey:@"versionIdentifiers"] retain];
		if (_versionIdentifiers == nil) { _versionIdentifiers = [[NSSet alloc] init]; }
	}
	return self;
}

@end
