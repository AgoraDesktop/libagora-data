/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * CDFetchEngine.m — the pipeline COREDATA-PLAN.md §8.1 describes, executed against a node cache.
 *
 * ONE PIPELINE, FOUR SHAPES, AND THE ORDER IS THE CONTRACT: candidates → predicate → sort → offset → limit → shape.
 * Limit before shape matters (a fetch limit applies to rows, not to dictionary keys), and offset before limit is
 * what makes paging work. W7 replaces the candidate source with SQL; it does not replace the order, because the
 * order is what the flags mean.
 *
 * `includesPendingChanges` IS THE REASON THE ENGINE CANNOT LIVE IN THE STORE. A fetch must see objects the store
 * has never heard of — inserts sitting in the context — so the engine asks the CONTEXT for them and merges by
 * identity. That is why the predicate is evaluated on managed objects rather than on rows: a pending insert has no
 * row to evaluate.
 */

#import <CoreData/CDFetchEngine.h>
#import <CoreData/NSFetchRequest.h>
#import <Foundation/NSPredicate.h>
#import <Foundation/NSSortDescriptor.h>
#import <Foundation/NSExpression.h>
#import <CoreData/NSExpressionDescription.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSPropertyDescription.h>
#import <Foundation/NSString.h>
#import <CoreData/NSAttributeDescription.h>
#import <CoreData/NSManagedObject.h>
#import <CoreData/NSManagedObjectID.h>
#import <CoreData/NSManagedObjectContext.h>
#import <CoreData/NSAtomicStore.h>
#import <CoreData/NSAtomicStoreCacheNode.h>
#import <CoreData/CoreDataErrors.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSSet.h>
#import <Foundation/NSError.h>
#include <stdlib.h>

static BOOL CDEntityMatches(NSEntityDescription *candidate, NSEntityDescription *wanted, BOOL subentities)
{
	if (candidate == wanted) {
		return YES;
	}
	return (subentities && [candidate isKindOfEntity:wanted]);
}

static NSDictionary *CDDictionaryForObject(NSManagedObject *object, NSArray *properties)
{
	NSMutableDictionary *row = [[NSMutableDictionary alloc] init];
	NSUInteger i;

	for (i = 0; i < [properties count]; i++) {
		id property = [properties objectAtIndex:i];
		NSString *key;
		id value;

		/* BOTH FORMS ARE ACCEPTED, and that is deliberate: Apple documents `-propertiesToFetch` as property
		 * descriptions, but nearly every caller writes key names, so a key name is treated as an attribute name
		 * rather than raising `-[NSTinyString name] is not implemented` at the caller's expense. */
		if ([property isKindOfClass:[NSString class]]) {
			key = property;
			value = [object primitiveValueForKey:key];
		} else if ([property isKindOfClass:[NSExpressionDescription class]]) {
			key = [(NSPropertyDescription *)property name];
			value = [[(NSExpressionDescription *)property expression] expressionValueWithObject:object context:nil];
		} else {
			key = [(NSPropertyDescription *)property name];
			value = [object primitiveValueForKey:key];
		}
		if (value != nil) {
			[row setObject:value forKey:key];
		}
	}
	return [row autorelease];
}

NSArray *CDFetchCandidates(NSAtomicStore *store, NSManagedObjectContext *context, NSFetchRequest *request)
{
	NSEntityDescription *entity = [request entity];
	NSMutableArray *matched = [[NSMutableArray alloc] init];
	NSArray *nodes;
	NSUInteger i;

	if (entity == nil) {
		return [matched autorelease];
	}
	/* **IDS, NOT NODES** (§0.18): a lazy store has read no values at all, so asking it for its nodes would answer
	 * nothing. `-cd_objectIDs` answers the cheap half — which rows exist — and the values are read only for the rows
	 * the predicate actually touches. */
	nodes = [store cd_objectIDs];
	for (i = 0; i < [nodes count]; i++) {
		NSManagedObjectID *objectID = [nodes objectAtIndex:i];

		if (!CDEntityMatches([objectID entity], entity, [request includesSubentities])) {
			continue;
		}
		{
			NSManagedObject *object = [context objectWithID:objectID];

			/* THE PREDICATE IS EVALUATED ON THE OBJECT, not on the row, because a pending insert has no row and a
			 * relationship's value is an object (COREDATA-PLAN.md §8.1). W7's SQL pushdown replaces this loop. */
			if ([request predicate] == nil || [[request predicate] evaluateWithObject:object]) {
				[matched addObject:object];
			}
		}
	}
	return [matched autorelease];
}

