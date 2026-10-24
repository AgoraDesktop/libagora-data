/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * CDSQLiteStore.m — `NSSQLiteStoreType`, against the schema in `store/sqlite/SCHEMA.md` (decision D1-b).
 *
 * THE SCHEMA WAS WRITTEN FIRST, AND THIS FILE IMPLEMENTS IT RATHER THAN DEFINING IT. That order is the point of
 * §7.1: the format is a specification someone can read and build fixtures from, not whatever the code emitted the
 * afternoon it was written.
 *
 * ONE TRANSACTION PER SAVE. The store rewrites the rows it owns inside a single `BEGIN`/`COMMIT`, so a failed save
 * leaves the file as it was — a partial write is not a state this store can produce. That is worth the cost of a
 * full rewrite at this size, and it is the property `NSPersistentStoreIncompleteSaveError` (§6.7) names for the
 * multi-store case.
 *
 * THE VERSION HASH IS THE FILE'S IDENTITY. Opening a store whose `NSStoreModelVersionHashesKey` does not match the
 * model fails with `NSPersistentStoreIncompatibleVersionHashError`, which is what makes D1-b's refusal of an
 * Apple-authored store a *documented* error rather than corruption.
 */

#import <CoreData/CDSerialisingStores.h>
#import <CoreData/NSPersistentStore.h>
#import <CoreData/NSPersistentStoreCoordinator.h>
#import <CoreData/NSAtomicStoreCacheNode.h>
#import <CoreData/NSManagedObjectID.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSAttributeDescription.h>
#import <CoreData/NSFetchRequest.h>
#import <CoreData/NSManagedObjectModel.h>
#import <CoreData/CoreDataErrors.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSData.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSError.h>
#include <sqlite3.h>
#import <CoreData/CDSQLPredicate.h>
#include <string.h>
#include <stdio.h>
#include <stdlib.h>

static NSString *const CDSQLiteMetadataTable = @"agora_metadata";

static NSError *CDSQLiteError(sqlite3 *db, NSInteger code, NSString *why)
{
	NSString *reason = (db != NULL)
	    ? [NSString stringWithFormat:@"%@: %s", why, sqlite3_errmsg(db)] : why;
	return [NSError errorWithDomain:@"NSCocoaErrorDomain" code:code
	                      userInfo:[NSDictionary dictionaryWithObject:reason forKey:@"reason"]];
}

static BOOL CDExec(sqlite3 *db, const char *sql, NSError **error)
{
	char *message = NULL;

	if (sqlite3_exec(db, sql, NULL, NULL, &message) != SQLITE_OK) {
		if (error != NULL) {
			*error = CDSQLiteError(db, NSSQLiteError,
			                       [NSString stringWithFormat:@"%s failed", sql]);
		}
		if (message != NULL) { sqlite3_free(message); }
		return NO;
	}
	return YES;
}

@implementation CDSQLiteStore

- (void)dealloc
{
	if (_db != NULL) {
		sqlite3_close((sqlite3 *)_db);
		_db = NULL;
	}
	[super dealloc];
}

- (BOOL)cd_openCreating:(BOOL)create error:(NSError **)error
{
	NSString *path = [[self URL] path];
	sqlite3 *db = NULL;
	int flags = create ? (SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) : SQLITE_OPEN_READWRITE;

	if (path == nil) {
		if (error != NULL) {
			*error = CDSQLiteError(NULL, NSPersistentStoreOpenError,
			                       @"NSSQLiteStoreType needs a file URL (an in-memory store is NSInMemoryStoreType)");
		}
		return NO;
	}
	if (_db != NULL) {
		return YES;
	}
	if (sqlite3_open_v2([path fileSystemRepresentation], &db, flags, NULL) != SQLITE_OK) {
		if (error != NULL) {
			*error = CDSQLiteError(db, NSPersistentStoreOpenError,
			                       [NSString stringWithFormat:@"could not open %@", path]);
		}
		sqlite3_close(db);
		return NO;
	}
	_db = db;
	/* PRAGMAS FROM THE OPTIONS, applied once at open: the caller's `NSSQLitePragmasOption` is the only way to reach
	 * them, and a store that ignored it would silently run with different durability from the one asked for. */
	{
		NSDictionary *pragmas = [[self options] objectForKey:NSSQLitePragmasOption];
		NSArray *keys = [pragmas allKeys];
		NSUInteger i;

		CDExec(db, "PRAGMA foreign_keys = ON", NULL);
		for (i = 0; i < [keys count]; i++) {
			NSString *key = [keys objectAtIndex:i];
			NSString *sql = [NSString stringWithFormat:@"PRAGMA %@ = %@", key, [pragmas objectForKey:key]];
			CDExec(db, [sql UTF8String], NULL);
		}
	}
	return YES;
}

