/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSMigrationManager.m — two contexts, an association table, and three passes in the order §9 describes.
 *
 * THE PASSES ARE SEPARATE FOR A REASON THAT IS STRUCTURAL, NOT STYLISTIC: relationships can only be rebuilt once
 * every destination object exists, and validation can only run once every relationship is in place. A manager that
 * migrated one object at a time would have to resolve forward references, which is why Apple's design (and this
 * one) keeps the three passes and the table between them.
 *
 * IN-MEMORY MIGRATION IS A DOCUMENTED ADAPTATION: an in-memory store has no URL to reopen, so if the source context
 * already has a store the manager uses it — which is what a caller who seeded `-sourceContext` wants, and the only
 * way this wave is measurable before W7 gives stores files.
 */

#import <CoreData/NSMigrationManager.h>
#import <CoreData/NSMappingModel.h>
#import <CoreData/NSEntityMapping.h>
#import <CoreData/NSEntityMigrationPolicy.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/NSManagedObject.h>
#import <CoreData/NSManagedObjectID.h>
#import <CoreData/NSManagedObjectContext.h>
#import <CoreData/NSManagedObjectModel.h>
#import <CoreData/NSFetchRequest.h>
#import <CoreData/NSPersistentStore.h>
#import <CoreData/NSPersistentStoreCoordinator.h>
#import <CoreData/CoreDataErrors.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSError.h>

static NSError *CDManagerError(NSInteger code, NSString *why)
{
	return [NSError errorWithDomain:@"NSCocoaErrorDomain" code:code
	                      userInfo:[NSDictionary dictionaryWithObject:why forKey:@"reason"]];
}

/* A SOURCE OBJECT'S KEY IN THE TABLE: its object ID, printed. Identity is the ID (§5.2), so two contexts' objects
 * for the same row must land on the same association. */
static NSString *CDAssociationKey(NSManagedObject *object)
{
	return [[object objectID] description];
}

@interface NSMigrationManager (CDPrivate)
- (id)cd_destinationInstanceForSource:(id)source;
@end

@implementation NSMigrationManager

