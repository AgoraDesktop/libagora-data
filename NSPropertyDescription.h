/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSPropertyDescription — the base of everything an entity can have: attributes, relationships, fetched
 * properties and expression descriptions. W1 of COREDATA-PLAN.md §12.
 *
 * THE FLAGS ARE FOUR DIFFERENT IDEAS AND ALL FOUR ARE IN 10.6. `optional` is validation (a missing value is
 * allowed); `transient` is storage (the value is never written); `indexed` is the store's concern;
 * `indexedBySpotlight` and `storedInExternalRecord` are *other systems'* concerns and are refused at the store
 * layer rather than here (§7.6). Keeping them on the base class is Apple's shape and it is the right one: a
 * property's flags are what a model editor edits, whatever kind of property it is.
 *
 * THE BACK-POINTER IS UNRETAINED AND THAT IS THE OWNERSHIP RULE OF THE WHOLE MODEL: an entity owns its
 * properties, a property names its entity. `-setProperties:` and `-setSuperentity:` are the only doors that
 * maintain it, so a property cannot outlive the entity it describes and no cycle exists to leak.
 */

#ifndef COREDATA_NSPROPERTYDESCRIPTION_H
#define COREDATA_NSPROPERTYDESCRIPTION_H

#import <Foundation/Foundation.h>
#import <CoreData/CoreDataDefines.h>

@class NSEntityDescription;

@interface NSPropertyDescription : NSObject <NSCoding, NSCopying>
{
	NSEntityDescription *_entity;		/* NOT retained: the entity owns this */
	NSString *_name;
	NSString *_renamingIdentifier;
	NSString *_versionHashModifier;
	NSMutableArray *_validationPredicates;
	NSMutableArray *_validationWarnings;
	NSMutableDictionary *_userInfo;
	BOOL _optional;
	BOOL _transient;
	BOOL _indexed;
	BOOL _indexedBySpotlight;
	BOOL _storedInExternalRecord;
}

- (NSEntityDescription *)entity;

- (NSString *)name;
- (void)setName:(NSString *)name;

- (BOOL)isOptional;
- (void)setOptional:(BOOL)flag;

- (BOOL)isTransient;
- (void)setTransient:(BOOL)flag;

- (NSArray *)validationPredicates;
- (NSArray *)validationWarnings;
- (void)setValidationPredicates:(NSArray *)validationPredicates
        withValidationWarnings:(NSArray *)validationWarnings;

- (NSDictionary *)userInfo;
- (void)setUserInfo:(NSDictionary *)dictionary;

- (BOOL)isIndexed;
- (void)setIndexed:(BOOL)flag;

- (NSData *)versionHash;
- (NSString *)versionHashModifier;
- (void)setVersionHashModifier:(NSString *)modifierString;

- (BOOL)isIndexedBySpotlight;
- (void)setIndexedBySpotlight:(BOOL)flag;

- (BOOL)isStoredInExternalRecord;
- (void)setStoredInExternalRecord:(BOOL)flag;

- (NSString *)renamingIdentifier;
- (void)setRenamingIdentifier:(NSString *)value;

@end

#endif /* COREDATA_NSPROPERTYDESCRIPTION_H */
