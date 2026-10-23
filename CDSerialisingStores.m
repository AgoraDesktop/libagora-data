/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * CDSerialisingStores.m — the keyed-archive store and the XML-plist store, over one node-graph writer.
 *
 * THE FORMAT IS `{ metadata: {...}, nodes: [ { entity, key, values } ] }`, and it is deliberately the SAME for both,
 * because a binary store and an XML store differ in how they encode a tree and not in what a store is. That is the
 * `NSAtomicStore` contract paying for itself (§7.3): W4 wrote the node cache once, and W7 adds two serialisers.
 *
 * METADATA IS READ BEFORE ANY NODE, and the version hashes decide whether the file may be opened at all. That is
 * D1-b: the hash is this library's digest, so an Apple-authored store fails here — with
 * `NSPersistentStoreIncompatibleVersionHashError` — instead of being half-read.
 */

#import <CoreData/CDSerialisingStores.h>
#import <CoreData/NSPersistentStore.h>
#import <CoreData/NSPersistentStoreCoordinator.h>
#import <CoreData/NSAtomicStoreCacheNode.h>
#import <CoreData/NSManagedObjectID.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSManagedObjectModel.h>
#import <CoreData/CoreDataErrors.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSData.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSError.h>
#import <Foundation/NSKeyedArchiver.h>
#import <Foundation/NSPropertyListSerialization.h>

static NSError *CDStoreFileError(NSInteger code, NSString *why)
{
	return [NSError errorWithDomain:@"NSCocoaErrorDomain" code:code
	                      userInfo:[NSDictionary dictionaryWithObject:why forKey:@"reason"]];
}

@implementation CDSerialisingStore

- (NSDictionary *)cd_storeDictionary
{
	NSMutableArray *nodes = [[NSMutableArray alloc] init];
	NSArray *all = [[self cacheNodes] allObjects];
	NSUInteger i;

	for (i = 0; i < [all count]; i++) {
		NSAtomicStoreCacheNode *node = [all objectAtIndex:i];
		NSMutableDictionary *entry = [[NSMutableDictionary alloc] init];

		[entry setObject:[[[node objectID] entity] name] forKey:@"entity"];
		[entry setObject:([[node objectID] primaryKey] != nil) ? [[node objectID] primaryKey] : (id)[NSNumber numberWithInt:0]
		          forKey:@"key"];
		[entry setObject:[node propertyCache] forKey:@"values"];
		[nodes addObject:entry];
		[entry release];
	}
	{
		NSDictionary *store = [NSDictionary dictionaryWithObjectsAndKeys:
		                       ([self metadata] != nil) ? [self metadata] : (id)[NSDictionary dictionary], @"metadata",
		                       nodes, @"nodes", nil];
		[nodes release];
		return store;
	}
}

- (void)cd_loadStoreDictionary:(NSDictionary *)dictionary
{
	NSArray *entries = [dictionary objectForKey:@"nodes"];
	NSDictionary *entities = [[self cd_model] entitiesByName];
	NSUInteger i;

	for (i = 0; i < [entries count]; i++) {
		NSDictionary *entry = [entries objectAtIndex:i];
		NSEntityDescription *entity = [entities objectForKey:[entry objectForKey:@"entity"]];
		NSManagedObjectID *objectID;
		NSAtomicStoreCacheNode *node;

		if (entity == nil) {
			/* AN ENTITY THE MODEL NO LONGER HAS IS SKIPPED, NOT INVENTED: it is what the migration machinery
			 * exists to deal with, and a node for it would be a row nothing can name. */
			continue;
		}
		if (![self cd_entityInConfiguration:entity]) {
			/* AND AN ENTITY OUTSIDE THIS STORE'S CONFIGURATION IS NOT LOADED, which is what a configuration is
			 * FOR: two stores over one file, each seeing its own half of the model (§7.5). */
			continue;
		}
		objectID = [self objectIDForEntity:entity referenceObject:[entry objectForKey:@"key"]];
		node = [[NSAtomicStoreCacheNode alloc] initWithObjectID:objectID];
		[node setPropertyCache:[entry objectForKey:@"values"]];
		[self addCacheNodes:[NSSet setWithObject:node]];
		[node release];
	}
}

- (NSData *)cd_serialise:(NSDictionary *)dictionary error:(NSError **)error
{
	(void)dictionary; (void)error;
	return nil;	/* a subclass supplies this */
}

- (NSDictionary *)cd_deserialise:(NSData *)data error:(NSError **)error
{
	(void)data; (void)error;
	return nil;
}