- (BOOL)cd_createSchema:(NSError **)error
{
	/* THE DDL IS `store/sqlite/SCHEMA.md`, verbatim. */
	static const char *ddl =
	    "CREATE TABLE IF NOT EXISTS agora_metadata ("
	    " key TEXT PRIMARY KEY NOT NULL, value BLOB NOT NULL);"
	    "CREATE TABLE IF NOT EXISTS agora_entity ("
	    " id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE);"
	    "CREATE TABLE IF NOT EXISTS agora_object ("
	    " entity_id INTEGER NOT NULL REFERENCES agora_entity(id), object_key INTEGER NOT NULL,"
	    " PRIMARY KEY (entity_id, object_key));"
	    "CREATE TABLE IF NOT EXISTS agora_value ("
	    " entity_id INTEGER NOT NULL, object_key INTEGER NOT NULL, name TEXT NOT NULL, type TEXT NOT NULL,"
	    " ival INTEGER, rval REAL, tval TEXT, bval BLOB,"
	    " PRIMARY KEY (entity_id, object_key, name),"
	    " FOREIGN KEY (entity_id, object_key) REFERENCES agora_object(entity_id, object_key));"
	    "CREATE INDEX IF NOT EXISTS agora_value_by_name ON agora_value (name);";

	return CDExec((sqlite3 *)_db, ddl, error);
}

/* ---- metadata ------------------------------------------------------------------------------------ */

- (BOOL)cd_writeMetadata:(NSDictionary *)metadata error:(NSError **)error
{
	/* XML RATHER THAN BINARY, because this Foundation's property-list writer implements XML v1.0 and refuses the
	 * binary format with a named error — which is exactly what it said the first time this ran. The blob is opaque
	 * to SQLite either way. */
	NSData *blob = [NSPropertyListSerialization dataWithPropertyList:metadata
	                                                          format:NSPropertyListXMLFormat_v1_0
	                                                         options:0 error:error];
	sqlite3_stmt *statement = NULL;

	if (blob == nil) {
		return NO;
	}
	if (sqlite3_prepare_v2((sqlite3 *)_db,
	        "INSERT OR REPLACE INTO agora_metadata (key, value) VALUES ('store', ?1)", -1,
	        &statement, NULL) != SQLITE_OK) {
		if (error != NULL) { *error = CDSQLiteError((sqlite3 *)_db, NSSQLiteError, @"prepare metadata insert"); }
		return NO;
	}
	sqlite3_bind_blob(statement, 1, [blob bytes], (int)[blob length], SQLITE_TRANSIENT);
	if (sqlite3_step(statement) != SQLITE_DONE) {
		if (error != NULL) { *error = CDSQLiteError((sqlite3 *)_db, NSPersistentStoreSaveError, @"write metadata"); }
		sqlite3_finalize(statement);
		return NO;
	}
	sqlite3_finalize(statement);
	return YES;
}

- (NSDictionary *)cd_readMetadata
{
	sqlite3_stmt *statement = NULL;
	NSDictionary *metadata = nil;

	if (sqlite3_prepare_v2((sqlite3 *)_db, "SELECT value FROM agora_metadata WHERE key = 'store'", -1,
	                       &statement, NULL) != SQLITE_OK) {
		return nil;
	}
	if (sqlite3_step(statement) == SQLITE_ROW) {
		const void *bytes = sqlite3_column_blob(statement, 0);
		int length = sqlite3_column_bytes(statement, 0);

		if (bytes != NULL && length > 0) {
			NSData *blob = [[NSData alloc] initWithBytes:bytes length:(NSUInteger)length];
			id decoded = [NSPropertyListSerialization propertyListWithData:blob
			                                                      options:NSPropertyListImmutable
			                                                       format:NULL error:NULL];
			if ([decoded isKindOfClass:[NSDictionary class]]) {
				metadata = [decoded retain];
			}
			[blob release];
		}
	}
	sqlite3_finalize(statement);
	return [metadata autorelease];
}

- (BOOL)loadMetadata:(NSError **)error
{
	NSDictionary *stored;

	if (![self cd_openCreating:!([self isReadOnly]) error:error]) {
		return NO;
	}
	if (![self cd_createSchema:error]) {
		return NO;
	}
	stored = [self cd_readMetadata];
	if (stored == nil) {
		/* A NEW FILE: the base class mints the metadata (type, UUID, model hashes) and this store writes it. */
		if (![super loadMetadata:error]) {
			return NO;
		}
		return [self cd_writeMetadata:[self metadata] error:error];
	}
	if ([self cd_model] != nil && ![[self cd_model] isConfiguration:[self configurationName]
	                                     compatibleWithStoreMetadata:stored]) {
		if (error != NULL) {
			*error = CDSQLiteError(NULL, NSPersistentStoreIncompatibleVersionHashError,
			    @"the store's model version hashes do not match this model (COREDATA-PLAN.md D1-b)");
		}
		return NO;
	}
	[self setMetadata:stored];
	[self setIdentifier:[stored objectForKey:NSStoreUUIDKey]];
	return YES;
}

+ (NSDictionary *)cd_metadataAtURL:(NSURL *)url error:(NSError **)error
{
	sqlite3 *db = NULL;
	sqlite3_stmt *statement = NULL;
	NSDictionary *metadata = nil;

	if (sqlite3_open_v2([[url path] fileSystemRepresentation], &db, SQLITE_OPEN_READONLY, NULL) != SQLITE_OK) {
		if (error != NULL) { *error = CDSQLiteError(db, NSPersistentStoreOpenError, @"could not open for reading"); }
		sqlite3_close(db);
		return nil;
	}
	if (sqlite3_prepare_v2(db, "SELECT value FROM agora_metadata WHERE key = 'store'", -1,
	                       &statement, NULL) == SQLITE_OK &&
	    sqlite3_step(statement) == SQLITE_ROW) {
		const void *bytes = sqlite3_column_blob(statement, 0);
		int length = sqlite3_column_bytes(statement, 0);

		if (bytes != NULL && length > 0) {
			NSData *blob = [[NSData alloc] initWithBytes:bytes length:(NSUInteger)length];
			id decoded = [NSPropertyListSerialization propertyListWithData:blob
			                                                      options:NSPropertyListImmutable
			                                                       format:NULL error:NULL];
			if ([decoded isKindOfClass:[NSDictionary class]]) {
				metadata = [decoded retain];
			}
			[blob release];
		}
	}
	if (statement != NULL) { sqlite3_finalize(statement); }
	sqlite3_close(db);
	return [metadata autorelease];
}

