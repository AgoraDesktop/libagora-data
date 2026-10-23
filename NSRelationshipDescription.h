/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSRelationshipDescription — the edge of the graph, and the only property whose meaning depends on another
 * entity. W1 of COREDATA-PLAN.md §12.
 *
 * `-isToMany` IS DERIVED, NOT STORED: it answers `maxCount != 1`. That is Apple's rule and it is the one that
 * keeps a model from holding two contradictory facts — a relationship cannot be "to many" and "at most one" at
 * the same time, so there is one bit of truth and one derivation.
 *
 * THE INVERSE IS RECIPROCAL WHEN SET THROUGH THE PUBLIC DOOR. `-setInverseRelationship:` links both ends, so a
 * model edited from either side ends up consistent; the private assignment exists so the second half of the
 * link does not recurse. A mismatch here is the kind of model corruption that shows up much later as a delete
 * that leaves dangling rows, so it is maintained at the door rather than validated at save.
 */

#ifndef COREDATA_NSRELATIONSHIPDESCRIPTION_H
#define COREDATA_NSRELATIONSHIPDESCRIPTION_H

#import <Foundation/Foundation.h>
#import <CoreData/NSPropertyDescription.h>

typedef NSUInteger NSDeleteRule;

enum {
	NSNoActionDeleteRule = 0,
	NSNullifyDeleteRule = 1,
	NSCascadeDeleteRule = 2,
	NSDenyDeleteRule = 3
};

@class NSEntityDescription;

@interface NSRelationshipDescription : NSPropertyDescription
{
	NSEntityDescription *_destinationEntity;		/* NOT retained */
	NSRelationshipDescription *_inverseRelationship;	/* NOT retained; reciprocal */
	NSUInteger _minCount;
	NSUInteger _maxCount;
	NSDeleteRule _deleteRule;
}

- (NSEntityDescription *)destinationEntity;
- (void)setDestinationEntity:(NSEntityDescription *)entity;

- (NSRelationshipDescription *)inverseRelationship;
- (void)setInverseRelationship:(NSRelationshipDescription *)relationship;

- (NSUInteger)maxCount;
- (void)setMaxCount:(NSUInteger)maxCount;

- (NSUInteger)minCount;
- (void)setMinCount:(NSUInteger)minCount;

- (NSDeleteRule)deleteRule;
- (void)setDeleteRule:(NSDeleteRule)rule;

- (BOOL)isToMany;

@end

#endif /* COREDATA_NSRELATIONSHIPDESCRIPTION_H */
