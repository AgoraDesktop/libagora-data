/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSManagedObjectModel — the schema: the entities, the named configurations that partition them across stores,
 * and the fetch-request templates. W1 of COREDATA-PLAN.md §12, and the object W4's coordinator is opened from.
 *
 * A MODEL OWNS ITS ENTITIES AND NOTHING OWNS A MODEL: `-setEntities:` writes each entity's `-managedObjectModel`
 * back-pointer, the entity does not retain the model, and there is no cycle.
 *
 * `+mergedModelFromBundles:` REFUSES, AND WHY IS THE INTERESTING PART. Apple's version looks for *compiled*
 * models (`.momd` / `.mom`) in a bundle; this tree has no model compiler, so there is nothing for it to find and
 * a silent empty model would be worse than a refusal. `+modelByMergingModels:` — the in-memory half, which is
 * what a model compiler's output would be merged with — IS implemented, so the day a `.mom` reader exists only
 * the door that opens files is missing.
 *
 * `-initWithContentsOfURL:` IS IMPLEMENTED, and it reads a keyed archive: a model this library archived can be
 * written and read back today, which is what makes the model's `NSCoding` conformance a measured claim rather
 * than a declared one.
 */

#ifndef COREDATA_NSMANAGEDOBJECTMODEL_H
#define COREDATA_NSMANAGEDOBJECTMODEL_H

#import <Foundation/Foundation.h>
#import <CoreData/CoreDataDefines.h>

@class NSEntityDescription;
@class NSFetchRequest;
@class NSURL;

@interface NSManagedObjectModel : NSObject <NSCoding, NSCopying, NSFastEnumeration>
{
	NSMutableArray *_entities;
	NSMutableDictionary *_configurations;
	NSMutableDictionary *_fetchRequestTemplates;
	NSMutableDictionary *_localizationDictionary;
	NSSet *_versionIdentifiers;
}

+ (NSManagedObjectModel *)mergedModelFromBundles:(NSArray *)bundles;
+ (NSManagedObjectModel *)mergedModelFromBundles:(NSArray *)bundles
                                 forStoreMetadata:(NSDictionary *)metadata;
+ (NSManagedObjectModel *)modelByMergingModels:(NSArray *)models;
+ (NSManagedObjectModel *)modelByMergingModels:(NSArray *)models
                               forStoreMetadata:(NSDictionary *)metadata;

- (id)init;
- (id)initWithContentsOfURL:(NSURL *)url;

- (NSDictionary *)entitiesByName;
- (NSArray *)entities;
- (void)setEntities:(NSArray *)entities;

- (NSArray *)configurations;
- (NSArray *)entitiesForConfiguration:(NSString *)configuration;
- (void)setEntities:(NSArray *)entities forConfiguration:(NSString *)configuration;

- (void)setFetchRequestTemplate:(NSFetchRequest *)fetchRequestTemplate forName:(NSString *)name;
- (NSFetchRequest *)fetchRequestTemplateForName:(NSString *)name;
- (NSFetchRequest *)fetchRequestFromTemplateWithName:(NSString *)name
                               substitutionVariables:(NSDictionary *)variables;
- (NSDictionary *)fetchRequestTemplatesByName;

- (NSDictionary *)localizationDictionary;
- (void)setLocalizationDictionary:(NSDictionary *)localizationDictionary;

- (NSSet *)versionIdentifiers;
- (void)setVersionIdentifiers:(NSSet *)identifiers;

- (BOOL)isConfiguration:(NSString *)configuration
    compatibleWithStoreMetadata:(NSDictionary *)metadata;

- (NSDictionary *)entityVersionHashesByName;

@end

#endif /* COREDATA_NSMANAGEDOBJECTMODEL_H */