/* ---- load ---------------------------------------------------------------------------------------- */

- (NSInteger)cd_entityIDForName:(NSString *)name insert:(BOOL)insert
{
	sqlite3_stmt *statement = NULL;
	NSInteger identifier = 0;

	if (sqlite3_prepare_v2((sqlite3 *)_db, "SELECT id FROM agora_entity WHERE name = ?1", -1,
	                       &statement, NULL) == SQLITE_OK) {
		sqlite3_bind_text(statement, 1, [name UTF8String], -1, SQLITE_TRANSIENT);
		if (sqlite3_step(statement) == SQLITE_ROW) {
			identifier = (NSInteger)sqlite3_column_int64(statement, 0);
		}
		sqlite3_finalize(statement);
	}
	if (identifier != 0 || !insert) {
		return identifier;
	}
	if (sqlite3_prepare_v2((sqlite3 *)_db, "INSERT INTO agora_entity (name) VALUES (?1)", -1,
	                       &statement, NULL) != SQLITE_OK) {
		return 0;
	}
	sqlite3_bind_text(statement, 1, [name UTF8String], -1, SQLITE_TRANSIENT);
	sqlite3_step(statement);
	sqlite3_finalize(statement);
	return (NSInteger)sqlite3_last_insert_rowid((sqlite3 *)_db);
}

- (BOOL)load:(NSError **)error
{
	/* ⚠ **THE STORE NO LONGER READS THE FILE HERE, AND THAT IS THE WHOLE POINT (§0.18).** It used to join
	 * `agora_object`, `agora_entity` and `agora_value` and build a node per row — 100,000 rows of work before the
	 * first fetch, every launch. What it does now is open the file and check the schema; the ROWS are read when
	 * something asks for them: `-cd_objectIDs` for which rows exist (a cheap two-column SELECT) and
	 * `-cd_cacheNodeForObjectID:` for one row's values. A workload that reads a hundred rows now costs a hundred
	 * row-selects instead of a whole-file load. */
	if (![self cd_openCreating:NO error:error]) {
		return NO;
	}
	if (![self cd_createSchema:error]) {
		return NO;
	}
	[self cd_clearChanges];
	return YES;
}

- (NSArray *)cd_objectIDs
{
	NSMutableArray *ids;
	NSDictionary *entities = [[self cd_model] entitiesByName];
	sqlite3_stmt *statement = NULL;

	if (![self cd_openCreating:NO error:NULL]) {
		return [NSArray array];
	}
	if (sqlite3_prepare_v2((sqlite3 *)_db,
	        "SELECT o.object_key, e.name FROM agora_object o JOIN agora_entity e ON e.id = o.entity_id",
	        -1, &statement, NULL) != SQLITE_OK) {
		return [NSArray array];
	}
	ids = [[NSMutableArray alloc] init];
	while (sqlite3_step(statement) == SQLITE_ROW) {
		NSInteger objectKey = (NSInteger)sqlite3_column_int64(statement, 0);
		const char *entityName = (const char *)sqlite3_column_text(statement, 1);
		NSEntityDescription *entity = (entityName != NULL)
		    ? [entities objectForKey:[NSString stringWithUTF8String:entityName]] : nil;

		if (entity == nil) {
			continue;
		}
		[ids addObject:[self objectIDForEntity:entity
		                       referenceObject:[NSNumber numberWithInteger:objectKey]]];
	}
	sqlite3_finalize(statement);
	return [ids autorelease];
}

/* **CHUNKS OF ROWS, NOT ONE ROW AT A TIME** (§0.19). The scan has to look at every candidate, and a lazy store that
 * answered one SELECT per candidate would be slower than the eager load it replaced. Ids are grouped by entity and
 * read 200 at a time, so a 10^5-row scan is 500 statements rather than 100,000. */
