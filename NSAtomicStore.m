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
#import <CoreData/NSManagedObjectModel.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/NSRelationshipDescription.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSPredicate.h>

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
		_dirtyNodes = [[NSMutableSet alloc] init];
		_removedObjectIDs = [[NSMutableSet alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_cacheNodes release];
	[_referenceCounters release];
	[_dirtyNodes release];
	[_removedObjectIDs release];
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
	NSArray *properties = [[[managedObject entity] propertiesByName] allValues];
	NSUInteger i;

	/* AN UPDATE IS A WRITE (§0.18). The coordinator updates a node it may have READ on demand, and a lazy store
	 * saves only what is dirty — so without this an edit to a row the store had read was never written back, which
	 * is exactly the bug the lazy suite found. */
	[_dirtyNodes addObject:node];
	[_removedObjectIDs removeObject:[node objectID]];
	for (i = 0; i < [properties count]; i++) {
		NSString *key = [[properties objectAtIndex:i] name];
		NSPropertyDescription *property = [properties objectAtIndex:i];

		/* TRANSIENT PROPERTIES ARE NOT STORED, which is the one flag a store must honour or the model is a lie. */
		if ([property isTransient]) {
			continue;
		}
		/* A RELATIONSHIP IS STORED AS THE RELATED OBJECT'S IDENTITY, not as the object: a node holds scalars, and an
		 * object ID's URI form is exactly the scalar that names a row without naming an instance. To-many becomes an
		 * array of them. The coordinator resolves them back into objects when a fault fires, which is why the node
		 * format needs no type marker — the model already says which properties are relationships. */
		if ([property isKindOfClass:[NSRelationshipDescription class]]) {
			NSRelationshipDescription *relationship = (NSRelationshipDescription *)property;
			id value = [managedObject primitiveValueForKey:key];

			if ([relationship isToMany]) {
				NSArray *members = (value == nil) ? nil
				    : ([value respondsToSelector:@selector(allObjects)] ? [value allObjects]
				                                                       : [NSArray arrayWithObject:value]);
				NSMutableArray *references = [[NSMutableArray alloc] init];
				NSUInteger m;

				for (m = 0; m < [members count]; m++) {
					id member = [members objectAtIndex:m];
					if (![member isKindOfClass:[NSManagedObject class]]) { continue; }
					[references addObject:[[[member objectID] URIRepresentation] absoluteString]];
				}
				[node setValue:([references count] > 0) ? references : nil forKey:key];
				[references release];
			} else if ([value isKindOfClass:[NSManagedObject class]]) {
				[node setValue:[[[value objectID] URIRepresentation] absoluteString] forKey:key];
			} else {
				[node setValue:nil forKey:key];
			}
			continue;
		}
		/* **A PROPERTY THE OBJECT HAS NEVER READ IS NOT WRITTEN BACK, AND THE FIRST LAZY SAVE SHOWED WHY** (§0.18).
		 * `-primitiveValueForKey:` does not fire a fault, so an unfetched property answers nil — and writing that
		 * nil into the node REMOVED the row's value: one edited object came back from the file with its `name`
		 * gone, and nothing in the suite would have noticed had it not checked identity as well as count. A value
		 * is written when the object CHANGED it (even to nil) or when it HOLDS it; otherwise it is left alone. */
		{
			NSDictionary *changed = [managedObject changedValues];
			NSDictionary *committed = [managedObject cd_committedValues];
			BOOL known = ([changed objectForKey:key] != nil || [committed objectForKey:key] != nil);
			id value;

			if (!known) {
				continue;
			}
			value = [managedObject primitiveValueForKey:key];
			[node setValue:value forKey:key];
		}
	}
}

- (BOOL)cd_entityInConfiguration:(NSEntityDescription *)entity
{
	NSString *configuration = [self configurationName];
	NSManagedObjectModel *model = [self cd_model];

	if (configuration == nil || model == nil || entity == nil) {
		return YES;	/* no configuration means every entity, which is the model's own default */
	}
	return [[model entitiesForConfiguration:configuration] containsObject:entity];
}

- (NSSet *)cacheNodes { return [NSSet setWithArray:[_cacheNodes allValues]]; }

- (void)addCacheNodes:(NSSet *)cacheNodes
{
	NSArray *all = [cacheNodes allObjects];
	NSUInteger i;

	for (i = 0; i < [all count]; i++) {
		NSAtomicStoreCacheNode *node = [all objectAtIndex:i];
		[_cacheNodes setObject:node forKey:[node objectID]];
		/* A NODE ADDED AFTER A LOAD IS A WRITE; a node added BY the load is not, and `-cd_clearChanges` at the end
		 * of every `-load:` is what makes that distinction. */
		[_dirtyNodes addObject:node];
		[_removedObjectIDs removeObject:[node objectID]];
	}
}

- (void)willRemoveCacheNodes:(NSSet *)cacheNodes
{
	NSArray *all = [cacheNodes allObjects];
	NSUInteger i;

	for (i = 0; i < [all count]; i++) {
		NSManagedObjectID *objectID = [[all objectAtIndex:i] objectID];

		[_cacheNodes removeObjectForKey:objectID];
		[_removedObjectIDs addObject:objectID];
		/* A NODE THAT WAS ADDED AND THEN REMOVED BEFORE A SAVE WAS NEVER A WRITE: dropping it from the dirty set
		 * keeps a delete from also being an insert. */
		{
			NSArray *dirty = [_dirtyNodes allObjects];
			NSUInteger d;

			for (d = 0; d < [dirty count]; d++) {
				NSAtomicStoreCacheNode *node = [dirty objectAtIndex:d];

				if ([[node objectID] isEqual:objectID]) {
					[_dirtyNodes removeObject:node];
				}
			}
		}
	}
}

- (NSArray *)cd_objectIDs
{
	return [_cacheNodes allKeys];
}

- (NSAtomicStoreCacheNode *)cd_cacheNodeForObjectID:(NSManagedObjectID *)objectID
{
	return [_cacheNodes objectForKey:objectID];
}

- (NSSet *)cd_dirtyNodes { return [[_dirtyNodes copy] autorelease]; }
- (NSSet *)cd_removedObjectIDs { return [[_removedObjectIDs copy] autorelease]; }

- (void)cd_clearChanges
{
	[_dirtyNodes removeAllObjects];
	[_removedObjectIDs removeAllObjects];
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
