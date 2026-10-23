/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSFetchRequest — the question. W5 of COREDATA-PLAN.md §12, and the object the predicate engine (§8) answers.
 *
 * THIRTY SELECTORS, FOUR FEATURES AND TWENTY-SIX MODIFIERS (§8.3). The features are filtering (`predicate`),
 * ordering (`sortDescriptors`), shaping (`fetchLimit`, `fetchOffset`, `fetchBatchSize`, `propertiesToFetch`,
 * `resultType`, `returnsDistinctResults`, `includesPropertyValues`, `returnsObjectsAsFaults`,
 * `relationshipKeyPathsForPrefetching`) and scope (`entity`, `includesSubentities`, `includesPendingChanges`,
 * `affectedStores`). The modifiers are where the behaviour lives, so each one gets a test that distinguishes it
 * from its default in `tests/fetch.m`.
 *
 * THE DEFAULTS ARE APPLE'S AND THEY ARE NOT NEUTRAL: `includesPendingChanges` and `includesSubentities` are YES,
 * `returnsObjectsAsFaults` and `includesPropertyValues` are YES, `returnsDistinctResults` is NO, and the result
 * type is managed objects. A fetch that forgot one of those would be right for the rows and wrong for the caller.
 */

#ifndef COREDATA_NSFETCHREQUEST_H
#define COREDATA_NSFETCHREQUEST_H

#import <Foundation/Foundation.h>
#import <CoreData/CoreDataDefines.h>

typedef NSUInteger NSFetchRequestResultType;

enum {
	NSManagedObjectResultType = 0x00,
	NSManagedObjectIDResultType = 0x01,
	NSDictionaryResultType = 0x02
};

@class NSEntityDescription;
@class NSPredicate;
@class NSArray;

@interface NSFetchRequest : NSObject <NSCoding, NSCopying>
{
	NSEntityDescription *_entity;		/* NOT retained: the model owns it */
	NSPredicate *_predicate;
	NSArray *_sortDescriptors;
	NSArray *_affectedStores;
	NSArray *_relationshipKeyPathsForPrefetching;
	NSArray *_propertiesToFetch;
	NSUInteger _fetchLimit;
	NSUInteger _fetchOffset;
	NSUInteger _fetchBatchSize;
	NSFetchRequestResultType _resultType;
	BOOL _includesSubentities;
	BOOL _includesPropertyValues;
	BOOL _includesPendingChanges;
	BOOL _returnsObjectsAsFaults;
	BOOL _returnsDistinctResults;
}

- (NSEntityDescription *)entity;
- (void)setEntity:(NSEntityDescription *)entity;

- (NSPredicate *)predicate;
- (void)setPredicate:(NSPredicate *)predicate;

- (NSArray *)sortDescriptors;
- (void)setSortDescriptors:(NSArray *)sortDescriptors;

- (NSUInteger)fetchLimit;
- (void)setFetchLimit:(NSUInteger)limit;

- (NSArray *)affectedStores;
- (void)setAffectedStores:(NSArray *)stores;

- (NSFetchRequestResultType)resultType;
- (void)setResultType:(NSFetchRequestResultType)type;

- (BOOL)includesSubentities;
- (void)setIncludesSubentities:(BOOL)yesNo;

- (BOOL)includesPropertyValues;
- (void)setIncludesPropertyValues:(BOOL)yesNo;

- (BOOL)returnsObjectsAsFaults;
- (void)setReturnsObjectsAsFaults:(BOOL)yesNo;

- (NSArray *)relationshipKeyPathsForPrefetching;
- (void)setRelationshipKeyPathsForPrefetching:(NSArray *)keys;

- (BOOL)includesPendingChanges;
- (void)setIncludesPendingChanges:(BOOL)flag;

- (BOOL)returnsDistinctResults;
- (void)setReturnsDistinctResults:(BOOL)flag;

- (NSArray *)propertiesToFetch;
- (void)setPropertiesToFetch:(NSArray *)values;

- (NSUInteger)fetchOffset;
- (void)setFetchOffset:(NSUInteger)offset;

- (NSUInteger)fetchBatchSize;
- (void)setFetchBatchSize:(NSUInteger)bsize;

@end

#endif /* COREDATA_NSFETCHREQUEST_H */