- (void)cd_prefetchNodesForObjectIDs:(NSArray *)objectIDs
{
	NSMutableDictionary *byEntity = [[NSMutableDictionary alloc] init];
	NSDictionary *entities = [[self cd_model] entitiesByName];
	NSUInteger i, c;

	if (![self cd_openCreating:NO error:NULL]) {
		[byEntity release];
		return;
	}
	for (i = 0; i < [objectIDs count]; i++) {
		NSManagedObjectID *objectID = [objectIDs objectAtIndex:i];
		NSString *entityName = [[objectID entity] name];
		NSMutableArray *group;

		if (entityName == nil || [_cacheNodes objectForKey:objectID] != nil) {
			continue;	/* already read, or an id with no entity */
		}
		group = [byEntity objectForKey:entityName];
		if (group == nil) {
			group = [[NSMutableArray alloc] init];
			[byEntity setObject:group forKey:entityName];
			[group release];
		}
		[group addObject:objectID];
	}

	{
		NSArray *names = [byEntity allKeys];

		for (i = 0; i < [names count]; i++) {
			NSString *entityName = [names objectAtIndex:i];
			NSArray *group = [byEntity objectForKey:entityName];
			NSEntityDescription *entity = [entities objectForKey:entityName];
			NSInteger entityID = [self cd_entityIDForName:entityName insert:NO];

			if (entity == nil || entityID == 0) {
				continue;
			}
			for (c = 0; c < [group count]; c += 200) {
				NSUInteger count = ([group count] - c < 200) ? ([group count] - c) : 200;
				NSMutableString *placeholders = [[NSMutableString alloc] init];
				NSMutableString *sql = [[NSMutableString alloc] init];
				NSMutableDictionary *nodes = [[NSMutableDictionary alloc] init];
				sqlite3_stmt *statement = NULL;
				NSUInteger k;

				for (k = 0; k < count; k++) {
					[placeholders appendString:(k == 0) ? @"?" : @",?"];
					[nodes setObject:[[NSAtomicStoreCacheNode alloc]
					                  initWithObjectID:[group objectAtIndex:c + k]]
					          forKey:[group objectAtIndex:c + k]];
				}
				[sql appendFormat:
				 @"SELECT object_key, name, type, ival, rval, tval, bval FROM agora_value"
				  " WHERE entity_id = ? AND object_key IN (%@)", placeholders];
				if (sqlite3_prepare_v2((sqlite3 *)_db, [sql UTF8String], -1, &statement, NULL) == SQLITE_OK) {
					sqlite3_bind_int64(statement, 1, (sqlite3_int64)entityID);
					for (k = 0; k < count; k++) {
						sqlite3_bind_int64(statement, (int)(k + 2),
						                   (sqlite3_int64)[[ [group objectAtIndex:c + k] primaryKey] longLongValue]);
					}
					while (sqlite3_step(statement) == SQLITE_ROW) {
						NSInteger objectKey = (NSInteger)sqlite3_column_int64(statement, 0);
						const char *valueName = (const char *)sqlite3_column_text(statement, 1);
						const char *valueType = (const char *)sqlite3_column_text(statement, 2);
						NSManagedObjectID *objectID = [self objectIDForEntity:entity
						                                      referenceObject:[NSNumber numberWithInteger:objectKey]];
						NSAtomicStoreCacheNode *node = [nodes objectForKey:objectID];
						id value = nil;

						if (node == nil || valueName == NULL || valueType == NULL) {
							continue;
						}
						switch (valueType[0]) {
						case 'i':
							value = [NSNumber numberWithLongLong:sqlite3_column_int64(statement, 3)];
							break;
						case 'r':
							value = [NSNumber numberWithDouble:sqlite3_column_double(statement, 4)];
							break;
						case 'd':
							value = [NSDate dateWithTimeIntervalSinceReferenceDate:
							         sqlite3_column_double(statement, 4)];
							break;
						case 'a':
						case 'b': {
							const void *bytes = sqlite3_column_blob(statement, 6);
							int length = sqlite3_column_bytes(statement, 6);

							/* ONE OWNED OBJECT, ONE RELEASE (§0.19). The first version retained the data case and
							 * then autoreleased it again — an over-release that showed up as wrong results in the
							 * scan path, not as a crash. */
							if (bytes != NULL && length > 0) {
								NSData *blob = [[NSData alloc] initWithBytes:bytes length:(NSUInteger)length];

								if (valueType[0] == 'b') {
									value = blob;
								} else {
									value = [[NSPropertyListSerialization propertyListWithData:blob
									                                                   options:NSPropertyListImmutable
									                                                    format:NULL error:NULL] retain];
									[blob release];
								}
								[value autorelease];
							}
							break;
						}
						default:
							if (sqlite3_column_text(statement, 5) != NULL) {
								value = [NSString stringWithUTF8String:
								         (const char *)sqlite3_column_text(statement, 5)];
							}
							break;
						}
						if (value != nil) {
							[node setValue:value forKey:[NSString stringWithUTF8String:valueName]];
						}
					}
					sqlite3_finalize(statement);
				}
				/* CACHED DIRECTLY: a prefetch is a READ. */
				{
					NSArray *built = [nodes allKeys];

					for (k = 0; k < [built count]; k++) {
						[_cacheNodes setObject:[nodes objectForKey:[built objectAtIndex:k]]
						                forKey:[built objectAtIndex:k]];
					}
				}
				[nodes release];
				[sql release];
				[placeholders release];
			}
		}
	}
	[byEntity release];
}