/* THE METADATA DOOR RUNS BEFORE `-load:`, so this is where a file's identity is checked. */
- (BOOL)loadMetadata:(NSError **)error
{
	NSData *data = ([[self URL] path] != nil) ? [NSData dataWithContentsOfFile:[[self URL] path]] : nil;

	if (data == nil || [data length] == 0) {
		return [super loadMetadata:error];	/* a new file: super creates the metadata */
	}
	{
		NSDictionary *stored = [self cd_deserialise:data error:error];
		NSDictionary *metadata = [stored objectForKey:@"metadata"];

		if (metadata == nil) {
			if (error != NULL) {
				*error = CDStoreFileError(NSPersistentStoreIncompatibleSchemaError,
				                          @"the file has no store metadata");
			}
			return NO;
		}
		/* THE COMPATIBILITY TEST IS THE MODEL'S, not this class's: it already knows that a missing entity is an
		 * incompatibility rather than a skip. */
		if ([self cd_model] != nil && ![[self cd_model] isConfiguration:[self configurationName]
		                                     compatibleWithStoreMetadata:metadata]) {
			if (error != NULL) {
				*error = CDStoreFileError(NSPersistentStoreIncompatibleVersionHashError,
				    @"the store's model version hashes do not match this model (COREDATA-PLAN.md D1-b)");
			}
			return NO;
		}
		[self setMetadata:metadata];
		[self setIdentifier:[metadata objectForKey:NSStoreUUIDKey]];
		return YES;
	}
}

- (BOOL)load:(NSError **)error
{
	NSData *data = ([[self URL] path] != nil) ? [NSData dataWithContentsOfFile:[[self URL] path]] : nil;

	if (data == nil || [data length] == 0) {
		return YES;	/* nothing on disk yet: an empty store */
	}
	{
		NSDictionary *stored = [self cd_deserialise:data error:error];
		if (stored == nil) {
			return NO;
		}
		[self cd_loadStoreDictionary:stored];
		return YES;
	}
}

- (BOOL)save:(NSError **)error
{
	NSData *data;

	if ([self isReadOnly]) {
		if (error != NULL) {
			*error = CDStoreFileError(NSPersistentStoreOperationError, @"the store is read-only");
		}
		return NO;
	}
	data = [self cd_serialise:[self cd_storeDictionary] error:error];
	if (data == nil) {
		return NO;
	}
	if (![data writeToFile:[[self URL] path] atomically:YES]) {
		if (error != NULL) {
			*error = CDStoreFileError(NSPersistentStoreSaveError,
			                          [NSString stringWithFormat:@"could not write %@", [[self URL] path]]);
		}
		return NO;
	}
	return YES;
}

+ (NSDictionary *)cd_metadataAtURL:(NSURL *)url error:(NSError **)error
{
	/* THE FILE IS READ WITH A THROWAWAY INSTANCE, because the serialiser is an instance method and the point of this
	 * door is that there is no stack yet. It is deallocated immediately; nothing is registered anywhere. */
	CDSerialisingStore *probe = [[self alloc] initWithPersistentStoreCoordinator:nil
	                                                          configurationName:nil
	                                                                        URL:url
	                                                                    options:nil];
	NSData *data = ([[url path] length] > 0) ? [NSData dataWithContentsOfFile:[url path]] : nil;
	NSDictionary *stored = nil;

	if (data != nil && [data length] > 0) {
		stored = [probe cd_deserialise:data error:error];
	}
	[probe release];
	return [stored objectForKey:@"metadata"];
}

@end

/* ---- the two serialisers ------------------------------------------------------------------------- */

@implementation CDBinaryStore

- (NSData *)cd_serialise:(NSDictionary *)dictionary error:(NSError **)error
{
	(void)error;
	return [NSKeyedArchiver archivedDataWithRootObject:dictionary];
}

- (NSDictionary *)cd_deserialise:(NSData *)data error:(NSError **)error
{
	id decoded = [NSKeyedUnarchiver unarchiveObjectWithData:data];

	if (![decoded isKindOfClass:[NSDictionary class]]) {
		if (error != NULL) {
			*error = CDStoreFileError(NSPersistentStoreIncompatibleSchemaError,
			                          @"the file is not an archived store");
		}
		return nil;
	}
	return decoded;
}

@end

@implementation CDXMLStore

- (NSData *)cd_serialise:(NSDictionary *)dictionary error:(NSError **)error
{
	/* AN XML PROPERTY LIST IS PARSEABLE XML, which is what `NSXMLStoreType` promises, and it carries the value
	 * TYPES — a store that wrote numbers as text would need a type table, and the plist writer already has one. */
	return [NSPropertyListSerialization dataWithPropertyList:dictionary
	                                                  format:NSPropertyListXMLFormat_v1_0
	                                                 options:0
	                                                   error:error];
}

- (NSDictionary *)cd_deserialise:(NSData *)data error:(NSError **)error
{
	NSPropertyListFormat format = NSPropertyListXMLFormat_v1_0;
	id decoded = [NSPropertyListSerialization propertyListWithData:data options:NSPropertyListImmutable
	                                                        format:&format error:error];

	if (![decoded isKindOfClass:[NSDictionary class]]) {
		if (error != NULL) {
			*error = CDStoreFileError(NSPersistentStoreIncompatibleSchemaError,
			                          @"the file is not a property list");
		}
		return nil;
	}
	/* `NSValidateXMLStoreOption` IS HONOURED HERE: re-serialising what was parsed proves the tree is well formed and
	 * writable, which is the only validation an XML store can perform without a schema. */
	if ([[self options] objectForKey:NSValidateXMLStoreOption] != nil) {
		NSData *again = [NSPropertyListSerialization dataWithPropertyList:decoded
		                                                           format:NSPropertyListXMLFormat_v1_0
		                                                          options:0 error:error];
		if (again == nil) {
			return nil;
		}
	}
	return decoded;
}

@end
