/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSFetchRequest.h>
#import <Foundation/NSPredicate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSCoder.h>

@implementation NSFetchRequest

- (id)init
{
	self = [super init];
	if (self != nil) {
		/* APPLE'S DEFAULTS, WRITTEN OUT RATHER THAN LEFT TO ZERO: three of the five are YES, and a request that
		 * defaulted them to NO would omit pending work, omit subentities' rows, and hand back faulted objects
		 * with no values. */
		_resultType = NSManagedObjectResultType;
		_includesSubentities = YES;
		_includesPropertyValues = YES;
		_includesPendingChanges = YES;
		_returnsObjectsAsFaults = YES;
	}
	return self;
}

- (void)dealloc
{
	[_predicate release];
	[_sortDescriptors release];
	[_affectedStores release];
	[_relationshipKeyPathsForPrefetching release];
	[_propertiesToFetch release];
	[super dealloc];
}

- (NSEntityDescription *)entity { return _entity; }
- (void)setEntity:(NSEntityDescription *)entity { _entity = entity; }

- (NSPredicate *)predicate { return _predicate; }
- (void)setPredicate:(NSPredicate *)predicate
{
	id copy = [predicate copy];
	[_predicate release];
	_predicate = copy;
}

- (NSArray *)sortDescriptors { return _sortDescriptors; }
- (void)setSortDescriptors:(NSArray *)sortDescriptors
{
	NSArray *copy = (sortDescriptors != nil) ? [[NSArray alloc] initWithArray:sortDescriptors] : nil;
	[_sortDescriptors release];
	_sortDescriptors = copy;
}

- (NSUInteger)fetchLimit { return _fetchLimit; }
- (void)setFetchLimit:(NSUInteger)limit { _fetchLimit = limit; }

- (NSArray *)affectedStores { return _affectedStores; }
- (void)setAffectedStores:(NSArray *)stores
{
	NSArray *copy = (stores != nil) ? [[NSArray alloc] initWithArray:stores] : nil;
	[_affectedStores release];
	_affectedStores = copy;
}

- (NSFetchRequestResultType)resultType { return _resultType; }
- (void)setResultType:(NSFetchRequestResultType)type { _resultType = type; }

- (BOOL)includesSubentities { return _includesSubentities; }
- (void)setIncludesSubentities:(BOOL)yesNo { _includesSubentities = yesNo; }

- (BOOL)includesPropertyValues { return _includesPropertyValues; }
- (void)setIncludesPropertyValues:(BOOL)yesNo { _includesPropertyValues = yesNo; }

- (BOOL)returnsObjectsAsFaults { return _returnsObjectsAsFaults; }
- (void)setReturnsObjectsAsFaults:(BOOL)yesNo { _returnsObjectsAsFaults = yesNo; }

- (NSArray *)relationshipKeyPathsForPrefetching { return _relationshipKeyPathsForPrefetching; }
- (void)setRelationshipKeyPathsForPrefetching:(NSArray *)keys
{
	NSArray *copy = (keys != nil) ? [[NSArray alloc] initWithArray:keys] : nil;
	[_relationshipKeyPathsForPrefetching release];
	_relationshipKeyPathsForPrefetching = copy;
}

- (BOOL)includesPendingChanges { return _includesPendingChanges; }
- (void)setIncludesPendingChanges:(BOOL)flag { _includesPendingChanges = flag; }

- (BOOL)returnsDistinctResults { return _returnsDistinctResults; }
- (void)setReturnsDistinctResults:(BOOL)flag { _returnsDistinctResults = flag; }

- (NSArray *)propertiesToFetch { return _propertiesToFetch; }
- (void)setPropertiesToFetch:(NSArray *)values
{
	NSArray *copy = (values != nil) ? [[NSArray alloc] initWithArray:values] : nil;
	[_propertiesToFetch release];
	_propertiesToFetch = copy;
}

- (NSUInteger)fetchOffset { return _fetchOffset; }
- (void)setFetchOffset:(NSUInteger)offset { _fetchOffset = offset; }

- (NSUInteger)fetchBatchSize { return _fetchBatchSize; }
- (void)setFetchBatchSize:(NSUInteger)bsize { _fetchBatchSize = bsize; }