- (NSAtomicStoreCacheNode *)cd_cacheNodeForObjectID:(NSManagedObjectID *)objectID
{
	NSAtomicStoreCacheNode *cached = [_cacheNodes objectForKey:objectID];
	NSInteger entityID;
	NSInteger objectKey = [[objectID primaryKey] integerValue];
	NSAtomicStoreCacheNode *node;
	sqlite3_stmt *statement = NULL;

	if (cached != nil) {
		return cached;
	}
	if (![self cd_openCreating:NO error:NULL]) {
		return nil;
	}
	entityID = [self cd_entityIDForName:[[objectID entity] name] insert:NO];
	if (entityID == 0) {
		return nil;
	}
	if (sqlite3_prepare_v2((sqlite3 *)_db,
	        "SELECT name, type, ival, rval, tval, bval FROM agora_value"
	        " WHERE entity_id = ?1 AND object_key = ?2", -1, &statement, NULL) != SQLITE_OK) {
		return nil;
	}
	sqlite3_bind_int64(statement, 1, (sqlite3_int64)entityID);
	sqlite3_bind_int64(statement, 2, (sqlite3_int64)objectKey);

	node = [[NSAtomicStoreCacheNode alloc] initWithObjectID:objectID];
	while (sqlite3_step(statement) == SQLITE_ROW) {
		const char *valueName = (const char *)sqlite3_column_text(statement, 0);
		const char *valueType = (const char *)sqlite3_column_text(statement, 1);
		id value = nil;

		if (valueName == NULL || valueType == NULL) {
			continue;
		}
		switch (valueType[0]) {
		case 'i':
			value = [NSNumber numberWithLongLong:sqlite3_column_int64(statement, 2)];
			break;
		case 'r':
			value = [NSNumber numberWithDouble:sqlite3_column_double(statement, 3)];
			break;
		case 'd':
			value = [NSDate dateWithTimeIntervalSinceReferenceDate:sqlite3_column_double(statement, 3)];
			break;
		case 'b': {
			const void *bytes = sqlite3_column_blob(statement, 5);
			int length = sqlite3_column_bytes(statement, 5);

			value = (bytes != NULL) ? [[[NSData alloc] initWithBytes:bytes length:(NSUInteger)length] autorelease]
			                        : nil;
			break;
		}
		case 'a': {
			/* A TO-MANY RELATIONSHIP IS AN ARRAY OF OBJECT URIs, stored as a property-list blob (SCHEMA.md). The
			 * file-level reader had this case and the per-row reader did not, so a lazy store dropped every
			 * `staff` set — found by the serialisation suite's to-many check, which is why that suite exists. */
			const void *bytes = sqlite3_column_blob(statement, 5);
			int length = sqlite3_column_bytes(statement, 5);

			if (bytes != NULL && length > 0) {
				NSData *blob = [[NSData alloc] initWithBytes:bytes length:(NSUInteger)length];

				value = [NSPropertyListSerialization propertyListWithData:blob
				                                                  options:NSPropertyListImmutable
				                                                   format:NULL error:NULL];
				[blob release];
			}
			break;
		}
		default:
			if (sqlite3_column_text(statement, 4) != NULL) {
				value = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(statement, 4)];
			}
			break;
		}
		if (value != nil) {
			[node setValue:value forKey:[NSString stringWithUTF8String:valueName]];
		}
	}
	sqlite3_finalize(statement);
	/* INTO THE CACHE DIRECTLY, not through `-addCacheNodes:`: a READ IS NOT A WRITE, and the dirty set is what the
	 * incremental save writes. */
	[_cacheNodes setObject:node forKey:objectID];
	return [node autorelease];
}

/* ---- the query path (§8): SQL answers, not a scan ---- */

/* ONE PLACE BUILDS AND BINDS THE STATEMENT, so the count and the fetch cannot disagree about the WHERE. */
- (sqlite3_stmt *)cd_prepareForRequest:(NSFetchRequest *)request
                               select:(NSString *)select
                                 tail:(NSString *)tail
                           extraBinds:(NSArray *)extraBinds
                                error:(NSError **)error
{
	NSEntityDescription *entity = [request entity];
	NSMutableArray *bindings;
	NSString *where;
	NSMutableString *sql;
	sqlite3_stmt *statement = NULL;
	NSUInteger i;

	(void)extraBinds;

	if (entity == nil) {
		return NULL;
	}
	bindings = [[NSMutableArray alloc] init];
	where = CDSQLTranslatePredicate([request predicate], entity, bindings);
	if (where == nil) {
		/* UNTRANSLATABLE: THE CALLER SCANS. A wrong answer would be worse than a slow one. */
		[bindings release];
		return NULL;
	}
	if (![self cd_openCreating:NO error:error]) {
		[bindings release];
		return NULL;
	}
	sql = [NSMutableString stringWithFormat:
	       @"SELECT %@ FROM agora_object o JOIN agora_entity e ON e.id = o.entity_id"
	        " WHERE e.name = ? AND (%@)%@", select, where, (tail != nil) ? tail : @""];
	if (getenv("CD_SQL") != NULL) {
		fprintf(stderr, "    SQL: %s\n", [sql UTF8String]);
	}
	if (sqlite3_prepare_v2((sqlite3 *)_db, [sql UTF8String], -1, &statement, NULL) != SQLITE_OK) {
		[bindings release];
		return NULL;
	}
	sqlite3_bind_text(statement, 1, [[entity name] UTF8String], -1, SQLITE_TRANSIENT);
	for (i = 0; i < [bindings count] + [extraBinds count]; i++) {
		id value = (i < [bindings count]) ? [bindings objectAtIndex:i] : [extraBinds objectAtIndex:i - [bindings count]];
		if ([value isKindOfClass:[NSString class]]) {
			sqlite3_bind_text(statement, (int)(i + 2), [value UTF8String], -1, SQLITE_TRANSIENT);
		} else if ([value isKindOfClass:[NSNumber class]]) {
			/* INTEGERS AS INTEGERS: `LIMIT`/`OFFSET` and every integer attribute bind as int64, which is what the
			 * column holds — a double would compare fine and be the wrong type in a `COUNT`-shaped query. */
			const char *encoding = [value objCType];

			if (encoding != NULL && (encoding[0] == 'f' || encoding[0] == 'd')) {
				sqlite3_bind_double(statement, (int)(i + 2), [value doubleValue]);
			} else {
				sqlite3_bind_int64(statement, (int)(i + 2), (sqlite3_int64)[value longLongValue]);
			}
		} else if ([value isKindOfClass:[NSData class]]) {
			sqlite3_bind_blob(statement, (int)(i + 2), [value bytes], (int)[value length], SQLITE_TRANSIENT);
		} else {
			sqlite3_finalize(statement);
			[bindings release];
			return NULL;
		}
	}
	[bindings release];
	return statement;
}

