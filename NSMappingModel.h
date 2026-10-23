/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSMappingModel — the set of entity mappings between two models, and the inference that writes one. W6, §9.
 *
 * `+inferredMappingModelForSourceModel:destinationModel:error:` IS THE DOOR MOST CLIENTS USE, which is why it is
 * the one implemented properly: `NSMigratePersistentStoresAutomaticallyOption` plus
 * `NSInferMappingModelAutomaticallyOption` is what `NSPersistentDocument` does by default, and a migration that
 * only worked with a hand-written `.cdm` would leave every light migration to the caller. Inference handles an
 * entity that is in both models (copy or transform), one that exists only in the destination (add) and one that
 * exists only in the source (remove).
 *
 * `+mappingModelFromBundles:…` REFUSES, for the reason `+mergedModelFromBundles:` does: there is no compiled
 * `.cdm` reader in this tree, and an empty mapping model returned "successfully" would turn a missing file into a
 * migration that deleted nothing and copied nothing.
 */

#ifndef COREDATA_NSMAPPINGMODEL_H
#define COREDATA_NSMAPPINGMODEL_H

#import <Foundation/Foundation.h>

@class NSError;
@class NSManagedObjectModel;
@class NSURL;

@interface NSMappingModel : NSObject
{
	NSMutableArray *_entityMappings;
}

+ (NSMappingModel *)mappingModelFromBundles:(NSArray *)bundles
                             forSourceModel:(NSManagedObjectModel *)sourceModel
                          destinationModel:(NSManagedObjectModel *)destinationModel;
+ (NSMappingModel *)inferredMappingModelForSourceModel:(NSManagedObjectModel *)sourceModel
                                      destinationModel:(NSManagedObjectModel *)destinationModel
                                                 error:(NSError **)error;

- (id)initWithContentsOfURL:(NSURL *)url;

- (NSArray *)entityMappings;
- (void)setEntityMappings:(NSArray *)mappings;
- (NSDictionary *)entityMappingsByName;

@end

#endif /* COREDATA_NSMAPPINGMODEL_H */
