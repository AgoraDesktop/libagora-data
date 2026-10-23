/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSAtomicStore.m — the node cache, once, for every store that subclasses it.
 *
 * THE FOUR REFERENCE-OBJECT DOORS ARE THE SUBCLASS'S, and this class only composes them: `-newReferenceObject…`
 * picks a key, `-objectIDForEntity:referenceObject:` mints the ID, `-referenceObjectForObjectID:` reads it back.
 * A store that keys by NSNumber and one that keys by a string both work, because nothing here interprets the key.
 */

#import <CoreData/NSAtomicStore.h>
#import <CoreData/NSAtomicStoreCacheNode.h>
#import <CoreData/NSManagedObject.h>
#import <CoreData/NSManagedObjectID.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSPropertyDescription.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSSet.h>

@implementation NSAtomicStore

- (id)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator
                       configurationName:(NSString *)configurationName
                                     URL:(NSURL *)url
                                 options:(NSDictionary *)options
{
	self = [super initWithPersistentStoreCoordinator:coordinator
	                               configurationName:configurationName
	                                             URL:url
	                                         options:options];
	if (self != nil) {
		_cacheNodes = [[NSMutableDictionary alloc] init];
		_referenceCounters = [[NSMutableDictionary alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_cacheNodes release];
	[_referenceCounters release];
	[super dealloc];
}

/* THE BASE STORE LOADS AND SAVES NOTHING, which is exactly right for a store whose contents are the nodes: the
 * in-memory store overrides neither, and a serialising store overrides both. */
- (BOOL)load:(NSError **)error { (void)error; return YES; }
- (BOOL)save:(NSError **)error { (void)error; return YES; }

- (NSAtomicStoreCacheNode *)newCacheNodeForManagedObject:(NSManagedObject *)managedObject
{
	NSAtomicStoreCacheNode *node = [[NSAtomicStoreCacheNode alloc] initWithObjectID:[managedObject objectID]];
	[self updateCacheNode:node fromManagedObject:managedObject];
	return node;	/* the caller owns it, as the "new" prefix says */
}

- (void)updateCacheNode:(NSAtomicStoreCacheNode *)node fromManagedObject:(NSManagedObject *)managedObject
{
	NSArray *properties = [[managedObject entity] properties];
	NSUInteger i;

	for (i = 0; i < [properties count]; i++) {
		NSString *key = [[properties objectAtIndex:i] name];
		/* TRANSIENT PROPERTIES ARE NOT STORED, which is the one flag a store must honour or the model is a lie. */
		if ([[properties objectAtIndex:i] isTransient]) {
			continue;
		}
		[node setValue:[managedObject primitiveValueForKey:key] forKey:key];
	}
}

- (NSSet *)cacheNodes { return [NSSet setWithArray:[_cacheNodes allValues]]; }

- (void)addCacheNodes:(NSSet *)cacheNodes
{
	NSArray *all = [cacheNodes allObjects];
	NSUInteger i;

	for (i = 0; i < [all count]; i++) {
		NSAtomicStoreCacheNode *node = [all objectAtIndex:i];
		[_cacheNodes setObject:node forKey:[node objectID]];
	}
}

- (void)willRemoveCacheNodes:(NSSet *)cacheNodes
{
	NSArray *all = [cacheNodes allObjects];
	NSUInteger i;

	for (i = 0; i < [all count]; i++) {
		[_cacheNodes removeObjectForKey:[[all objectAtIndex:i] objectID]];
	}
}

- (NSAtomicStoreCacheNode *)cacheNodeForObjectID:(NSManagedObjectID *)objectID
{
	return [_cacheNodes objectForKey:objectID];
}

- (NSManagedObjectID *)objectIDForEntity:(NSEntityDescription *)entity referenceObject:(id)data
{
	return [[[NSManagedObjectID alloc] initWithEntity:entity
	                                  persistentStore:self
	                                      primaryKey:data
	                                       temporary:NO] autorelease];
}

- (id)newReferenceObjectForManagedObject:(NSManagedObject *)managedObject
{
	NSString *entityName = [[managedObject entity] name];
	NSNumber *last = [_referenceCounters objectForKey:entityName];
	NSInteger next = ([last integerValue] + 1);

	[_referenceCounters setObject:[NSNumber numberWithInteger:next] forKey:entityName];
	return [NSNumber numberWithInteger:next];
}

- (id)referenceObjectForObjectID:(NSManagedObjectID *)objectID
{
	return [objectID primaryKey];
}

@end
