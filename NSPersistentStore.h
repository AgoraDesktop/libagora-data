/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSPersistentStore — what a store IS, independent of how it stores. W4 of COREDATA-PLAN.md §12.
 *
 * A STORE IS A NAMED PLACE WITH A METADATA DICTIONARY, and the metadata is the part that matters: it carries
 * `NSStoreTypeKey`, `NSStoreUUIDKey` and `NSStoreModelVersionHashesKey`, which is how a coordinator decides
 * whether a file may be opened at all (D1-b, §7.1). `-loadMetadata:error:` is therefore the door a subclass
 * overrides first, and its default here creates the metadata a new store gets.
 *
 * `-identifier` IS THE STORE'S NAME IN AN OBJECT ID. It is what `NSManagedObjectID` puts in a URI and what
 * `-managedObjectIDForURIRepresentation:` parses back out, so two stores in one coordinator stay distinguishable.
 */

#ifndef COREDATA_NSPERSISTENTSTORE_H
#define COREDATA_NSPERSISTENTSTORE_H

#import <Foundation/Foundation.h>
#import <CoreData/CoreDataDefines.h>

@class NSError;
@class NSManagedObjectModel;
@class NSPersistentStoreCoordinator;
@class NSURL;

@interface NSPersistentStore : NSObject
{
	NSPersistentStoreCoordinator *_coordinator;	/* NOT retained */
	NSString *_configurationName;
	NSString *_identifier;
	NSString *_type;
	NSURL *_URL;
	NSDictionary *_options;
	NSDictionary *_metadata;
	BOOL _readOnly;
}

+ (NSDictionary *)metadataForPersistentStoreWithURL:(NSURL *)url error:(NSError **)error;
+ (BOOL)setMetadata:(NSDictionary *)metadata forPersistentStoreWithURL:(NSURL *)url error:(NSError **)error;
+ (Class)migrationManagerClass;

- (id)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)root
                        configurationName:(NSString *)name
                                      URL:(NSURL *)url
                                  options:(NSDictionary *)options;

- (BOOL)loadMetadata:(NSError **)error;

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator;
- (NSString *)configurationName;
- (NSDictionary *)options;

- (NSURL *)URL;
- (void)setURL:(NSURL *)url;

- (NSString *)identifier;
- (void)setIdentifier:(NSString *)identifier;

- (NSString *)type;
- (BOOL)isReadOnly;
- (void)setReadOnly:(BOOL)flag;

- (NSDictionary *)metadata;
- (void)setMetadata:(NSDictionary *)storeMetadata;

- (void)didAddToPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator;
- (void)willRemoveFromPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator;

@end

/* The coordinator tells a store its type when it builds it, and the model it was opened against. */
@interface NSPersistentStore (CDPrivate)
- (void)cd_setType:(NSString *)type;
- (NSManagedObjectModel *)cd_model;
@end

#endif /* COREDATA_NSPERSISTENTSTORE_H */