- (id)initWithSourceModel:(NSManagedObjectModel *)sourceModel
         destinationModel:(NSManagedObjectModel *)destinationModel
{
	self = [super init];
	if (self != nil) {
		_sourceModel = [sourceModel retain];
		_destinationModel = [destinationModel retain];
		_associations = [[NSMutableDictionary alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_sourceModel release];
	[_destinationModel release];
	[_mappingModel release];
	[_sourceContext release];
	[_destinationContext release];
	[_associations release];
	[_userInfo release];
	[_cancellationError release];
	[super dealloc];
}

- (NSMappingModel *)mappingModel { return _mappingModel; }
- (NSManagedObjectModel *)sourceModel { return _sourceModel; }
- (NSManagedObjectModel *)destinationModel { return _destinationModel; }
- (NSEntityMapping *)currentEntityMapping { return _currentMapping; }
- (float)migrationProgress { return _progress; }

- (NSDictionary *)userInfo { return _userInfo; }
- (void)setUserInfo:(NSDictionary *)dict
{
	NSDictionary *copy = (dict != nil) ? [[NSDictionary alloc] initWithDictionary:dict] : nil;
	[_userInfo release];
	_userInfo = copy;
}

- (void)cancelMigrationWithError:(NSError *)error
{
	NSError *copy = (error != nil) ? [error retain] : [CDManagerError(NSMigrationCancelledError,
	                                                                 @"the migration was cancelled") retain];
	[_cancellationError release];
	_cancellationError = copy;
}

/* ---- the two contexts ---------------------------------------------------------------------------- */

- (NSManagedObjectContext *)sourceContext
{
	if (_sourceContext == nil) {
		NSPersistentStoreCoordinator *coordinator =
		    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:_sourceModel];
		NSError *error = nil;

		(void)[coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil
		                                options:nil error:&error];
		_sourceContext = [[NSManagedObjectContext alloc] init];
		[_sourceContext setPersistentStoreCoordinator:coordinator];
		[coordinator release];
	}
	return _sourceContext;
}

- (NSManagedObjectContext *)destinationContext
{
	if (_destinationContext == nil) {
		NSPersistentStoreCoordinator *coordinator =
		    [[NSPersistentStoreCoordinator alloc] initWithManagedObjectModel:_destinationModel];
		NSError *error = nil;

		(void)[coordinator addPersistentStoreWithType:NSInMemoryStoreType configuration:nil URL:nil
		                                options:nil error:&error];
		_destinationContext = [[NSManagedObjectContext alloc] init];
		[_destinationContext setPersistentStoreCoordinator:coordinator];
		[coordinator release];
	}
	return _destinationContext;
}

- (NSEntityDescription *)sourceEntityForEntityMapping:(NSEntityMapping *)mEntity
{
	return [[_sourceModel entitiesByName] objectForKey:[mEntity sourceEntityName]];
}

- (NSEntityDescription *)destinationEntityForEntityMapping:(NSEntityMapping *)mEntity
{
	return [[_destinationModel entitiesByName] objectForKey:[mEntity destinationEntityName]];
}

/* ---- the association table ----------------------------------------------------------------------- */

- (void)associateSourceInstance:(NSManagedObject *)sourceInstance
         withDestinationInstance:(NSManagedObject *)destinationInstance
                forEntityMapping:(NSEntityMapping *)entityMapping
{
	NSString *mappingName = [entityMapping name];
	NSMutableDictionary *bySource = [_associations objectForKey:mappingName];

	if (bySource == nil) {
		bySource = [[NSMutableDictionary alloc] init];
		[_associations setObject:bySource forKey:mappingName];
		[bySource release];
	}
	{
		NSString *key = CDAssociationKey(sourceInstance);
		NSMutableArray *destinations = [bySource objectForKey:key];

		if (destinations == nil) {
			destinations = [[NSMutableArray alloc] init];
			[bySource setObject:destinations forKey:key];
			[destinations release];
		}
		if (![destinations containsObject:destinationInstance]) {
			[destinations addObject:destinationInstance];
		}
	}
}

- (NSArray *)destinationInstancesForEntityMappingNamed:(NSString *)mappingName
                                       sourceInstances:(NSArray *)sourceInstances
{
	NSMutableArray *out = [[NSMutableArray alloc] init];
	NSDictionary *bySource = [_associations objectForKey:mappingName];
	NSUInteger i;

	for (i = 0; i < [sourceInstances count]; i++) {
		NSArray *destinations = [bySource objectForKey:CDAssociationKey([sourceInstances objectAtIndex:i])];
		NSUInteger d;

		for (d = 0; d < [destinations count]; d++) {
			id object = [destinations objectAtIndex:d];
			if (![out containsObject:object]) {
				[out addObject:object];
			}
		}
	}
	return [out autorelease];
}

- (NSArray *)sourceInstancesForEntityMappingNamed:(NSString *)mappingName
                                 destinationInstances:(NSArray *)destinationInstances
{
	NSMutableArray *out = [[NSMutableArray alloc] init];
	NSDictionary *bySource = [_associations objectForKey:mappingName];
	NSArray *keys = [bySource allKeys];
	NSUInteger i, d;

	for (i = 0; i < [keys count]; i++) {
		NSArray *destinations = [bySource objectForKey:[keys objectAtIndex:i]];
		for (d = 0; d < [destinations count]; d++) {
			if ([destinationInstances containsObject:[destinations objectAtIndex:d]]) {
				/* THE INVERSE IS A LOOKUP, NOT A STORED SECOND TABLE: the forward one is the fact, and a second copy
				 * of it could disagree. The source object is resolved through the source context by ID. */
				NSArray *sources = [self _sourceInstancesForKey:[keys objectAtIndex:i] mappingName:mappingName];
				NSUInteger s;
				for (s = 0; s < [sources count]; s++) {
					if (![out containsObject:[sources objectAtIndex:s]]) {
						[out addObject:[sources objectAtIndex:s]];
					}
				}
				break;
			}
		}
	}
	(void)i;
	return [out autorelease];
}

/* THE ASSOCIATION IS KEYED BY AN OBJECT ID STRING, so the inverse has to find the object that ID names. The source
 * context is asked for it, which is why this door exists here rather than in the table. */
- (NSArray *)_sourceInstancesForKey:(NSString *)key mappingName:(NSString *)mappingName
{
	NSEntityMapping *mapping = [[_mappingModel entityMappingsByName] objectForKey:mappingName];
	NSEntityDescription *entity = [self sourceEntityForEntityMapping:mapping];
	NSFetchRequest *request;
	NSArray *candidates;
	NSMutableArray *out = [[NSMutableArray alloc] init];
	NSUInteger i;

	if (entity == nil) {
		return [out autorelease];
	}
	request = [[NSFetchRequest alloc] init];
	[request setEntity:entity];
	candidates = [[self sourceContext] executeFetchRequest:request error:NULL];
	for (i = 0; i < [candidates count]; i++) {
		NSManagedObject *object = [candidates objectAtIndex:i];
		if ([CDAssociationKey(object) isEqualToString:key]) {
			[out addObject:object];
		}
	}
	[request release];
	return [out autorelease];
}

- (id)cd_destinationInstanceForSource:(id)source
{
	NSArray *mappingNames = [_associations allKeys];
	NSUInteger i;

	if (![source isKindOfClass:[NSManagedObject class]]) {
		return nil;
	}
	for (i = 0; i < [mappingNames count]; i++) {
		NSDictionary *bySource = [_associations objectForKey:[mappingNames objectAtIndex:i]];
		NSArray *destinations = [bySource objectForKey:CDAssociationKey(source)];
		if ([destinations count] > 0) {
			return [destinations objectAtIndex:0];
		}
	}
	return nil;
}

- (void)reset
{
	[_associations removeAllObjects];
	_currentMapping = nil;
	_progress = 0.0f;
}

/* ---- the migration ------------------------------------------------------------------------------- */

- (BOOL)migrateStoreFromURL:(NSURL *)sourceURL
                       type:(NSString *)sStoreType
                    options:(NSDictionary *)sOptions
           withMappingModel:(NSMappingModel *)mappings
           toDestinationURL:(NSURL *)dURL
            destinationType:(NSString *)dStoreType
         destinationOptions:(NSDictionary *)dOptions
                      error:(NSError **)error
{
	NSArray *entityMappings;
	NSUInteger i;

	(void)sOptions; (void)dOptions;

	if (mappings == nil) {
		mappings = [NSMappingModel inferredMappingModelForSourceModel:_sourceModel
		                                             destinationModel:_destinationModel error:error];
	}
	if (mappings == nil) {
		if (error != NULL) {
			*error = CDManagerError(NSMigrationMissingMappingModelError,
			                        @"no mapping model was given and none could be inferred");
		}
		return NO;
	}
	[_mappingModel release];
	_mappingModel = [mappings retain];

	/* THE SOURCE STORE IS OPENED ONLY IF THE CALLER HAS NOT ALREADY SEEDED ONE — see the header's adaptation note. */
	if ([[[_sourceContext persistentStoreCoordinator] persistentStores] count] == 0) {
		(void)[[[self sourceContext] persistentStoreCoordinator]
		       addPersistentStoreWithType:(sStoreType != nil) ? sStoreType : NSInMemoryStoreType
		                    configuration:nil URL:sourceURL options:nil error:error];
	}
	(void)[[[self destinationContext] persistentStoreCoordinator]
	       addPersistentStoreWithType:(dStoreType != nil) ? dStoreType : NSInMemoryStoreType
	                    configuration:nil URL:dURL options:nil error:error];

	entityMappings = [mappings entityMappings];
	for (i = 0; i < [entityMappings count]; i++) {
		NSEntityMapping *mapping = [entityMappings objectAtIndex:i];
		Class policyClass = NSClassFromString([mapping entityMigrationPolicyClassName]);
		NSEntityMigrationPolicy *policy;
		NSArray *sources;

		if (_cancellationError != nil) {
			if (error != NULL) { *error = [[_cancellationError retain] autorelease]; }
			return NO;
		}
		if (policyClass == Nil) {
			policyClass = [NSEntityMigrationPolicy class];
		}
		policy = [[policyClass alloc] init];
		_currentMapping = mapping;

		/* A REMOVE MAPPING HAS NO DESTINATION PASS: there is nothing to create, and the rows it names are the ones
		 * the destination model no longer describes. */
		if ([mapping mappingType] == NSRemoveEntityMappingType) {
			_currentMapping = nil;
			[policy release];
			continue;
		}

		if (![policy beginEntityMapping:mapping manager:self error:error]) {
			_currentMapping = nil;
			[policy release];
			return NO;
		}

		/* PASS ONE — creation, for every source instance. */
		{
			NSFetchRequest *request = [[NSFetchRequest alloc] init];
			NSUInteger s;

			[request setEntity:[self sourceEntityForEntityMapping:mapping]];
			[request setReturnsObjectsAsFaults:NO];
			sources = [[self sourceContext] executeFetchRequest:request error:error];
			[request release];
			for (s = 0; s < [sources count]; s++) {
				if (![policy createDestinationInstancesForSourceInstance:[sources objectAtIndex:s]
				                                           entityMapping:mapping
				                                                 manager:self
				                                                   error:error]) {
					_currentMapping = nil;
					[policy release];
					return NO;
				}
			}
		}
		if (![policy endInstanceCreationForEntityMapping:mapping manager:self error:error]) {
			_currentMapping = nil;
			[policy release];
			return NO;
		}

		/* PASS TWO — relationships, for every destination instance pass one created. */
		{
			NSArray *destinations = [self destinationInstancesForEntityMappingNamed:[mapping name]
			                                                      sourceInstances:sources];
			NSUInteger d;

			for (d = 0; d < [destinations count]; d++) {
				if (![policy createRelationshipsForDestinationInstance:[destinations objectAtIndex:d]
				                                         entityMapping:mapping
				                                               manager:self
				                                                 error:error]) {
					_currentMapping = nil;
					[policy release];
					return NO;
				}
			}
		}
		if (![policy endRelationshipCreationForEntityMapping:mapping manager:self error:error]) {
			_currentMapping = nil;
			[policy release];
			return NO;
		}

		/* PASS THREE — validation. */
		if (![policy performCustomValidationForEntityMapping:mapping manager:self error:error] ||
		    ![policy endEntityMapping:mapping manager:self error:error]) {
			_currentMapping = nil;
			[policy release];
			return NO;
		}
		[policy release];
		_currentMapping = nil;
	}

	if (![[self destinationContext] save:error]) {
		return NO;
	}
	_progress = 1.0f;
	return YES;
}

@end
