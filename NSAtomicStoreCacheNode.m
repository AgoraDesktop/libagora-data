/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSAtomicStoreCacheNode.h>
#import <CoreData/NSManagedObjectID.h>
#import <Foundation/NSString.h>
#import <Foundation/NSDictionary.h>

@implementation NSAtomicStoreCacheNode

- (id)initWithObjectID:(NSManagedObjectID *)moid
{
	self = [super init];
	if (self != nil) {
		_objectID = [moid retain];
		_propertyCache = [[NSMutableDictionary alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_objectID release];
	[_propertyCache release];
	[super dealloc];
}

- (NSManagedObjectID *)objectID { return _objectID; }

/* THE CACHE IS LAZY-FREE: a node is created with one, so a store that writes a value before reading anything
 * does not have to check. */
- (NSMutableDictionary *)propertyCache { return _propertyCache; }

- (void)setPropertyCache:(NSMutableDictionary *)propertyCache
{
	NSMutableDictionary *copy = (propertyCache != nil)
	    ? [[NSMutableDictionary alloc] initWithDictionary:propertyCache] : [[NSMutableDictionary alloc] init];
	[_propertyCache release];
	_propertyCache = copy;
}

- (id)valueForKey:(NSString *)key { return [_propertyCache objectForKey:key]; }

- (void)setValue:(id)value forKey:(NSString *)key
{
	if (value == nil) {
		[_propertyCache removeObjectForKey:key];
	} else {
		[_propertyCache setObject:value forKey:key];
	}
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<NSAtomicStoreCacheNode: %@ (%lu values)>",
	         _objectID, (unsigned long)[_propertyCache count]];
}

@end