- (NSInteger)cd_countForFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
	sqlite3_stmt *statement = [self cd_prepareForRequest:request select:@"COUNT(*)" tail:nil
	                                          extraBinds:nil error:error];
	NSInteger count = -1;

	if (statement == NULL) {
		return -1;
	}
	if (sqlite3_step(statement) == SQLITE_ROW) {
		count = (NSInteger)sqlite3_column_int64(statement, 0);
	}
	sqlite3_finalize(statement);
	return count;
}

static NSString *CDSQLiteColumnForAttribute(NSAttributeDescription *attribute)
{
	switch ([attribute attributeType]) {
	case NSInteger16AttributeType:
	case NSInteger32AttributeType:
	case NSInteger64AttributeType:
	case NSBooleanAttributeType:
		return @"ival";
	case NSDecimalAttributeType:
	case NSDoubleAttributeType:
	case NSFloatAttributeType:
	case NSDateAttributeType:
		return @"rval";
	case NSStringAttributeType:
		return @"tval";
	default:
		return nil;
	}
}

static NSString *CDSQLiteTypeNameForAttribute(NSAttributeDescription *attribute)
{
	switch ([attribute attributeType]) {
	case NSInteger16AttributeType:
	case NSInteger32AttributeType:
	case NSInteger64AttributeType:
	case NSBooleanAttributeType:
		return @"integer";
	case NSDecimalAttributeType:
	case NSDoubleAttributeType:
	case NSFloatAttributeType:
		return @"real";
	case NSDateAttributeType:
		return @"date";
	case NSStringAttributeType:
		return @"string";
	default:
		return nil;
	}
}

- (BOOL)cd_canPushDownOrderingForRequest:(NSFetchRequest *)request
{
	NSArray *descriptors = [request sortDescriptors];
	NSEntityDescription *entity = [request entity];
	NSUInteger i;

	/* DISTINCT AND ORDER BY DO NOT COMPOSE WITH A LIMIT the way a caller expects — a distinct page is a page of
	 * distinct rows — so a request that asks for both is shaped in memory. */
	if ([request returnsDistinctResults]) {
		return NO;
	}
	if (entity == nil) {
		return NO;
	}
	for (i = 0; i < [descriptors count]; i++) {
		NSSortDescriptor *descriptor = [descriptors objectAtIndex:i];
		NSAttributeDescription *attribute =
		    [[entity attributesByName] objectForKey:[descriptor key]];

		if (attribute == nil || CDSQLiteColumnForAttribute(attribute) == nil ||
		    CDSQLiteTypeNameForAttribute(attribute) == nil) {
			return NO;	/* a relationship, a selector, a blob: not a column */
		}
	}
	return YES;
}

- (NSArray *)cd_objectIDsForFetchRequest:(NSFetchRequest *)request error:(NSError **)error
{
	sqlite3_stmt *statement;
	NSMutableArray *ids;
	NSDictionary *entities = [[self cd_model] entitiesByName];
	NSMutableString *tail = [[NSMutableString alloc] init];

	/* **ORDER BY AND LIMIT GO TO SQL WHEN THEY CAN** (§0.19). Each descriptor becomes a correlated scalar subquery
	 * over the EAV table — the same shape the WHERE uses — so `ORDER BY age` costs one subquery per row and the
	 * paging happens before any object exists. The caller is told by `-cd_canPushDownOrderingForRequest:` and must
	 * not page again. */
	if ([self cd_canPushDownOrderingForRequest:request]) {
		NSArray *descriptors = [request sortDescriptors];
		NSUInteger d;

		for (d = 0; d < [descriptors count]; d++) {
			NSSortDescriptor *descriptor = [descriptors objectAtIndex:d];
			NSAttributeDescription *attribute =
			    [[[request entity] attributesByName] objectForKey:[descriptor key]];

			[tail appendFormat:@"%@(SELECT v.%@ FROM agora_value v WHERE v.entity_id = o.entity_id"
			                    " AND v.object_key = o.object_key AND v.name = '%@' AND v.type = '%@') %@",
			                    (d == 0) ? @" ORDER BY " : @", ",
			                    CDSQLiteColumnForAttribute(attribute), [descriptor key],
			                    CDSQLiteTypeNameForAttribute(attribute),
			                    [descriptor ascending] ? @"ASC" : @"DESC"];
		}
		if ([request fetchLimit] > 0 || [request fetchOffset] > 0) {
			[tail appendString:@" LIMIT ? OFFSET ?"];
		}
	}

	{
		NSMutableArray *extra = [[NSMutableArray alloc] init];

		if ([self cd_canPushDownOrderingForRequest:request] &&
		    ([request fetchLimit] > 0 || [request fetchOffset] > 0)) {
			[extra addObject:[NSNumber numberWithInteger:
			                  ([request fetchLimit] > 0) ? (NSInteger)[request fetchLimit] : (NSInteger)-1]];
			[extra addObject:[NSNumber numberWithInteger:(NSInteger)[request fetchOffset]]];
		}
		statement = [self cd_prepareForRequest:request select:@"o.object_key, e.name"
		                                  tail:tail extraBinds:extra error:error];
		[extra release];
	}
	[tail release];
	if (statement == NULL) {
		return nil;
	}
	ids = [[NSMutableArray alloc] init];
	while (sqlite3_step(statement) == SQLITE_ROW) {
		NSInteger objectKey = (NSInteger)sqlite3_column_int64(statement, 0);
		const char *entityName = (const char *)sqlite3_column_text(statement, 1);
		NSEntityDescription *entity = (entityName != NULL)
		    ? [entities objectForKey:[NSString stringWithUTF8String:entityName]] : nil;

		if (entity == nil) {
			continue;
		}
		[ids addObject:[self objectIDForEntity:entity
		                       referenceObject:[NSNumber numberWithInteger:objectKey]]];
	}
	sqlite3_finalize(statement);
	return [ids autorelease];
}

