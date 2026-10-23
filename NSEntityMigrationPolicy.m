/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSEntityMigrationPolicy.m — the seven hooks, and the default copy that makes an inferred mapping work.
 *
 * THE DEFAULT `-createDestinationInstances…` IS THE WHOLE MECHANISM: it creates the destination object and applies
 * each attribute mapping's expression, WITH THE SOURCE INSTANCE AS THE EVALUATED OBJECT and the migration keys in
 * the context. A mapping with no attribute mappings at all falls back to copying every destination attribute that
 * the source has, which is what Apple's copy does for an entity whose shape did not change.
 */

#import <CoreData/NSEntityMigrationPolicy.h>
#import <CoreData/NSMigrationManager.h>

/* THE ONE PRIVATE DOOR THIS CLASS NEEDS FROM THE MANAGER: which destination object the association table built for
 * a given source object, across every entity mapping. */
@interface NSMigrationManager (CDPolicyPrivate)
- (id)cd_destinationInstanceForSource:(id)source;
@end
#import <CoreData/NSEntityMapping.h>
#import <CoreData/NSPropertyMapping.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/NSAttributeDescription.h>
#import <CoreData/NSRelationshipDescription.h>
#import <CoreData/NSManagedObject.h>
#import <CoreData/NSManagedObjectContext.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSExpression.h>

NSString *const NSMigrationManagerKey = @"NSMigrationManager";
NSString *const NSMigrationSourceObjectKey = @"NSMigrationSourceObject";
NSString *const NSMigrationDestinationObjectKey = @"NSMigrationDestinationObject";
NSString *const NSMigrationEntityMappingKey = @"NSMigrationEntityMapping";
NSString *const NSMigrationPropertyMappingKey = @"NSMigrationPropertyMapping";
NSString *const NSMigrationEntityPolicyKey = @"NSMigrationEntityPolicy";

static NSMutableDictionary *CDMigrationContext(NSManagedObject *source,
                                               NSManagedObject *destination,
                                               NSEntityMapping *mapping,
                                               NSMigrationManager *manager,
                                               id policy)
{
	/* THE NINETEEN KEYS ARE APPLE'S, and a policy subclass that reads its dictionary by name depends on them
	 * being there. `-copyMigrationContext` is what this class is; the constants above are its keys. */
	NSMutableDictionary *context = [[NSMutableDictionary alloc] init];

	[context setObject:manager forKey:NSMigrationManagerKey];
	[context setObject:mapping forKey:NSMigrationEntityMappingKey];
	[context setObject:policy forKey:NSMigrationEntityPolicyKey];
	if (source != nil) { [context setObject:source forKey:NSMigrationSourceObjectKey]; }
	if (destination != nil) { [context setObject:destination forKey:NSMigrationDestinationObjectKey]; }
	return context;
}

@implementation NSEntityMigrationPolicy

- (BOOL)beginEntityMapping:(NSEntityMapping *)mapping
                   manager:(NSMigrationManager *)manager
                     error:(NSError **)error
{
	(void)mapping; (void)manager; (void)error;
	return YES;
}

