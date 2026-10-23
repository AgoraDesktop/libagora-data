/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSPersistentStoreCoordinator.m — the store registry, the metadata doors, and W3's `CDStoreDoors` implemented.
 *
 * THE FIRST STORE IS THE IN-MEMORY ONE, AND IT IS THE CONFORMANCE REFERENCE (§7.2). It is a genuine
 * `NSAtomicStore` — nodes, reference objects, `-load:`/`-save:` — so the object graph, the save pipeline and
 * faulting are exercised against the same contract the SQLite store will have to honour, with no file format in
 * the way. W7 adds serialisation; it does not add the store protocol.
 *
 * WHAT THE COORDINATOR DOES ON A SAVE IS THE WHOLE POINT OF THE WAVE: temporary IDs become permanent ones, the
 * row is written as a cache node, and the object's snapshot is adopted from what was written. After that a
 * `-objectWithID:` on a fresh context can name a row, which is the first time in this plan that an ID has meant
 * anything.
 */

#import <CoreData/NSPersistentStoreCoordinator.h>
#import <CoreData/NSPersistentStore.h>
#import <CoreData/NSAtomicStore.h>
#import <CoreData/NSAtomicStoreCacheNode.h>
#import <CoreData/NSManagedObjectModel.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/NSManagedObject.h>
#import <CoreData/NSManagedObjectID.h>
#import <CoreData/NSManagedObjectContext.h>
#import <CoreData/CoreDataErrors.h>
#import <CoreData/CDModelPrivate.h>
#import <CoreData/CDFetchEngine.h>
#import <CoreData/CDSerialisingStores.h>
#import <CoreData/NSFetchRequest.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSError.h>
#import <Foundation/NSNotification.h>
#import <Foundation/NSNotificationCenter.h>
#import <Foundation/NSLock.h>

NSString *const NSSQLiteStoreType = @"SQLite";
NSString *const NSXMLStoreType = @"XML";
NSString *const NSBinaryStoreType = @"Binary";
NSString *const NSInMemoryStoreType = @"InMemory";

NSString *const NSStoreTypeKey = @"NSStoreType";
NSString *const NSStoreUUIDKey = @"NSStoreUUID";
NSString *const NSStoreModelVersionHashesKey = @"NSStoreModelVersionHashes";
NSString *const NSStoreModelVersionIdentifiersKey = @"NSStoreModelVersionIdentifiers";
NSString *const NSStorePathKey = @"NSStorePath";
NSString *const NSStoreUUIDInPathKey = @"NSStoreUUIDInPath";
NSString *const NSEntityNameInPathKey = @"NSEntityNameInPath";
NSString *const NSModelPathKey = @"NSModelPath";
NSString *const NSObjectURIKey = @"NSObjectURI";
NSString *const NSPersistentStoreOSCompatibility = @"NSPersistentStoreOSCompatibility";

NSString *const NSPersistentStoreCoordinatorStoresDidChangeNotification =
    @"NSPersistentStoreCoordinatorStoresDidChangeNotification";
NSString *const NSPersistentStoreCoordinatorWillRemoveStoreNotification =
    @"NSPersistentStoreCoordinatorWillRemoveStoreNotification";
NSString *const NSAddedPersistentStoresKey = @"NSAddedPersistentStores";
NSString *const NSRemovedPersistentStoresKey = @"NSRemovedPersistentStores";
NSString *const NSUUIDChangedPersistentStoresKey = @"NSUUIDChangedPersistentStores";

NSString *const NSReadOnlyPersistentStoreOption = @"NSReadOnlyPersistentStoreOption";
NSString *const NSValidateXMLStoreOption = @"NSValidateXMLStoreOption";
NSString *const NSPersistentStoreTimeoutOption = @"NSPersistentStoreTimeoutOption";
NSString *const NSSQLitePragmasOption = @"NSSQLitePragmasOption";
NSString *const NSSQLiteAnalyzeOption = @"NSSQLiteAnalyzeOption";
NSString *const NSSQLiteManualVacuumOption = @"NSSQLiteManualVacuumOption";
NSString *const NSIgnorePersistentStoreVersioningOption = @"NSIgnorePersistentStoreVersioningOption";
NSString *const NSMigratePersistentStoresAutomaticallyOption = @"NSMigratePersistentStoresAutomaticallyOption";
NSString *const NSInferMappingModelAutomaticallyOption = @"NSInferMappingModelAutomaticallyOption";