/* ---- save ---------------------------------------------------------------------------------------- */

- (BOOL)cd_writeValue:(id)value forName:(NSString *)name
             entityID:(NSInteger)entityID objectKey:(NSInteger)objectKey error:(NSError **)error
{
	sqlite3_stmt *statement = NULL;
	const char *type = "string";

	if ([value isKindOfClass:[NSNumber class]]) {
		/* THE TYPE COLUMN IS DECIDED BY THE NUMBER'S OWN ENCODING, not by a guess from its value: `YES` and `1`
		 * are different attributes, and a store that wrote both as INTEGER would read one back as the other. */
		const char *encoding = [value objCType];
		type = (encoding != NULL && (encoding[0] == 'f' || encoding[0] == 'd')) ? "real" : "integer";
	} else if ([value isKindOfClass:[NSDate class]]) {
		type = "date";
	} else if ([value isKindOfClass:[NSData class]]) {
		type = "blob";
	} else if ([value isKindOfClass:[NSArray class]] || [value isKindOfClass:[NSSet class]]) {
		/* A TO-MANY RELATIONSHIP ARRIVES HERE AS AN ARRAY OF REFERENCES, and an array has no scalar column: it is
		 * written as a property-list blob under its own type rather than being joined into a string, so the
		 * structure survives and the type column still says what the value is. */
		type = "array";
	}

	if (sqlite3_prepare_v2((sqlite3 *)_db,
	        "INSERT OR REPLACE INTO agora_value"
	        " (entity_id, object_key, name, type, ival, rval, tval, bval)"
	        " VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)", -1, &statement, NULL) != SQLITE_OK) {
		if (error != NULL) { *error = CDSQLiteError((sqlite3 *)_db, NSSQLiteError, @"prepare value insert"); }
		return NO;
	}
	sqlite3_bind_int64(statement, 1, (sqlite3_int64)entityID);
	sqlite3_bind_int64(statement, 2, (sqlite3_int64)objectKey);
	sqlite3_bind_text(statement, 3, [name UTF8String], -1, SQLITE_TRANSIENT);
	sqlite3_bind_text(statement, 4, type, -1, SQLITE_TRANSIENT);

	if (strcmp(type, "integer") == 0) {
		sqlite3_bind_int64(statement, 5, (sqlite3_int64)[value longLongValue]);
	} else if (strcmp(type, "real") == 0) {
		sqlite3_bind_double(statement, 6, [value doubleValue]);
	} else if (strcmp(type, "date") == 0) {
		sqlite3_bind_double(statement, 6, [value timeIntervalSinceReferenceDate]);
	} else if (strcmp(type, "blob") == 0) {
		sqlite3_bind_blob(statement, 8, [value bytes], (int)[value length], SQLITE_TRANSIENT);
	} else if (strcmp(type, "array") == 0) {
		NSArray *members = [value respondsToSelector:@selector(allObjects)]
		    ? [value allObjects] : value;
		NSData *blob = [NSPropertyListSerialization dataWithPropertyList:members
		                                                          format:NSPropertyListXMLFormat_v1_0
		                                                         options:0 error:NULL];
		if (blob != nil) {
			sqlite3_bind_blob(statement, 8, [blob bytes], (int)[blob length], SQLITE_TRANSIENT);
		}
	} else {
		sqlite3_bind_text(statement, 7, [value UTF8String], -1, SQLITE_TRANSIENT);
	}

	if (sqlite3_step(statement) != SQLITE_DONE) {
		if (error != NULL) { *error = CDSQLiteError((sqlite3 *)_db, NSPersistentStoreSaveError, @"write value"); }
		sqlite3_finalize(statement);
		return NO;
	}
	sqlite3_finalize(statement);
	return YES;
}