- (id)copyWithZone:(NSZone *)zone
{
	(void)zone;
	NSFetchRequest *r = [[NSFetchRequest allocWithZone:zone] init];
	NSUInteger i;

	r->_entity = _entity;
	r->_predicate = [_predicate retain];
	{
		NSMutableArray *sorted = [[NSMutableArray allocWithZone:zone] init];
		for (i = 0; i < [_sortDescriptors count]; i++) {
			[sorted addObject:[[_sortDescriptors objectAtIndex:i] copy]];
		}
		r->_sortDescriptors = sorted;
	}
	r->_affectedStores = [_affectedStores retain];
	r->_relationshipKeyPathsForPrefetching = [_relationshipKeyPathsForPrefetching retain];
	r->_propertiesToFetch = [_propertiesToFetch retain];
	r->_fetchLimit = _fetchLimit;
	r->_fetchOffset = _fetchOffset;
	r->_fetchBatchSize = _fetchBatchSize;
	r->_resultType = _resultType;
	r->_includesSubentities = _includesSubentities;
	r->_includesPropertyValues = _includesPropertyValues;
	r->_includesPendingChanges = _includesPendingChanges;
	r->_returnsObjectsAsFaults = _returnsObjectsAsFaults;
	r->_returnsDistinctResults = _returnsDistinctResults;
	return r;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:[_entity name] forKey:@"entityName"];
	[coder encodeObject:_predicate forKey:@"predicate"];
	[coder encodeObject:_sortDescriptors forKey:@"sortDescriptors"];
	[coder encodeObject:_affectedStores forKey:@"affectedStores"];
	[coder encodeObject:_relationshipKeyPathsForPrefetching forKey:@"prefetch"];
	[coder encodeObject:_propertiesToFetch forKey:@"propertiesToFetch"];
	[coder encodeInteger:(NSInteger)_fetchLimit forKey:@"fetchLimit"];
	[coder encodeInteger:(NSInteger)_fetchOffset forKey:@"fetchOffset"];
	[coder encodeInteger:(NSInteger)_fetchBatchSize forKey:@"fetchBatchSize"];
	[coder encodeInteger:(NSInteger)_resultType forKey:@"resultType"];
	[coder encodeBool:_includesSubentities forKey:@"includesSubentities"];
	[coder encodeBool:_includesPropertyValues forKey:@"includesPropertyValues"];
	[coder encodeBool:_includesPendingChanges forKey:@"includesPendingChanges"];
	[coder encodeBool:_returnsObjectsAsFaults forKey:@"returnsObjectsAsFaults"];
	[coder encodeBool:_returnsDistinctResults forKey:@"returnsDistinctResults"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [self init];
	if (self != nil) {
		_predicate = [[coder decodeObjectForKey:@"predicate"] retain];
		_sortDescriptors = [[coder decodeObjectForKey:@"sortDescriptors"] retain];
		_affectedStores = [[coder decodeObjectForKey:@"affectedStores"] retain];
		_relationshipKeyPathsForPrefetching = [[coder decodeObjectForKey:@"prefetch"] retain];
		_propertiesToFetch = [[coder decodeObjectForKey:@"propertiesToFetch"] retain];
		_fetchLimit = (NSUInteger)[coder decodeIntegerForKey:@"fetchLimit"];
		_fetchOffset = (NSUInteger)[coder decodeIntegerForKey:@"fetchOffset"];
		_fetchBatchSize = (NSUInteger)[coder decodeIntegerForKey:@"fetchBatchSize"];
		_resultType = (NSFetchRequestResultType)[coder decodeIntegerForKey:@"resultType"];
		_includesSubentities = [coder decodeBoolForKey:@"includesSubentities"];
		_includesPropertyValues = [coder decodeBoolForKey:@"includesPropertyValues"];
		_includesPendingChanges = [coder decodeBoolForKey:@"includesPendingChanges"];
		_returnsObjectsAsFaults = [coder decodeBoolForKey:@"returnsObjectsAsFaults"];
		_returnsDistinctResults = [coder decodeBoolForKey:@"returnsDistinctResults"];
	}
	return self;
}

@end
