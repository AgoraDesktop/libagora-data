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
#include <string.h>

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
	NSDictionary *entities = [[self cd_model] entitiesByName];
	sqlite3_stmt *statement = NULL;
	NSInteger currentObject = 0;
	NSAtomicStoreCacheNode *node = nil;

	if (![self cd_openCreating:NO error:error]) {
		return NO;
	}
	if (sqlite3_prepare_v2((sqlite3 *)_db,
	        "SELECT o.entity_id, o.object_key, e.name, v.name, v.type, v.ival, v.rval, v.tval, v.bval"
	        "  FROM agora_object o"
	        "  JOIN agora_entity e ON e.id = o.entity_id"
	        "  LEFT JOIN agora_value v ON v.entity_id = o.entity_id AND v.object_key = o.object_key"
	        " ORDER BY o.entity_id, o.object_key, v.name", -1, &statement, NULL) != SQLITE_OK) {
		if (error != NULL) { *error = CDSQLiteError((sqlite3 *)_db, NSSQLiteError, @"prepare load"); }
		return NO;
	}

	while (sqlite3_step(statement) == SQLITE_ROW) {
		NSInteger objectKey = (NSInteger)sqlite3_column_int64(statement, 1);
		const char *entityName = (const char *)sqlite3_column_text(statement, 2);
		const char *valueName = (const char *)sqlite3_column_text(statement, 3);
		const char *valueType = (const char *)sqlite3_column_text(statement, 4);

		if (node == nil || objectKey != currentObject) {
			NSString *name = [NSString stringWithUTF8String:entityName];
			NSEntityDescription *entity = [entities objectForKey:name];
			NSManagedObjectID *objectID;

			if (node != nil) {
				[self addCacheNodes:[NSSet setWithObject:node]];
				[node release];
				node = nil;
			}
			if (entity == nil) {
				currentObject = objectKey;
				continue;
			}
			objectID = [self objectIDForEntity:entity
			                  referenceObject:[NSNumber numberWithInteger:objectKey]];
			node = [[NSAtomicStoreCacheNode alloc] initWithObjectID:objectID];
			currentObject = objectKey;
		}
		if (valueName != NULL && valueType != NULL && node != nil) {
			NSString *key = [NSString stringWithUTF8String:valueName];
			NSString *type = [NSString stringWithUTF8String:valueType];
			id value = nil;

			if ([type isEqualToString:@"integer"]) {
				value = [NSNumber numberWithLongLong:sqlite3_column_int64(statement, 5)];
			} else if ([type isEqualToString:@"real"]) {
				value = [NSNumber numberWithDouble:sqlite3_column_double(statement, 6)];
			} else if ([type isEqualToString:@"date"]) {
				value = [NSDate dateWithTimeIntervalSinceReferenceDate:sqlite3_column_double(statement, 6)];
			} else if ([type isEqualToString:@"array"]) {
				const void *bytes = sqlite3_column_blob(statement, 8);
				int length = sqlite3_column_bytes(statement, 8);
				if (bytes != NULL && length > 0) {
					NSData *blob = [[NSData alloc] initWithBytes:bytes length:(NSUInteger)length];
					value = [NSPropertyListSerialization propertyListWithData:blob
					                                                 options:NSPropertyListImmutable
					                                                  format:NULL error:NULL];
					[blob release];
				}
			} else if ([type isEqualToString:@"blob"]) {
				const void *bytes = sqlite3_column_blob(statement, 8);
				int length = sqlite3_column_bytes(statement, 8);
				if (bytes != NULL) {
					value = [[[NSData alloc] initWithBytes:bytes length:(NSUInteger)length] autorelease];
				}
			} else if (sqlite3_column_text(statement, 7) != NULL) {
				value = [NSString stringWithUTF8String:(const char *)sqlite3_column_text(statement, 7)];
			}
			if (value != nil) {
				[node setValue:value forKey:key];
			}
		}
	}
	sqlite3_finalize(statement);
	if (node != nil) {
		[self addCacheNodes:[NSSet setWithObject:node]];
		[node release];
	}
	return YES;
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
	NSArray *nodes;
	NSUInteger i;

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
	/* ONE REWRITE PER SAVE, inside one transaction: the file is either the old state or the new one. */
	if (!CDExec((sqlite3 *)_db, "DELETE FROM agora_value", error) ||
	    !CDExec((sqlite3 *)_db, "DELETE FROM agora_object", error)) {
		CDExec((sqlite3 *)_db, "ROLLBACK", NULL);
		return NO;
	}

	nodes = [[self cacheNodes] allObjects];
	for (i = 0; i < [nodes count]; i++) {
		NSAtomicStoreCacheNode *node = [nodes objectAtIndex:i];
		NSManagedObjectID *objectID = [node objectID];
		NSString *entityName = [[objectID entity] name];
		NSInteger entityID = [self cd_entityIDForName:entityName insert:YES];
		NSInteger objectKey = [[objectID primaryKey] integerValue];
		NSDictionary *values = [node propertyCache];
		NSArray *keys = [values allKeys];
		sqlite3_stmt *statement = NULL;
		NSUInteger k;

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
