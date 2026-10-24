/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSMappingModel.m — the inference, which is the half of W6 that clients actually use (§9.1).
 *
 * THE THREE CASES ARE THE WHOLE ALGORITHM, and each one is a different mapping type: an entity in both models is a
 * copy (or a transform, when its property list changed), one only in the destination is an add, and one only in the
 * source is a remove. Properties are matched BY NAME, and a destination property with no source namesake simply
 * gets no mapping — which leaves it at its default rather than inventing a value.
 */

#import <CoreData/NSMappingModel.h>
#import <CoreData/NSEntityMapping.h>
#import <CoreData/NSPropertyMapping.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/NSAttributeDescription.h>
#import <CoreData/NSRelationshipDescription.h>
#import <CoreData/NSManagedObjectModel.h>
#import <CoreData/CoreDataErrors.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSData.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSExpression.h>
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSError.h>
#import <Foundation/NSException.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSBundle.h>
#import <Foundation/NSURL.h>

static NSError *CDMappingError(NSInteger code, NSString *why)
{
	return [NSError errorWithDomain:@"NSCocoaErrorDomain" code:code
	                      userInfo:[NSDictionary dictionaryWithObject:why forKey:@"reason"]];
}

@implementation NSMappingModel

- (id)init
{
	self = [super init];
	if (self != nil) {
		_entityMappings = [[NSMutableArray alloc] init];
	}
	return self;
}

- (id)initWithContentsOfURL:(NSURL *)url
{
	NSData *data = (url != nil) ? [NSData dataWithContentsOfURL:url] : nil;
	id decoded;

	if (data == nil) {
		[NSException raise:NSInvalidArgumentException
		            format:@"NSMappingModel: nothing readable at %@", url];
	}
	decoded = [NSKeyedUnarchiver unarchiveObjectWithData:data];
	if (![decoded isKindOfClass:[NSMappingModel class]]) {
		/* THE SAME NAMED REFUSAL FOR `.cdm` (§0.20). */
		(void)CDRefuse(@"Apple's compiled mapping model format (momc)",
		               [NSString stringWithFormat:
		                @"%@ is not a mapping model this library archived; Apple's .cdm has the same undocumented "
		                @"encoder keys as .mom (COREDATA-PLAN.md section 0.20)", url],
		               NSMigrationMissingMappingModelError);
		[NSException raise:NSInvalidArgumentException
		            format:@"NSMappingModel: %@ is not an archived mapping model; Apple's compiled .cdm is refused by "
		                   @"name (COREDATA-PLAN.md section 0.20)", url];
	}
	[self release];
	return [decoded retain];
}

- (void)dealloc
{
	[_entityMappings release];
	[super dealloc];
}

+ (NSMappingModel *)mappingModelFromBundles:(NSArray *)bundles
                             forSourceModel:(NSManagedObjectModel *)sourceModel
                          destinationModel:(NSManagedObjectModel *)destinationModel
{
	NSDictionary *sourceEntities;
	NSDictionary *destinationEntities;
	NSUInteger i, b;

	/* EVERY `.cdm` IN EVERY BUNDLE, and the FIRST ONE THAT FITS BOTH MODELS. A mapping model names the entities it
	 * was written for; one whose names are not in these models is a model for a different pair of versions, and
	 * returning it would migrate by guess. `bundles` nil means the main bundle, which is Apple's contract. */
	if (bundles == nil) {
		bundles = [NSArray arrayWithObject:[NSBundle mainBundle]];
	}
	sourceEntities = (sourceModel != nil) ? [sourceModel entitiesByName] : nil;
	destinationEntities = (destinationModel != nil) ? [destinationModel entitiesByName] : nil;

	for (b = 0; b < [bundles count]; b++) {
		NSArray *paths = [[bundles objectAtIndex:b] pathsForResourcesOfType:@"cdm" inDirectory:nil];

		for (i = 0; i < [paths count]; i++) {
			NSMappingModel *candidate = [[NSMappingModel alloc]
			                             initWithContentsOfURL:[NSURL fileURLWithPath:[paths objectAtIndex:i]]];
			BOOL fits = [candidate isKindOfClass:[NSMappingModel class]];

			[candidate autorelease];
			if (!fits || [[candidate entityMappings] count] == 0) {
				continue;
			}
			{
				NSArray *mappings = [candidate entityMappings];
				NSUInteger m;

				for (m = 0; fits && m < [mappings count]; m++) {
					NSEntityMapping *mapping = [mappings objectAtIndex:m];

					if ([mapping sourceEntityName] != nil && sourceEntities != nil &&
					    [sourceEntities objectForKey:[mapping sourceEntityName]] == nil) {
						fits = NO;
					}
					if ([mapping destinationEntityName] != nil && destinationEntities != nil &&
					    [destinationEntities objectForKey:[mapping destinationEntityName]] == nil) {
						fits = NO;
					}
				}
			}
			if (fits) {
				return candidate;
			}
		}
	}
	return nil;
}

