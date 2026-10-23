/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSEntityDescription — one entity: its properties, its inheritance, and its identity in the model. W1 of
 * COREDATA-PLAN.md §12.
 *
 * THE OWNERSHIP RULE FROM NSPropertyDescription.h IS ENFORCED HERE: an entity retains its properties and its
 * subentities, and `-setProperties:`, `-setSubentities:` and `-setSuperentity:` are the only doors that write
 * the back-pointers. Two consequences follow and both are tested: a property knows its entity, and a subentity
 * appears in exactly one parent's `-subentities`.
 *
 * THE DICTIONARIES ARE COMPUTED ON EVERY CALL RATHER THAN CACHED. Apple caches; this does not, deliberately —
 * a stale `-propertiesByName` after a `-setProperties:` is a bug that survives review because the model was
 * edited in a code path nobody re-ran, and a model has tens of properties, not thousands.
 *
 * THE TWO CLASS METHODS ARE FORWARD-COMPATIBLE AND REFUSE TODAY. `+entityForName:inManagedObjectContext:`
 * reaches the context's coordinator and the coordinator's model through `respondsToSelector:` rather than a
 * declared type, so the day W3 lands the context they begin working; until then a nil context raises a message
 * that says which wave is missing. `+insertNewObjectForEntityForName:inManagedObjectContext:` is the same shape.
 */

#ifndef COREDATA_NSENTITYDESCRIPTION_H
#define COREDATA_NSENTITYDESCRIPTION_H

#import <Foundation/Foundation.h>
#import <CoreData/NSPropertyDescription.h>

@class NSManagedObjectModel;
@class NSManagedObjectContext;
@class NSManagedObject;

@interface NSEntityDescription : NSObject <NSCoding, NSCopying, NSFastEnumeration>
{
	NSString *_name;
	NSString *_managedObjectClassName;
	NSString *_renamingIdentifier;
	NSString *_versionHashModifier;
	NSMutableArray *_properties;
	NSMutableArray *_subentities;
	NSEntityDescription *_superentity;	/* NOT retained */
	NSManagedObjectModel *_model;		/* NOT retained */
	NSMutableDictionary *_userInfo;
	BOOL _abstract;
}

+ (NSEntityDescription *)entityForName:(NSString *)entityName
                inManagedObjectContext:(NSManagedObjectContext *)context;
+ (id)insertNewObjectForEntityForName:(NSString *)entityName
              inManagedObjectContext:(NSManagedObjectContext *)context;

- (NSManagedObjectModel *)managedObjectModel;

- (NSString *)managedObjectClassName;
- (void)setManagedObjectClassName:(NSString *)name;

- (NSString *)name;
- (void)setName:(NSString *)name;

- (BOOL)isAbstract;
- (void)setAbstract:(BOOL)flag;

- (NSDictionary *)subentitiesByName;
- (NSArray *)subentities;
- (void)setSubentities:(NSArray *)array;

- (NSEntityDescription *)superentity;

- (NSDictionary *)propertiesByName;
- (NSArray *)properties;
- (void)setProperties:(NSArray *)properties;

- (NSDictionary *)userInfo;
- (void)setUserInfo:(NSDictionary *)dictionary;

- (NSDictionary *)attributesByName;
- (NSDictionary *)relationshipsByName;

- (NSArray *)relationshipsWithDestinationEntity:(NSEntityDescription *)entity;

- (BOOL)isKindOfEntity:(NSEntityDescription *)entity;

- (NSData *)versionHash;
- (NSString *)versionHashModifier;
- (void)setVersionHashModifier:(NSString *)modifierString;

- (NSString *)renamingIdentifier;
- (void)setRenamingIdentifier:(NSString *)value;

@end

#endif /* COREDATA_NSENTITYDESCRIPTION_H */
