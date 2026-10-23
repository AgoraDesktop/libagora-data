/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSRelationshipDescription.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSCoder.h>
#import <Foundation/NSException.h>

@implementation NSRelationshipDescription

- (id)init
{
	self = [super init];
	if (self != nil) {
		_maxCount = 1;		/* Apple's default: a to-ONE relationship, min 0 */
		_minCount = 0;
		_deleteRule = NSNullifyDeleteRule;
	}
	return self;
}

- (NSEntityDescription *)destinationEntity { return _destinationEntity; }
- (void)setDestinationEntity:(NSEntityDescription *)entity { _destinationEntity = entity; }
- (void)cd_setDestinationEntity:(NSEntityDescription *)entity { _destinationEntity = entity; }

- (NSRelationshipDescription *)inverseRelationship { return _inverseRelationship; }
- (void)cd_setInverseRelationship:(NSRelationshipDescription *)relationship
{
	_inverseRelationship = relationship;
}

- (void)setInverseRelationship:(NSRelationshipDescription *)relationship
{
	NSRelationshipDescription *previous = _inverseRelationship;

	if (previous == relationship) {
		return;
	}
	_inverseRelationship = relationship;
	/* THE OLD PARTNER IS UNLINKED RATHER THAN LEFT POINTING AT US, and the link is made one-way to avoid
	 * recursing through this same method. */
	if (previous != nil && [previous inverseRelationship] == self) {
		[previous cd_setInverseRelationship:nil];
	}
	if (relationship != nil && [relationship inverseRelationship] != self) {
		[relationship cd_setInverseRelationship:self];
	}
}

- (NSUInteger)minCount { return _minCount; }

- (void)setMinCount:(NSUInteger)minCount
{
	if (minCount > _maxCount && _maxCount != 0) {
		[NSException raise:NSInvalidArgumentException
		            format:@"NSRelationshipDescription: minCount %lu exceeds maxCount %lu",
		                   (unsigned long)minCount, (unsigned long)_maxCount];
	}
	_minCount = minCount;
}

- (NSUInteger)maxCount { return _maxCount; }

- (void)setMaxCount:(NSUInteger)maxCount
{
	if (maxCount < _minCount) {
		[NSException raise:NSInvalidArgumentException
		            format:@"NSRelationshipDescription: maxCount %lu is below minCount %lu",
		                   (unsigned long)maxCount, (unsigned long)_minCount];
	}
	_maxCount = maxCount;
}

- (NSDeleteRule)deleteRule { return _deleteRule; }
- (void)setDeleteRule:(NSDeleteRule)rule { _deleteRule = rule; }

- (BOOL)isToMany { return (_maxCount != 1); }

- (NSString *)cd_kind { return [self isToMany] ? @"to-many relationship" : @"to-one relationship"; }

- (NSString *)cd_details
{
	return [NSString stringWithFormat:@"destination=%@|inverse=%@|min=%lu|max=%lu|delete=%lu",
	         (_destinationEntity != nil) ? [_destinationEntity name] : @"",
	         (_inverseRelationship != nil) ? [_inverseRelationship name] : @"",
	         (unsigned long)_minCount, (unsigned long)_maxCount, (unsigned long)_deleteRule];
}

- (id)copy
{
	NSRelationshipDescription *r = [super copy];
	r->_destinationEntity = _destinationEntity;
	r->_inverseRelationship = nil;	/* a copy is not linked until a model says so */
	r->_minCount = _minCount;
	r->_maxCount = _maxCount;
	r->_deleteRule = _deleteRule;
	return r;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[super encodeWithCoder:coder];
	[coder encodeObject:[_destinationEntity name] forKey:@"destinationName"];
	[coder encodeObject:[_inverseRelationship name] forKey:@"inverseName"];
	[coder encodeInteger:(NSInteger)_minCount forKey:@"minCount"];
	[coder encodeInteger:(NSInteger)_maxCount forKey:@"maxCount"];
	[coder encodeInteger:(NSInteger)_deleteRule forKey:@"deleteRule"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super initWithCoder:coder];
	if (self != nil) {
		_minCount = (NSUInteger)[coder decodeIntegerForKey:@"minCount"];
		_maxCount = (NSUInteger)[coder decodeIntegerForKey:@"maxCount"];
		_deleteRule = (NSDeleteRule)[coder decodeIntegerForKey:@"deleteRule"];
	}
	return self;
}

@end
