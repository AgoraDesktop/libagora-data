/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSManagedObjectID — identity without lifetime, which is the trick the whole framework rests on (W2).
 *
 * A MOID is stable for the life of a row and is NOT the object: an object can be faulted, refreshed, turned into
 * a fault and re-materialised, and its ID is the same value throughout. That is what lets one context hold an
 * object while another holds only its ID, and it is why `-isTemporaryID` exists at all — before a save, a row has
 * no key, so the ID names the object rather than the row.
 *
 * THE URI FORM IS APPLE'S (`x-coredata://<store>/<Entity>/<pk>`, with `t` prefixing a temporary key). It is a
 * *name*, not a locator: nothing here dereferences it. It is also the form `NSPersistentStoreCoordinator` uses
 * to hand an object between stores, which is why it is spelled the same way.
 *
 * EQUALITY IS BY (store, entity, key), never by pointer. Two contexts that never saw each other's object must
 * still agree that this ID and that ID are the same row — so `-isEqual:` and `-hash` are written, not inherited.
 */

#ifndef COREDATA_NSMANAGEDOBJECTID_H
#define COREDATA_NSMANAGEDOBJECTID_H

#import <Foundation/Foundation.h>
#import <CoreData/CoreDataDefines.h>

@class NSEntityDescription;
@class NSPersistentStore;
@class NSURL;

@interface NSManagedObjectID : NSObject <NSCopying>
{
	NSEntityDescription *_entity;		/* NOT retained */
	id _store;				/* NSPersistentStore, NOT retained (W4) */
	id _primaryKey;				/* NSNumber for a permanent row, a counter for a temporary one */
	BOOL _temporary;
}

- (NSEntityDescription *)entity;
- (NSPersistentStore *)persistentStore;
- (BOOL)isTemporaryID;
- (NSURL *)URIRepresentation;

@end

/* THE DOORS ONLY THIS LIBRARY OPENS. A caller cannot make an ID, because an ID that names no row is a lie;
 * the context makes temporary ones (W3) and the store makes permanent ones (W4). */
@interface NSManagedObjectID (CDPrivate)
- (id)initWithEntity:(NSEntityDescription *)entity
      persistentStore:(id)store
          primaryKey:(id)key
           temporary:(BOOL)temporary;
- (id)primaryKey;
@end

#endif /* COREDATA_NSMANAGEDOBJECTID_H */