+ (NSMappingModel *)inferredMappingModelForSourceModel:(NSManagedObjectModel *)sourceModel
                                      destinationModel:(NSManagedObjectModel *)destinationModel
                                                 error:(NSError **)error
{
	NSMappingModel *mappingModel = [[NSMappingModel alloc] init];
	NSDictionary *sourceByName;
	NSDictionary *destinationByName;
	NSArray *destinationEntities;
	NSArray *sourceEntities;
	NSUInteger i;

	if (sourceModel == nil || destinationModel == nil) {
		if (error != NULL) {
			*error = CDMappingError(NSInferredMappingModelError,
			                        @"inference needs both a source and a destination model");
		}
		return nil;
	}
	sourceByName = [sourceModel entitiesByName];
	destinationByName = [destinationModel entitiesByName];
	destinationEntities = [destinationModel entities];
	sourceEntities = [sourceModel entities];

	for (i = 0; i < [destinationEntities count]; i++) {
		NSEntityDescription *destination = [destinationEntities objectAtIndex:i];
		NSEntityDescription *source = [sourceByName objectForKey:[destination name]];
		NSEntityMapping *mapping = [[NSEntityMapping alloc] init];

		[mapping setName:[NSString stringWithFormat:@"%@To%@", [destination name], [destination name]]];
		[mapping setDestinationEntityName:[destination name]];
		[mapping setDestinationEntityVersionHash:[destination versionHash]];

		if (source == nil) {
			/* AN ENTITY ONLY IN THE DESTINATION IS AN ADD: no source name, no hashes, and any properties the new
			 * entity declares are left to their defaults. */
			[mapping setMappingType:NSAddEntityMappingType];
		} else {
			BOOL sameShape = ([source versionHash] != nil &&
			                  [[source versionHash] isEqualToData:[destination versionHash]]);
			NSMutableArray *attributes = [[NSMutableArray alloc] init];
			NSMutableArray *relationships = [[NSMutableArray alloc] init];
			NSDictionary *sourceProperties = [source propertiesByName];
			NSDictionary *destinationProperties = [destination propertiesByName];
			NSArray *keys = [destinationProperties allKeys];
			NSUInteger k;

			[mapping setMappingType:sameShape ? NSCopyEntityMappingType : NSTransformEntityMappingType];
			[mapping setSourceEntityName:[destination name]];
			[mapping setSourceEntityVersionHash:[source versionHash]];

			for (k = 0; k < [keys count]; k++) {
				NSString *key = [keys objectAtIndex:k];
				NSPropertyDescription *from = [sourceProperties objectForKey:key];
				NSPropertyDescription *to = [destinationProperties objectForKey:key];
				NSPropertyMapping *propertyMapping;

				if (from == nil || to == nil) {
					continue;	/* a property with no namesake keeps its default */
				}
				propertyMapping = [[NSPropertyMapping alloc] init];
				[propertyMapping setName:key];
				/* THE EXPRESSION IS A KEY PATH, EVALUATED AGAINST THE SOURCE OBJECT by the default policy. That is
				 * what makes an inferred mapping migrate without a policy subclass. */
				[propertyMapping setValueExpression:[NSExpression expressionForKeyPath:key]];
				if ([to isKindOfClass:[NSRelationshipDescription class]]) {
					[relationships addObject:propertyMapping];
				} else {
					[attributes addObject:propertyMapping];
				}
				[propertyMapping release];
			}
			[mapping setAttributeMappings:attributes];
			[mapping setRelationshipMappings:relationships];
			[attributes release];
			[relationships release];
		}
		[mappingModel->_entityMappings addObject:mapping];
		[mapping release];
	}

	/* AND THE OTHER DIRECTION: an entity the destination no longer has is a remove. */
	for (i = 0; i < [sourceEntities count]; i++) {
		NSEntityDescription *source = [sourceEntities objectAtIndex:i];
		if ([destinationByName objectForKey:[source name]] != nil) {
			continue;
		}
		{
			NSEntityMapping *mapping = [[NSEntityMapping alloc] init];
			[mapping setName:[NSString stringWithFormat:@"%@ToNothing", [source name]]];
			[mapping setMappingType:NSRemoveEntityMappingType];
			[mapping setSourceEntityName:[source name]];
			[mapping setSourceEntityVersionHash:[source versionHash]];
			[mappingModel->_entityMappings addObject:mapping];
			[mapping release];
		}
	}
	return [mappingModel autorelease];
}

- (NSArray *)entityMappings { return _entityMappings; }

- (void)setEntityMappings:(NSArray *)mappings
{
	[_entityMappings removeAllObjects];
	[_entityMappings addObjectsFromArray:mappings];
}

- (NSDictionary *)entityMappingsByName
{
	NSMutableDictionary *out = [[NSMutableDictionary alloc] init];
	NSUInteger i;

	for (i = 0; i < [_entityMappings count]; i++) {
		NSEntityMapping *mapping = [_entityMappings objectAtIndex:i];
		[out setObject:mapping forKey:[mapping name]];
	}
	return [out autorelease];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:_entityMappings forKey:@"entityMappings"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super init];
	if (self != nil) {
		_entityMappings = [[NSMutableArray alloc] initWithArray:[coder decodeObjectForKey:@"entityMappings"]];
	}
	return self;
}

@end
