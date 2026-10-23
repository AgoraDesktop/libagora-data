/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSAtomicStoreCacheNode — one row, as a store sees it: an object ID and a bag of property values.
 *
 * IT IS THE WHOLE REASON FOUR STORES ARE CHEAP (COREDATA-PLAN.md §7.3). A node is not an object and has no
 * behaviour; it is what `NSAtomicStore` loads, updates and saves, so the in-memory, binary, XML and SQLite stores
 * differ only in how they serialise a set of nodes.
 */

#ifndef COREDATA_NSATOMICSTORECACHENODE_H
#define COREDATA_NSATOMICSTORECACHENODE_H

#import <Foundation/Foundation.h>

@class NSManagedObjectID;

@interface NSAtomicStoreCacheNode : NSObject
{
	NSManagedObjectID *_objectID;
	NSMutableDictionary *_propertyCache;
}

- (id)initWithObjectID:(NSManagedObjectID *)moid;
- (NSManagedObjectID *)objectID;
- (NSMutableDictionary *)propertyCache;
- (void)setPropertyCache:(NSMutableDictionary *)propertyCache;
- (id)valueForKey:(NSString *)key;
- (void)setValue:(id)value forKey:(NSString *)key;

@end

#endif /* COREDATA_NSATOMICSTORECACHENODE_H */
