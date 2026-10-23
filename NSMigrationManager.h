/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSMigrationManager — the object that runs a migration: two contexts, an association table, and three passes.
 * W6 of COREDATA-PLAN.md §12.
 *
 * THE ASSOCIATION TABLE IS WHY THE CLASS EXISTS. Pass two needs to know, for a source object, which destination
 * object pass one created for it — so the manager keeps the pairing and answers it two ways,
 * `-destinationInstancesForEntityMappingNamed:sourceInstances:` and its inverse. Without that, a relationship
 * could only be migrated by re-deriving the mapping, which is what the table makes unnecessary.
 *
 * IN-MEMORY MIGRATION USES THE MANAGER'S OWN SOURCE CONTEXT, and that is a documented adaptation: an in-memory
 * store has no URL to reopen, so a caller that wants to migrate one seeds `-sourceContext` and the manager uses
 * what is there. For a file-backed store the URL and type are used and the context is created fresh.
 */

#ifndef COREDATA_NSMIGRATIONMANAGER_H
#define COREDATA_NSMIGRATIONMANAGER_H

#import <Foundation/Foundation.h>

@class NSEntityDescription;
@class NSEntityMapping;
@class NSManagedObject;
@class NSManagedObjectContext;
@class NSManagedObjectModel;
@class NSMappingModel;
@class NSURL;

@interface NSMigrationManager : NSObject
{
	NSManagedObjectModel *_sourceModel;		/* retained */
	NSManagedObjectModel *_destinationModel;	/* retained */
	NSMappingModel *_mappingModel;			/* retained */
	NSManagedObjectContext *_sourceContext;	/* retained */
	NSManagedObjectContext *_destinationContext;	/* retained */
	NSMutableDictionary *_associations;		/* entity mapping name -> {source ID string -> dest objects} */
	NSEntityMapping *_currentMapping;		/* NOT retained */
	NSDictionary *_userInfo;
	NSError *_cancellationError;			/* retained */
	float _progress;
}

- (id)initWithSourceModel:(NSManagedObjectModel *)sourceModel
         destinationModel:(NSManagedObjectModel *)destinationModel;

- (BOOL)migrateStoreFromURL:(NSURL *)sourceURL
                       type:(NSString *)sStoreType
                    options:(NSDictionary *)sOptions
           withMappingModel:(NSMappingModel *)mappings
           toDestinationURL:(NSURL *)dURL
            destinationType:(NSString *)dStoreType
         destinationOptions:(NSDictionary *)dOptions
                      error:(NSError **)error;

- (void)reset;

- (NSMappingModel *)mappingModel;
- (NSManagedObjectModel *)sourceModel;
- (NSManagedObjectModel *)destinationModel;
- (NSManagedObjectContext *)sourceContext;
- (NSManagedObjectContext *)destinationContext;

- (NSEntityDescription *)sourceEntityForEntityMapping:(NSEntityMapping *)mEntity;
- (NSEntityDescription *)destinationEntityForEntityMapping:(NSEntityMapping *)mEntity;

- (void)associateSourceInstance:(NSManagedObject *)sourceInstance
         withDestinationInstance:(NSManagedObject *)destinationInstance
                forEntityMapping:(NSEntityMapping *)entityMapping;

- (NSArray *)destinationInstancesForEntityMappingNamed:(NSString *)mappingName
                                       sourceInstances:(NSArray *)sourceInstances;
- (NSArray *)sourceInstancesForEntityMappingNamed:(NSString *)mappingName
                                 destinationInstances:(NSArray *)destinationInstances;

- (NSEntityMapping *)currentEntityMapping;
- (float)migrationProgress;

- (NSDictionary *)userInfo;
- (void)setUserInfo:(NSDictionary *)dict;

- (void)cancelMigrationWithError:(NSError *)error;

@end

#endif /* COREDATA_NSMIGRATIONMANAGER_H */
