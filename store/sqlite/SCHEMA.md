# The Agora SQLite store — the file format, written before the first table

*Decision D1-b of `COREDATA-PLAN.md` §0.1 and §7.1. This document is the schema's specification; `CDSQLiteStore.m`
implements it. It is written and committed **before** the code that creates a table, because §7.1's requirement is
that the conformance fixtures are generated from the specification rather than from whatever the code happened to
emit.*

## What this is not

**It is not Apple's Core Data schema, and that is a decision rather than a shortfall.** Apple's format is
`Z_PK` / `Z_ENT` / `Z_OPT` / `Z_PRIMARYKEY` / `Z_METADATA`, undocumented, and its compatibility check is a version
hash over a canonical model serialisation that nothing describes. Reproducing it would mean reverse-engineering that
hash and freezing this project's schema to a format no document in this tree owns.

**A store written by Apple's Core Data is therefore refused, by name.** Its `NSStoreModelVersionHashesKey` cannot
match this library's digest (SHA-256 over an ordered description, `CDModelPrivate.h`), so opening it fails with
`NSPersistentStoreIncompatibleVersionHashError` — the documented error for a schema mismatch — rather than being
half-read. D1-a remains available later as an **importer**: read their file, write ours. It is not a second schema.

## The schema

Readable names, no prefixes, one row per object and one row per value. `AGORA_` names this project's format so a
future importer can tell the two apart by inspection.

```sql
CREATE TABLE agora_metadata (
    key   TEXT PRIMARY KEY NOT NULL,
    value BLOB NOT NULL
);

CREATE TABLE agora_entity (
    id   INTEGER PRIMARY KEY,
    name TEXT NOT NULL UNIQUE
);

CREATE TABLE agora_object (
    entity_id  INTEGER NOT NULL REFERENCES agora_entity(id),
    object_key INTEGER NOT NULL,
    PRIMARY KEY (entity_id, object_key)
);

CREATE TABLE agora_value (
    entity_id  INTEGER NOT NULL,
    object_key INTEGER NOT NULL,
    name       TEXT NOT NULL,
    type       TEXT NOT NULL,     -- 'string' | 'integer' | 'real' | 'blob' | 'date' | 'array'
    ival       INTEGER,           -- type = 'integer'
    rval       REAL,              -- type = 'real', and 'date' as a reference-date interval
    tval       TEXT,              -- type = 'string'
    bval       BLOB,              -- type = 'blob', and 'array' as a property-list blob of references
    PRIMARY KEY (entity_id, object_key, name),
    FOREIGN KEY (entity_id, object_key) REFERENCES agora_object(entity_id, object_key)
);

CREATE INDEX agora_value_by_name ON agora_value (name);
```

### `array` is a to-many relationship, and it is still a list of references

A to-many relationship's value is an **array of object-URI strings** (`x-coredata://…`), and an array has no scalar
column. It is written as a property-list blob under `type = 'array'` rather than joined into a comma-separated
string: the structure survives, the type column still says what the value is, and the coordinator resolves the
references back into objects when a fault fires. A store that joined them would lose the quoting rule the first time
an entity name contained a comma.

### Why the values are typed columns and not one opaque blob

A store whose every attribute is a blob cannot be inspected with `sqlite3`, and *that* was D1-b's whole argument:
a developer must be able to open the file and read the data. Four nullable typed columns keep the promise while
staying one table — `type` says which column is live, and the others are NULL.

### Why `agora_metadata` holds blobs

The metadata is a property list (`NSStoreTypeKey`, `NSStoreUUIDKey`, `NSStoreModelVersionHashesKey`,
`NSStoreModelVersionIdentifiersKey`), and the version hashes are `NSData`. Serialising the whole dictionary as one
plist blob keeps its types intact and keeps the key set open — the metadata is Apple's dictionary, not this
schema's.

## What the store writes and when

- **On creation**: the DDL above, `PRAGMA journal_mode = WAL`, `PRAGMA foreign_keys = ON`, and the metadata row.
- **On `-save:`**: one `DELETE` + `INSERT` per object for the nodes it was given, in **one transaction**. A partial
  write is not a state this store can produce.
- **On `-load:`**: one query joining `agora_object` and `agora_value`, ordered by `(entity_id, object_key)`.
- **`NSSQLitePragmasOption`** is applied after opening, key by key; `NSSQLiteAnalyzeOption` runs `ANALYZE` and
  `NSSQLiteManualVacuumOption` runs `VACUUM` after the schema is created.

## What is refused

- **Apple-authored stores** — `NSPersistentStoreIncompatibleVersionHashError` (§ above).
- **`NSReadOnlyPersistentStoreOption` with a missing file** — opening a read-only store that does not exist is
  `NSPersistentStoreOpenError`, not an empty store.
- **External records** (`NSExternalRecordsDirectoryOption` and the five related keys) — decision D4, refused by name.

## The version hash, restated because it is the file's identity

`NSStoreModelVersionHashesKey` maps entity name → the entity's `-versionHash` from `CDModelPrivate.m`. A store is
compatible with a model when **every** entity in the model's configuration has a stored hash equal to its current
one, and an entity the store does not know is an incompatibility rather than a skip (`NSManagedObjectModel`
`-isConfiguration:compatibleWithStoreMetadata:` already implements exactly that test, and this store uses it).