- (BOOL)createDestinationInstancesForSourceInstance:(NSManagedObject *)sInstance
                                      entityMapping:(NSEntityMapping *)mapping
                                            manager:(NSMigrationManager *)manager
                                              error:(NSError **)error
{
	NSEntityDescription *destinationEntity = [manager destinationEntityForEntityMapping:mapping];
	NSManagedObject *destination;
	NSArray *attributeMappings = [mapping attributeMappings];
	NSMutableDictionary *context;
	NSUInteger i;

	(void)error;
	if (destinationEntity == nil) {
		return NO;
	}
	destination = [[NSManagedObject alloc] initWithEntity:destinationEntity
	                          insertIntoManagedObjectContext:[manager destinationContext]];
	context = CDMigrationContext(sInstance, destination, mapping, manager, self);

	if ([attributeMappings count] > 0) {
		for (i = 0; i < [attributeMappings count]; i++) {
			NSPropertyMapping *propertyMapping = [attributeMappings objectAtIndex:i];
			id value = [[propertyMapping valueExpression] expressionValueWithObject:sInstance context:context];

			if (value != nil) {
				[destination setValue:value forKey:[propertyMapping name]];
			}
		}
	} else {
		/* NO MAPPINGS: COPY EVERY DESTINATION ATTRIBUTE THE SOURCE HAS. An inferred copy mapping carries mappings,
		 * so this is for a hand-built mapping model that says "copy" and means it. */
		NSDictionary *destinationProperties = [destinationEntity propertiesByName];
		NSArray *keys = [destinationProperties allKeys];

		for (i = 0; i < [keys count]; i++) {
			NSString *key = [keys objectAtIndex:i];
			if ([[destinationProperties objectForKey:key] isKindOfClass:[NSAttributeDescription class]] &&
			    [sInstance primitiveValueForKey:key] != nil) {
				[destination setValue:[sInstance primitiveValueForKey:key] forKey:key];
			}
		}
	}

	[manager associateSourceInstance:sInstance withDestinationInstance:destination forEntityMapping:mapping];
	[context release];
	[destination release];
	return YES;
}

- (BOOL)endInstanceCreationForEntityMapping:(NSEntityMapping *)mapping
                                    manager:(NSMigrationManager *)manager
                                      error:(NSError **)error
{
	(void)mapping; (void)manager; (void)error;
	return YES;
}

- (BOOL)createRelationshipsForDestinationInstance:(NSManagedObject *)dInstance
                                    entityMapping:(NSEntityMapping *)mapping
                                          manager:(NSMigrationManager *)manager
                                            error:(NSError **)error
{
	NSArray *sources = [manager sourceInstancesForEntityMappingNamed:[mapping name]
	                                           destinationInstances:[NSArray arrayWithObject:dInstance]];
	NSArray *relationshipMappings = [mapping relationshipMappings];
	NSUInteger i;

	(void)error;
	if ([sources count] == 0 || [relationshipMappings count] == 0) {
		/* PASS TWO HAS NOTHING TO DO FOR A MAPPING WITH NO RELATIONSHIPS, which is most of them. */
		return YES;
	}
	for (i = 0; i < [relationshipMappings count]; i++) {
		NSPropertyMapping *propertyMapping = [relationshipMappings objectAtIndex:i];
		NSManagedObject *source = [sources objectAtIndex:0];
		NSMutableDictionary *context = CDMigrationContext(source, dInstance, mapping, manager, self);
		id value = [[propertyMapping valueExpression] expressionValueWithObject:source context:context];

		/* A RELATIONSHIP IS REBUILT THROUGH THE ASSOCIATION TABLE, never copied: the destination object it must
		 * point at is the one pass ONE created, and the table is the only thing that knows which that is. */
		if (value != nil) {
			id destination = [(id)manager cd_destinationInstanceForSource:value];
			if (destination != nil) {
				[dInstance setValue:destination forKey:[propertyMapping name]];
			}
		}
		[context release];
	}
	return YES;
}

- (BOOL)endRelationshipCreationForEntityMapping:(NSEntityMapping *)mapping
                                        manager:(NSMigrationManager *)manager
                                          error:(NSError **)error
{
	(void)mapping; (void)manager; (void)error;
	return YES;
}

- (BOOL)performCustomValidationForEntityMapping:(NSEntityMapping *)mapping
                                        manager:(NSMigrationManager *)manager
                                          error:(NSError **)error
{
	(void)mapping; (void)manager; (void)error;
	return YES;
}

- (BOOL)endEntityMapping:(NSEntityMapping *)mapping
                 manager:(NSMigrationManager *)manager
                   error:(NSError **)error
{
	(void)mapping; (void)manager; (void)error;
	return YES;
}

@end