NSString *const NSXMLExternalRecordType = @"XML";
NSString *const NSBinaryExternalRecordType = @"Binary";
NSString *const NSExternalRecordsFileFormatOption = @"NSExternalRecordsFileFormat";
NSString *const NSExternalRecordsDirectoryOption = @"NSExternalRecordsDirectory";
NSString *const NSExternalRecordExtensionOption = @"NSExternalRecordExtension";

static NSMutableDictionary *CDStoreRegistry = nil;

static NSError *CDCoordinatorError(NSInteger code, NSString *why)
{
	return [NSError errorWithDomain:@"NSCocoaErrorDomain" code:code
	                      userInfo:[NSDictionary dictionaryWithObject:why forKey:@"reason"]];
}

/* The values a save writes, gathered from the object's primitive doors. */
static NSDictionary *CDValuesOfObject(NSManagedObject *object)
{
	NSMutableDictionary *values = [[NSMutableDictionary alloc] init];
	NSArray *properties = [[[object entity] propertiesByName] allValues];
	NSUInteger i;

	for (i = 0; i < [properties count]; i++) {
		NSString *key = [[properties objectAtIndex:i] name];
		id value = [object primitiveValueForKey:key];
		if (value != nil && ![[properties objectAtIndex:i] isTransient]) {
			[values setObject:value forKey:key];
		}
	}
	return [values autorelease];
}

/* ---- the in-memory store ------------------------------------------------------------------------- */

@interface CDInMemoryStore : NSAtomicStore
@end

@implementation CDInMemoryStore
/* NOTHING TO LOAD AND NOTHING TO WRITE: the nodes ARE the contents, which is what makes this the reference. */
- (BOOL)load:(NSError **)error { (void)error; return YES; }
- (BOOL)save:(NSError **)error { (void)error; return YES; }
@end

@implementation NSPersistentStoreCoordinator

+ (void)initialize
{
	if (self == [NSPersistentStoreCoordinator class]) {
		CDStoreRegistry = [[NSMutableDictionary alloc] init];
		[self registerStoreClass:[CDInMemoryStore class] forStoreType:NSInMemoryStoreType];
		[self registerStoreClass:[CDBinaryStore class] forStoreType:NSBinaryStoreType];
		[self registerStoreClass:[CDXMLStore class] forStoreType:NSXMLStoreType];
		[self registerStoreClass:[CDSQLiteStore class] forStoreType:NSSQLiteStoreType];
	}
}

+ (NSDictionary *)registeredStoreTypes
{
	return [[CDStoreRegistry copy] autorelease];
}

+ (void)registerStoreClass:(Class)storeClass forStoreType:(NSString *)storeType
{
	if (storeClass == Nil || storeType == nil) {
		return;
	}
	[CDStoreRegistry setObject:storeClass forKey:storeType];
}

+ (NSDictionary *)metadataForPersistentStoreOfType:(NSString *)storeType
                                               URL:(NSURL *)url
                                             error:(NSError **)error
{
	Class storeClass = [CDStoreRegistry objectForKey:storeType];

	/* THE METADATA IS READ WITHOUT OPENING A STACK — that is the door's whole purpose, and it is why the store
	 * classes answer it as a CLASS method. An in-memory store has no file, and a file with no metadata is nil with
	 * no error, which is the documented "nothing there yet". */
	if (storeClass == Nil || url == nil) {
		return nil;
	}
	if ([storeClass respondsToSelector:@selector(cd_metadataAtURL:error:)]) {
		return [storeClass cd_metadataAtURL:url error:error];
	}
	return nil;
}

+ (BOOL)setMetadata:(NSDictionary *)metadata
    forPersistentStoreOfType:(NSString *)storeType
                          URL:(NSURL *)url
                        error:(NSError **)error
{
	(void)metadata; (void)storeType; (void)url;
	/* REFUSED BY NAME: the metadata carries the model's version hashes, so letting a caller overwrite it without a
	 * model would let them forge compatibility. A store writes its own metadata on save, from the model it was
	 * opened against. */
	if (error != NULL) {
		*error = CDCoordinatorError(NSPersistentStoreOperationError,
		                            @"metadata is written by the store from the model it was opened against; "
		                            @"overwriting it without a model would forge compatibility");
	}
	return NO;
}

+ (NSDictionary *)metadataForPersistentStoreWithURL:(NSURL *)url error:(NSError **)error
{
	return [self metadataForPersistentStoreOfType:nil URL:url error:error];
}