NSArray *CDFetchPendingCandidates(NSManagedObjectContext *context, NSFetchRequest *request)
{
	NSEntityDescription *entity = [request entity];
	NSMutableArray *matched = [[NSMutableArray alloc] init];
	NSArray *inserted = [[context insertedObjects] allObjects];
	NSUInteger i;

	/* PENDING INSERTS HAVE NO ROWS, which is exactly why the engine is here and not in the store, and why they are
	 * gathered ONCE for the whole fetch rather than once per store. */
	if (![request includesPendingChanges] || entity == nil) {
		return [matched autorelease];
	}
	for (i = 0; i < [inserted count]; i++) {
		NSManagedObject *object = [inserted objectAtIndex:i];

		if (!CDEntityMatches([object entity], entity, [request includesSubentities])) {
			continue;
		}
		if ([request predicate] == nil || [[request predicate] evaluateWithObject:object]) {
			[matched addObject:object];
		}
	}
	return [matched autorelease];
}

id CDFetchShape(NSArray *candidates, NSFetchRequest *request, NSEntityDescription *entity)
{
	NSMutableArray *matched = [candidates mutableCopy];
	NSUInteger i;

	if ([[request sortDescriptors] count] > 0) {
		NSArray *sorted = [matched sortedArrayUsingDescriptors:[request sortDescriptors]];
		[matched release];
		matched = [sorted mutableCopy];
	}

	/* OFFSET THEN LIMIT, in that order: paging reads "skip n, take m", and doing it the other way takes the first m
	 * of the whole set and then skips inside it. With several stores this is the only place either applies. */
	if ([request fetchOffset] > 0) {
		NSUInteger offset = [request fetchOffset];

		if (offset >= [matched count]) {
			[matched removeAllObjects];
		} else {
			[matched removeObjectsInRange:NSMakeRange(0, offset)];
		}
	}
	if ([request fetchLimit] > 0 && [matched count] > [request fetchLimit]) {
		[matched removeObjectsInRange:NSMakeRange([request fetchLimit], [matched count] - [request fetchLimit])];
	}

	/* THE SHAPING. `fetchBatchSize` is a memory hint with nothing to bound here — the in-memory store has no rows to
	 * page — so it is accepted and not acted on, which is Apple's contract for it as well. */
	{
		NSArray *result;

		switch ([request resultType]) {
		case NSManagedObjectIDResultType: {
			NSMutableArray *ids = [NSMutableArray array];

			for (i = 0; i < [matched count]; i++) {
				NSManagedObjectID *objectID = [[matched objectAtIndex:i] objectID];
				if ([request returnsDistinctResults] && [ids containsObject:objectID]) {
					continue;
				}
				[ids addObject:objectID];
			}
			result = [[ids copy] autorelease];
			break;
		}
		case NSDictionaryResultType: {
			NSArray *properties = [request propertiesToFetch];
			NSMutableArray *rows = [NSMutableArray array];

			if (properties == nil) {
				properties = (entity != nil) ? [[entity propertiesByName] allValues] : [NSArray array];
			}
			for (i = 0; i < [matched count]; i++) {
				NSDictionary *row = CDDictionaryForObject([matched objectAtIndex:i], properties);
				if ([request returnsDistinctResults] && [rows containsObject:row]) {
					continue;
				}
				[rows addObject:row];
			}
			result = [[rows copy] autorelease];
			break;
		}
		default:
			result = [[matched copy] autorelease];
			break;
		}

		/* FAULTS AT THE DOOR: the pipeline had to materialise every candidate to judge it, but a caller that asked
		 * for faults gets faults, and reading one fires it from the node the way any other fault does. */
		if ([request resultType] == NSManagedObjectResultType && [request returnsObjectsAsFaults]) {
			for (i = 0; i < [result count]; i++) {
				[[result objectAtIndex:i] cd_turnIntoFault];
			}
		}
		[matched release];
		return result;
	}
}

NSArray *CDFetchExecute(NSAtomicStore *store, NSManagedObjectContext *context,
                        NSFetchRequest *request, NSError **error)
{
	NSEntityDescription *entity;
	NSMutableArray *candidates;

	if (request == nil) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSCoreDataError
			                        userInfo:[NSDictionary dictionaryWithObject:@"the request is nil"
			                                                             forKey:@"reason"]];
		}
		return nil;
	}
	entity = [request entity];
	if (entity == nil) {
		if (error != NULL) {
			*error = [NSError errorWithDomain:@"NSCocoaErrorDomain" code:NSCoreDataError
			                        userInfo:[NSDictionary dictionaryWithObject:
			                                  @"the fetch request has no entity (COREDATA-PLAN.md W5)"
			                                                             forKey:@"reason"]];
		}
		return nil;
	}
	candidates = [[NSMutableArray alloc] init];
	[candidates addObjectsFromArray:CDFetchCandidates(store, context, request)];
	[candidates addObjectsFromArray:CDFetchPendingCandidates(context, request)];
	{
		id result = CDFetchShape(candidates, request, entity);
		[candidates release];
		return result;
	}
}
