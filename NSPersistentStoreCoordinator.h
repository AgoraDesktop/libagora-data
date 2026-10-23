/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSPersistentStoreCoordinator — the object that owns the stores, answers for their metadata, and is the only
 * thing that turns an object into a row. W4 of COREDATA-PLAN.md §12, and the other half of the protocol W3
 * declared (`CDStoreDoors`).
 *
 * THE STORE TYPES ARE A REGISTRY, NOT A SWITCH. `+registerStoreClass:forStoreType:` is a 10.5 door and it is the
 * point: a store type is a class someone registered, which is why adding the SQLite store in W7 is a registration
 * rather than an edit here. On 10.6 exactly one of the four types is implemented — `NSInMemoryStoreType`, which is
 * also the conformance reference every other store is measured against. The other three refuse by name and say
 * which wave fills them in, which is D1-b's rule applied to types instead of files.
 *
 * THE CONSTANTS ARE APPLE'S STRINGS, INCLUDING THE ONES NOTHING USES YET. A client that passes
 * `NSMigratePersistentStoresAutomaticallyOption` must get the same string macOS would, and a client that passes
 * `NSExternalRecordsDirectoryOption` gets a refusal naming D4 (§7.6) rather than a silent ignore.
 */

#ifndef COREDATA_NSPERSISTENTSTORECOORDINATOR_H
#define COREDATA_NSPERSISTENTSTORECOORDINATOR_H

#import <Foundation/Foundation.h>
#import <CoreData/CoreDataDefines.h>

@class NSArray;
@class NSDictionary;
@class NSError;
@class NSManagedObjectID;
@class NSManagedObjectModel;
@class NSPersistentStore;
@class NSURL;

COREDATA_EXTERN NSString *const NSSQLiteStoreType;
COREDATA_EXTERN NSString *const NSXMLStoreType;
COREDATA_EXTERN NSString *const NSBinaryStoreType;
COREDATA_EXTERN NSString *const NSInMemoryStoreType;

COREDATA_EXTERN NSString *const NSStoreTypeKey;
COREDATA_EXTERN NSString *const NSStoreUUIDKey;
COREDATA_EXTERN NSString *const NSStoreModelVersionHashesKey;
COREDATA_EXTERN NSString *const NSStoreModelVersionIdentifiersKey;
COREDATA_EXTERN NSString *const NSStorePathKey;
COREDATA_EXTERN NSString *const NSStoreUUIDInPathKey;
COREDATA_EXTERN NSString *const NSEntityNameInPathKey;
COREDATA_EXTERN NSString *const NSModelPathKey;
COREDATA_EXTERN NSString *const NSObjectURIKey;
COREDATA_EXTERN NSString *const NSPersistentStoreOSCompatibility;

COREDATA_EXTERN NSString *const NSPersistentStoreCoordinatorStoresDidChangeNotification;
COREDATA_EXTERN NSString *const NSPersistentStoreCoordinatorWillRemoveStoreNotification;
COREDATA_EXTERN NSString *const NSAddedPersistentStoresKey;
COREDATA_EXTERN NSString *const NSRemovedPersistentStoresKey;
COREDATA_EXTERN NSString *const NSUUIDChangedPersistentStoresKey;

COREDATA_EXTERN NSString *const NSReadOnlyPersistentStoreOption;
COREDATA_EXTERN NSString *const NSValidateXMLStoreOption;
COREDATA_EXTERN NSString *const NSPersistentStoreTimeoutOption;
COREDATA_EXTERN NSString *const NSSQLitePragmasOption;
COREDATA_EXTERN NSString *const NSSQLiteAnalyzeOption;
COREDATA_EXTERN NSString *const NSSQLiteManualVacuumOption;
COREDATA_EXTERN NSString *const NSIgnorePersistentStoreVersioningOption;
COREDATA_EXTERN NSString *const NSMigratePersistentStoresAutomaticallyOption;
COREDATA_EXTERN NSString *const NSInferMappingModelAutomaticallyOption;

COREDATA_EXTERN NSString *const NSXMLExternalRecordType;
COREDATA_EXTERN NSString *const NSBinaryExternalRecordType;
COREDATA_EXTERN NSString *const NSExternalRecordsFileFormatOption;
COREDATA_EXTERN NSString *const NSExternalRecordsDirectoryOption;
COREDATA_EXTERN NSString *const NSExternalRecordExtensionOption;

@interface NSPersistentStoreCoordinator : NSObject <NSLocking>
{
	NSManagedObjectModel *_model;		/* retained */
	NSMutableArray *_stores;
	NSRecursiveLock *_lock;
}

+ (NSDictionary *)registeredStoreTypes;
+ (void)registerStoreClass:(Class)storeClass forStoreType:(NSString *)storeType;
+ (NSDictionary *)metadataForPersistentStoreOfType:(NSString *)storeType
                                               URL:(NSURL *)url
                                             error:(NSError **)error;
+ (BOOL)setMetadata:(NSDictionary *)metadata
    forPersistentStoreOfType:(NSString *)storeType
                          URL:(NSURL *)url
                        error:(NSError **)error;
+ (NSDictionary *)elementsDerivedFromExternalRecordURL:(NSURL *)fileURL;

- (id)initWithManagedObjectModel:(NSManagedObjectModel *)model;
- (NSManagedObjectModel *)managedObjectModel;

- (NSArray *)persistentStores;
- (NSPersistentStore *)persistentStoreForURL:(NSURL *)URL;
- (NSURL *)URLForPersistentStore:(NSPersistentStore *)store;
- (BOOL)setURL:(NSURL *)url forPersistentStore:(NSPersistentStore *)store;

- (NSPersistentStore *)addPersistentStoreWithType:(NSString *)storeType
                                  configuration:(NSString *)configuration
                                            URL:(NSURL *)storeURL
                                        options:(NSDictionary *)options
                                          error:(NSError **)error;
- (BOOL)removePersistentStore:(NSPersistentStore *)store error:(NSError **)error;

- (void)setMetadata:(NSDictionary *)metadata forPersistentStore:(NSPersistentStore *)store;
- (NSDictionary *)metadataForPersistentStore:(NSPersistentStore *)store;

- (NSPersistentStore *)migratePersistentStore:(NSPersistentStore *)store
                                        toURL:(NSURL *)URL
                                      options:(NSDictionary *)options
                                     withType:(NSString *)storeType
                                        error:(NSError **)error;
- (NSPersistentStore *)importStoreWithIdentifier:(NSString *)storeIdentifier
                     fromExternalRecordsDirectory:(NSURL *)externalRecordsURL
                                           toURL:(NSURL *)destinationURL
                                         options:(NSDictionary *)options
                                        withType:(NSString *)storeType
                                           error:(NSError **)error;
- (NSManagedObjectID *)managedObjectIDForURIRepresentation:(NSURL *)url;

- (void)lock;
- (void)unlock;
- (BOOL)tryLock;

@end

#endif /* COREDATA_NSPERSISTENTSTORECOORDINATOR_H */