+ (NSDictionary *)elementsDerivedFromExternalRecordURL:(NSURL *)fileURL
{
	(void)fileURL;
	/* D4 (§7.6): refused, not ignored. */
	return nil;
}

/* ---- lifecycle ----------------------------------------------------------------------------------- */

- (id)init
{
	return [self initWithManagedObjectModel:[[[NSManagedObjectModel alloc] init] autorelease]];
}

- (id)initWithManagedObjectModel:(NSManagedObjectModel *)model
{
	self = [super init];
	if (self != nil) {
		_model = [model retain];
		_stores = [[NSMutableArray alloc] init];
		_lock = [[NSRecursiveLock alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_model release];
	[_stores release];
	[_lock release];
	[super dealloc];
}

- (NSManagedObjectModel *)managedObjectModel { return _model; }

- (void)lock { [_lock lock]; }
- (void)unlock { [_lock unlock]; }
- (BOOL)tryLock { return [_lock tryLock]; }

/* ---- stores -------------------------------------------------------------------------------------- */

- (NSArray *)persistentStores { return [[_stores copy] autorelease]; }

- (NSPersistentStore *)persistentStoreForURL:(NSURL *)URL
{
	NSUInteger i;

	for (i = 0; i < [_stores count]; i++) {
		NSPersistentStore *store = [_stores objectAtIndex:i];
		if ([[store URL] isEqual:URL]) {
			return store;
		}
	}
	return nil;
}

- (NSURL *)URLForPersistentStore:(NSPersistentStore *)store { return [store URL]; }

- (BOOL)setURL:(NSURL *)url forPersistentStore:(NSPersistentStore *)store
{
	if (store == nil || url == nil) {
		return NO;
	}
	[store setURL:url];
	return YES;
}

- (NSPersistentStore *)addPersistentStoreWithType:(NSString *)storeType
                                  configuration:(NSString *)configuration
                                            URL:(NSURL *)storeURL
                                        options:(NSDictionary *)options
                                          error:(NSError **)error
{
	Class storeClass = [CDStoreRegistry objectForKey:storeType];
	NSPersistentStore *store;
	NSDictionary *info;

	if (storeClass == Nil) {
		/* EACH MISSING TYPE NAMES ITS WAVE, because a caller that asked for SQLite and got "invalid type" would
		 * have no way to tell a typo from a plan. */
		NSString *where = @"this build registers no class for it";
		if (error != NULL) {
			*error = CDCoordinatorError(NSPersistentStoreInvalidTypeError,
			    [NSString stringWithFormat:@"the store type `%@` is not registered; %@ (COREDATA-PLAN.md)",
			                               storeType, where]);
		}
		return nil;
	}
	store = [[storeClass alloc] initWithPersistentStoreCoordinator:self
	                                             configurationName:configuration
	                                                           URL:storeURL
	                                                       options:options];
	[store cd_setType:storeType];
	if (![store loadMetadata:error]) {
		[store release];
		return nil;
	}
	/* AND THE STORE'S CONTENTS ARE LOADED AFTER ITS METADATA, which is the order `NSAtomicStore` documents: the
	 * metadata decides whether the file may be read at all, and only then are its nodes worth building. This call
	 * was missing until W7's suite read back zero rows from a store that had written them — the write path worked,
	 * and nothing ever asked the file anything. */
	if ([store isKindOfClass:[NSAtomicStore class]] && ![store load:error]) {
		[store release];
		return nil;
	}
	[_stores addObject:store];
	[store didAddToPersistentStoreCoordinator:self];
	info = [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:store]
	                                   forKey:NSAddedPersistentStoresKey];
	[[NSNotificationCenter defaultCenter] postNotificationName:NSPersistentStoreCoordinatorStoresDidChangeNotification
	                                                    object:self
	                                                  userInfo:info];
	return [store autorelease];
}

- (BOOL)removePersistentStore:(NSPersistentStore *)store error:(NSError **)error
{
	NSDictionary *info;

	if (store == nil) {
		if (error != NULL) {
			*error = CDCoordinatorError(NSPersistentStoreOperationError, @"no store to remove");
		}
		return NO;
	}
	[[NSNotificationCenter defaultCenter] postNotificationName:NSPersistentStoreCoordinatorWillRemoveStoreNotification
	                                                    object:self
	                                                  userInfo:[NSDictionary dictionaryWithObject:store
	                                                                                       forKey:NSRemovedPersistentStoresKey]];
	[store willRemoveFromPersistentStoreCoordinator:self];
	info = [NSDictionary dictionaryWithObject:[NSArray arrayWithObject:store]
	                                   forKey:NSRemovedPersistentStoresKey];
	[store retain];
	[_stores removeObject:store];
	[[NSNotificationCenter defaultCenter] postNotificationName:NSPersistentStoreCoordinatorStoresDidChangeNotification
	                                                    object:self
	                                                  userInfo:info];
	[store release];
	return YES;
}

- (void)setMetadata:(NSDictionary *)metadata forPersistentStore:(NSPersistentStore *)store
{
	[store setMetadata:metadata];
}

- (NSDictionary *)metadataForPersistentStore:(NSPersistentStore *)store { return [store metadata]; }

/* ---- the two doors that belong to later waves ----------------------------------------------------- */

- (NSPersistentStore *)migratePersistentStore:(NSPersistentStore *)store
                                        toURL:(NSURL *)URL
                                      options:(NSDictionary *)options
                                     withType:(NSString *)storeType
                                        error:(NSError **)error
{
	(void)store; (void)URL; (void)options; (void)storeType;
	if (error != NULL) {
		*error = CDCoordinatorError(NSPersistentStoreOperationError,
		                            @"migration arrives in COREDATA-PLAN.md W6");
	}
	return nil;
}

- (NSPersistentStore *)importStoreWithIdentifier:(NSString *)storeIdentifier
                     fromExternalRecordsDirectory:(NSURL *)externalRecordsURL
                                           toURL:(NSURL *)destinationURL
                                         options:(NSDictionary *)options
                                        withType:(NSString *)storeType
                                           error:(NSError **)error
{
	(void)storeIdentifier; (void)externalRecordsURL; (void)destinationURL; (void)options; (void)storeType;
	/* D4 (§7.6): external records are refused, with the refusal named rather than the option ignored. */
	if (error != NULL) {
		*error = CDCoordinatorError(NSPersistentStoreOperationError,
		                            @"external records are refused (COREDATA-PLAN.md D4): no external record "
		                            @"indexer on this platform");
	}
	return nil;
}

- (NSManagedObjectID *)managedObjectIDForURIRepresentation:(NSURL *)url
{
	NSString *path = [url absoluteString];
	NSArray *parts;

	/* `x-coredata://<store>/<Entity>/<p|t><key>` — the store component is skipped because a coordinator's stores
	 * are the ones it owns, and the entity is resolved through the model it holds. */
	if (![path hasPrefix:@"x-coredata://"]) {
		return nil;
	}
	parts = [[path substringFromIndex:[@"x-coredata://" length]] componentsSeparatedByString:@"/"];
	if ([parts count] < 3) {
		return nil;
	}
	{
		NSString *entityName = [parts objectAtIndex:1];
		NSString *keyText = [parts objectAtIndex:2];
		BOOL temporary = [keyText hasPrefix:@"t"];
		NSString *digits = temporary ? [keyText substringFromIndex:1] : [keyText substringFromIndex:1];
		NSEntityDescription *entity = [[_model entitiesByName] objectForKey:entityName];

		if (entity == nil) {
			return nil;
		}
		return [[[NSManagedObjectID alloc] initWithEntity:entity
		                                  persistentStore:([_stores count] > 0) ? [_stores objectAtIndex:0] : nil
		                                      primaryKey:[NSNumber numberWithInteger:[digits integerValue]]
		                                       temporary:temporary] autorelease];
	}
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<NSPersistentStoreCoordinator: %lu stores>",
	         (unsigned long)[_stores count]];
}

