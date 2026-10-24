/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * The three stores that serialise. W7 of COREDATA-PLAN.md §12, and private to this library — the public surface is
 * the store TYPES, not these classes, so the census does not move when a store is added.
 *
 * THE TWO FILE STORES ARE ONE CLASS AND TWO SERIALISERS, which is §7.3's claim made concrete: `NSBinaryStoreType`
 * and `NSXMLStoreType` both write the same node graph plus metadata, one as a keyed archive and one as an XML
 * property list. `NSSQLiteStoreType` is the one that is genuinely different, because its point (D1-b) is that the
 * file is readable — see `store/sqlite/SCHEMA.md`.
 */

#ifndef COREDATA_CDSERIALISINGSTORES_H
#define COREDATA_CDSERIALISINGSTORES_H

#import <CoreData/NSAtomicStore.h>

@interface CDSerialisingStore : NSAtomicStore
/* The node graph and the metadata as one property-list-compatible dictionary. */
- (NSDictionary *)cd_storeDictionary;
- (void)cd_loadStoreDictionary:(NSDictionary *)dictionary;
/* The serialiser, which is the only thing a subclass supplies. */
- (NSData *)cd_serialise:(NSDictionary *)dictionary error:(NSError **)error;
- (NSDictionary *)cd_deserialise:(NSData *)data error:(NSError **)error;
/* The class-level metadata reader, which is what `+metadataForPersistentStoreOfType:URL:error:` needs: the metadata
 * WITHOUT a stack, so an application can ask what a file is before opening it. */
+ (NSDictionary *)cd_metadataAtURL:(NSURL *)url error:(NSError **)error;
@end

@interface CDBinaryStore : CDSerialisingStore
@end

@interface CDXMLStore : CDSerialisingStore
@end

@interface CDSQLiteStore : NSAtomicStore
{
	void *_db;		/* sqlite3 *, held as void so this header does not include sqlite3.h */
}
@end

@class NSFetchRequest;
@class NSError;

@interface CDSQLiteStore (CDQuery)
/* The count a fetch would return, computed by SQL — or -1 when the predicate cannot be translated, in which case
 * the caller falls back to the in-memory scan (§8.4). */
- (NSInteger)cd_countForFetchRequest:(NSFetchRequest *)request error:(NSError **)error;

/* THE FETCH DOOR (§8): the object IDs the WHERE selects, read by SQL, so only matching rows are ever built. nil
 * means "scan instead" — an untranslatable predicate, or a request this store cannot answer alone. */
- (NSArray *)cd_objectIDsForFetchRequest:(NSFetchRequest *)request error:(NSError **)error;
@end

#endif /* COREDATA_CDSERIALISINGSTORES_H */