- (BOOL)save:(NSError **)error
{
	NSArray *removed;
	NSArray *dirty;
	NSUInteger i, k;

	if ([self isReadOnly]) {
		if (error != NULL) {
			*error = CDSQLiteError(NULL, NSPersistentStoreOperationError, @"the store is read-only");
		}
		return NO;
	}
	if (![self cd_openCreating:YES error:error] || ![self cd_createSchema:error]) {
		return NO;
	}
	if (!CDExec((sqlite3 *)_db, "BEGIN IMMEDIATE", error)) {
		return NO;
	}

	/* **INCREMENTAL, BECAUSE A LAZY STORE HAS NOT SEEN THE WHOLE FILE** (§0.18). The old body deleted every row and
	 * rewrote the cache — correct while the cache was the file, and catastrophic now: it would erase the rows nobody
	 * had read. Deletions first, then the dirty nodes, and untouched rows are never mentioned. */
	removed = [[self cd_removedObjectIDs] allObjects];
	for (i = 0; i < [removed count]; i++) {
		NSManagedObjectID *objectID = [removed objectAtIndex:i];
		NSInteger entityID = [self cd_entityIDForName:[[objectID entity] name] insert:NO];
		NSInteger objectKey = [[objectID primaryKey] integerValue];
		sqlite3_stmt *statement = NULL;
		int bind;

		if (entityID == 0) {
			continue;
		}
		for (bind = 0; bind < 2; bind++) {
			const char *sql = (bind == 0)
			    ? "DELETE FROM agora_value WHERE entity_id = ?1 AND object_key = ?2"
			    : "DELETE FROM agora_object WHERE entity_id = ?1 AND object_key = ?2";

			if (sqlite3_prepare_v2((sqlite3 *)_db, sql, -1, &statement, NULL) != SQLITE_OK) {
				CDExec((sqlite3 *)_db, "ROLLBACK", NULL);
				if (error != NULL) {
					*error = CDSQLiteError((sqlite3 *)_db, NSSQLiteError, @"prepare delete");
				}
				return NO;
			}
			sqlite3_bind_int64(statement, 1, (sqlite3_int64)entityID);
			sqlite3_bind_int64(statement, 2, (sqlite3_int64)objectKey);
			sqlite3_step(statement);
			sqlite3_finalize(statement);
		}
	}

	dirty = [[self cd_dirtyNodes] allObjects];
	for (i = 0; i < [dirty count]; i++) {
		NSAtomicStoreCacheNode *node = [dirty objectAtIndex:i];
		NSManagedObjectID *objectID = [node objectID];
		NSString *entityName = [[objectID entity] name];
		NSInteger entityID = [self cd_entityIDForName:entityName insert:YES];
		NSInteger objectKey = [[objectID primaryKey] integerValue];
		NSDictionary *values = [node propertyCache];
		NSArray *keys = [values allKeys];
		sqlite3_stmt *statement = NULL;

		if (entityID == 0) {
			CDExec((sqlite3 *)_db, "ROLLBACK", NULL);
			if (error != NULL) {
				*error = CDSQLiteError((sqlite3 *)_db, NSPersistentStoreSaveError,
				                       [NSString stringWithFormat:@"no entity row for %@", entityName]);
			}
			return NO;
		}
		if (sqlite3_prepare_v2((sqlite3 *)_db,
		        "INSERT OR REPLACE INTO agora_object (entity_id, object_key) VALUES (?1, ?2)", -1,
		        &statement, NULL) != SQLITE_OK) {
			CDExec((sqlite3 *)_db, "ROLLBACK", NULL);
			if (error != NULL) { *error = CDSQLiteError((sqlite3 *)_db, NSSQLiteError, @"prepare object insert"); }
			return NO;
		}
		sqlite3_bind_int64(statement, 1, (sqlite3_int64)entityID);
		sqlite3_bind_int64(statement, 2, (sqlite3_int64)objectKey);
		sqlite3_step(statement);
		sqlite3_finalize(statement);

		/* THIS OBJECT'S VALUES ARE REPLACED, not merged: a property that was removed from the object would otherwise
		 * survive in the row the store had never read. */
		if (sqlite3_prepare_v2((sqlite3 *)_db,
		        "DELETE FROM agora_value WHERE entity_id = ?1 AND object_key = ?2", -1,
		        &statement, NULL) != SQLITE_OK) {
			CDExec((sqlite3 *)_db, "ROLLBACK", NULL);
			if (error != NULL) { *error = CDSQLiteError((sqlite3 *)_db, NSSQLiteError, @"prepare value clear"); }
			return NO;
		}
		sqlite3_bind_int64(statement, 1, (sqlite3_int64)entityID);
		sqlite3_bind_int64(statement, 2, (sqlite3_int64)objectKey);
		sqlite3_step(statement);
		sqlite3_finalize(statement);

		for (k = 0; k < [keys count]; k++) {
			NSString *name = [keys objectAtIndex:k];
			if (![self cd_writeValue:[values objectForKey:name] forName:name
			                entityID:entityID objectKey:objectKey error:error]) {
				CDExec((sqlite3 *)_db, "ROLLBACK", NULL);
				return NO;
			}
		}
	}

	if (![self cd_writeMetadata:[self metadata] error:error]) {
		CDExec((sqlite3 *)_db, "ROLLBACK", NULL);
		return NO;
	}
	if (!CDExec((sqlite3 *)_db, "COMMIT", error)) {
		return NO;
	}
	[self cd_clearChanges];
	/* THE OPTIONS THAT ARE COMMANDS RATHER THAN SETTINGS, run after the schema exists. */
	if ([[self options] objectForKey:NSSQLiteAnalyzeOption] != nil) {
		CDExec((sqlite3 *)_db, "ANALYZE", NULL);
	}
	if ([[self options] objectForKey:NSSQLiteManualVacuumOption] != nil) {
		CDExec((sqlite3 *)_db, "VACUUM", NULL);
	}
	return YES;
}

@end