/* ---- CDStoreDoors: what W3 asks of a store -------------------------------------------------------- */

- (void)cd_faultObject:(NSManagedObject *)object inContext:(NSManagedObjectContext *)context
{
	NSPersistentStore *store = ([_stores count] > 0) ? [_stores objectAtIndex:0] : nil;
	NSAtomicStoreCacheNode *node;

	(void)context;
	if (store == nil) {
		return;
	}
	node = [(NSAtomicStore *)store cacheNodeForObjectID:[object objectID]];
	if (node != nil) {
		[object cd_applyCommittedValues:[node propertyCache]];
	}
}

- (BOOL)cd_obtainPermanentIDsForObjects:(NSArray *)objects
                             inContext:(NSManagedObjectContext *)context
                                 error:(NSError **)error
{
	NSPersistentStore *store = ([_stores count] > 0) ? [_stores objectAtIndex:0] : nil;
	NSUInteger i;

	(void)context;
	if (store == nil) {
		if (error != NULL) {
			*error = CDCoordinatorError(NSPersistentStoreOperationError, @"no persistent store is attached");
		}
		return NO;
	}
	for (i = 0; i < [objects count]; i++) {
		NSManagedObject *object = [objects objectAtIndex:i];
		if (![[object objectID] isTemporaryID]) {
			continue;
		}
		{
			id reference = [(NSAtomicStore *)store newReferenceObjectForManagedObject:object];
			NSManagedObjectID *permanent = [(NSAtomicStore *)store objectIDForEntity:[object entity]
			                                                       referenceObject:reference];
			[object cd_setObjectID:permanent];
		}
	}
	return YES;
}

