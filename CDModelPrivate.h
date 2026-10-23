/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * CDModelPrivate.h — the two doors the seven model classes need from each other, and the version hash.
 *
 * THE VERSION HASH IS AGORA'S OWN DIGEST, which is decision D1-b (COREDATA-PLAN.md §7.1): SHA-256 over a
 * canonical, sorted description of an entity or property. Apple's algorithm is undocumented, so this one is
 * deliberately *different*: a store written by Apple's Core Data fails the comparison and reports
 * `NSPersistentStoreIncompatibleVersionHashError` — the documented error for a schema mismatch — instead of
 * being half-read. That is a refusal by name, not a compatibility claim.
 *
 * IT MUST BE STABLE ACROSS BUILDS, so nothing here may depend on pointer values, hash-table order or locale.
 * The canonical string is built from names and flags in sorted order, and the test pins a known digest so a
 * change to the recipe fails loudly rather than silently invalidating every store on disk.
 */

#ifndef COREDATA_CDMODELPRIVATE_H
#define COREDATA_CDMODELPRIVATE_H

#import <Foundation/Foundation.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/NSRelationshipDescription.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSManagedObject.h>

/* SHA-256 of the UTF-8 bytes of `canonical`, as 32 bytes. */
NSData *CDVersionHashOfCanonicalString(NSString *canonical);

/* Lower-case hex, for pins and diagnostics. */
NSString *CDHexOfData(NSData *data);

/* What a subclass adds to its own hash and to the model's canonical form. The base class contributes the
 * name, the five flags and the modifier; a subclass that contributes nothing else answers "". */
@interface NSPropertyDescription (CDPrivate)
- (NSString *)cd_kind;
- (NSString *)cd_details;
@end

/* THE THREE BACK-POINTERS, SETTABLE WITHOUT SIDE EFFECTS. Reciprocal links (`-setInverseRelationship:` twice,
 * `-setSuperentity:` updating both ends) would recurse if they used the public setters, so the public door links
 * and the private one only assigns. This is the whole reason the file exists. */
@class NSRelationshipDescription;
@class NSEntityDescription;

@interface NSPropertyDescription (CDPrivate)
- (void)cd_setEntity:(NSEntityDescription *)entity;
@end

@interface NSRelationshipDescription (CDPrivate)
- (void)cd_setInverseRelationship:(NSRelationshipDescription *)relationship;
- (void)cd_setDestinationEntity:(NSEntityDescription *)entity;
@end

@interface NSEntityDescription (CDPrivate)
- (void)cd_setEntity:(NSEntityDescription *)entity forProperty:(NSPropertyDescription *)property;
- (void)cd_setManagedObjectModel:(id)model;
- (void)cd_setSuperentity:(NSEntityDescription *)entity;
@end

/* THE DOORS W3 AND W4 DRIVE AN OBJECT WITH. They are on the object rather than on the context because the
 * context is the thing being written next, and a door only a context may use is still a door the object owns. */
@class NSManagedObject;
@class NSManagedObjectContext;
@class NSFetchRequest;
@class NSError;
@class NSArray;

/* THE STORE'S DOORS, AS A PROTOCOL RATHER THAN A TYPE. `NSPersistentStoreCoordinator` does not exist yet (W4), so
 * the context cannot name it — but it must still be able to ASK whether the object it was given answers. A
 * protocol with @optional members says exactly that: the messages are type-checked, and the guard is still
 * `respondsToSelector:`, so W3 runs with no coordinator at all and W4 fills in the other side. */
@protocol CDStoreDoors <NSObject>
@optional
- (BOOL)cd_saveContext:(NSManagedObjectContext *)context error:(NSError **)error;
- (BOOL)cd_obtainPermanentIDsForObjects:(NSArray *)objects
                             inContext:(NSManagedObjectContext *)context
                                 error:(NSError **)error;
- (id)cd_executeFetchRequest:(NSFetchRequest *)request
                   inContext:(NSManagedObjectContext *)context
                       error:(NSError **)error;
- (void)cd_faultObject:(NSManagedObject *)object inContext:(NSManagedObjectContext *)context;
@end

@interface NSManagedObject (CDPrivate)
- (BOOL)cd_hasChanges;
- (void)cd_setFault:(BOOL)flag;
- (void)cd_setInserted:(BOOL)flag;
- (void)cd_setDeleted:(BOOL)flag;
- (void)cd_setManagedObjectContext:(id)context;
- (void)cd_applyCommittedValues:(NSDictionary *)values;
- (void)cd_turnIntoFault;
- (void)cd_setObjectID:(NSManagedObjectID *)objectID;
- (NSDictionary *)cd_committedValues;
@end

#endif /* COREDATA_CDMODELPRIVATE_H */