- (BOOL)cd_saveContext:(NSManagedObjectContext *)context error:(NSError **)error
{
	NSPersistentStore *store = ([_stores count] > 0) ? [_stores objectAtIndex:0] : nil;
	NSArray *inserted;
	NSArray *updated;
	NSArray *deleted;
	NSUInteger i;

	if (store == nil) {
		if (error != NULL) {
			*error = CDCoordinatorError(NSPersistentStoreOperationError,
			                            @"no persistent store is attached to the coordinator");
		}
		return NO;
	}
	if (![store isKindOfClass:[NSAtomicStore class]]) {
		if (error != NULL) {
			*error = CDCoordinatorError(NSPersistentStoreOperationError,
			                            @"the store is not an NSAtomicStore");
		}
		return NO;
	}

	/* PERMANENT IDS FIRST, BEFORE ANY NODE IS WRITTEN: a relationship written as a key needs the key to exist, and
	 * a node keyed by a temporary ID would be a second row for the same object. */
	if (![self cd_obtainPermanentIDsForObjects:
	          [[context insertedObjects] allObjects] inContext:context error:error]) {
		return NO;
	}

	inserted = [[context insertedObjects] allObjects];
	updated = [[context updatedObjects] allObjects];
	deleted = [[context deletedObjects] allObjects];

	for (i = 0; i < [inserted count]; i++) {
		NSManagedObject *object = [inserted objectAtIndex:i];
		NSAtomicStoreCacheNode *node = [(NSAtomicStore *)store cacheNodeForObjectID:[object objectID]];

		if (node == nil) {
			node = [(NSAtomicStore *)store newCacheNodeForManagedObject:object];
			[(NSAtomicStore *)store addCacheNodes:[NSSet setWithObject:node]];
			[node release];
		} else {
			[(NSAtomicStore *)store updateCacheNode:node fromManagedObject:object];
		}
		[object cd_applyCommittedValues:[node propertyCache]];
		[object cd_setInserted:NO];
	}
	for (i = 0; i < [updated count]; i++) {
		NSManagedObject *object = [updated objectAtIndex:i];
		NSAtomicStoreCacheNode *node = [(NSAtomicStore *)store cacheNodeForObjectID:[object objectID]];

		if (node == nil) {
			node = [(NSAtomicStore *)store newCacheNodeForManagedObject:object];
			[(NSAtomicStore *)store addCacheNodes:[NSSet setWithObject:node]];
			[node release];
		} else {
			[(NSAtomicStore *)store updateCacheNode:node fromManagedObject:object];
		}
		[object cd_applyCommittedValues:[node propertyCache]];
	}
	for (i = 0; i < [deleted count]; i++) {
		NSManagedObject *object = [deleted objectAtIndex:i];
		NSAtomicStoreCacheNode *node = [(NSAtomicStore *)store cacheNodeForObjectID:[object objectID]];

		if (node != nil) {
			[(NSAtomicStore *)store willRemoveCacheNodes:[NSSet setWithObject:node]];
		}
	}
	return [store save:error];
}

- (id)cd_executeFetchRequest:(NSFetchRequest *)request
                   inContext:(NSManagedObjectContext *)context
                       error:(NSError **)error
{
	NSPersistentStore *store = ([_stores count] > 0) ? [_stores objectAtIndex:0] : nil;

	/* THE ENGINE IS W5's AND IT RUNS HERE RATHER THAN IN THE STORE, because a fetch must see the context's pending
	 * inserts and a store has never heard of them (§8.1). */
	if (store == nil) {
		if (error != NULL) {
			*error = CDCoordinatorError(NSPersistentStoreOperationError,
			                            @"no persistent store is attached to the coordinator");
		}
		return nil;
	}
	return CDFetchExecute((NSAtomicStore *)store, context, request, error);
}

@end
