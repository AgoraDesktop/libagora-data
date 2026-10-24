/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/CDSQLPredicate.h>
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/NSAttributeDescription.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSDate.h>
#import <Foundation/NSData.h>
#import <Foundation/NSPredicate.h>
#import <Foundation/NSComparisonPredicate.h>
#import <Foundation/NSCompoundPredicate.h>
#import <Foundation/NSExpression.h>
#include <stdio.h>
#include <stdlib.h>

/* A literal in a string context: single quotes doubled. Attribute names come from the model rather than from a
 * caller, but a model is data too. */
static NSString *CDSQLEscape(NSString *text)
{
	NSMutableString *out = [[NSMutableString alloc] init];
	NSUInteger i, n = [text length];

	for (i = 0; i < n; i++) {
		unichar c = [text characterAtIndex:i];

		[out appendString:[[[NSString alloc] initWithCharacters:&c length:1] autorelease]];
		if (c == '\'') { [out appendString:@"'"]; }
	}
	return [out autorelease];
}

static NSString *CDSQLColumnForAttribute(NSAttributeDescription *attribute)
{
	switch ([attribute attributeType]) {
	case NSInteger16AttributeType:
	case NSInteger32AttributeType:
	case NSInteger64AttributeType:
	case NSBooleanAttributeType:
		return @"ival";
	case NSDecimalAttributeType:
	case NSDoubleAttributeType:
	case NSFloatAttributeType:
		return @"rval";
	case NSDateAttributeType:
		return @"rval";
	case NSStringAttributeType:
		return @"tval";
	default:
		return nil;
	}
}

static NSString *CDSQLTypeForAttribute(NSAttributeDescription *attribute)
{
	switch ([attribute attributeType]) {
	case NSInteger16AttributeType:
	case NSInteger32AttributeType:
	case NSInteger64AttributeType:
	case NSBooleanAttributeType:
		return @"integer";
	case NSDecimalAttributeType:
	case NSDoubleAttributeType:
	case NSFloatAttributeType:
		return @"real";
	case NSDateAttributeType:
		return @"date";
	case NSStringAttributeType:
		return @"string";
	default:
		return nil;
	}
}

static id CDSQLBindValue(id value, NSAttributeDescription *attribute)
{
	if ([value isKindOfClass:[NSDate class]] && [attribute attributeType] == NSDateAttributeType) {
		return [NSNumber numberWithDouble:[value timeIntervalSinceReferenceDate]];
	}
	return value;
}

/* `%` AND `_` IN THE OPERAND ARE DATA, not wildcards: a `CONTAINS` on "50%" must not match everything after "50". */
static NSString *CDSQLLikeOperand(NSString *value, BOOL leadingWildcard, BOOL trailingWildcard)
{
	NSMutableString *pattern = [[NSMutableString alloc] init];
	NSUInteger i, n = [value length];

	if (leadingWildcard) { [pattern appendString:@"%"]; }
	for (i = 0; i < n; i++) {
		unichar c = [value characterAtIndex:i];

		if (c == '%' || c == '_' || c == '\\') { [pattern appendString:@"\\"]; }
		[pattern appendString:[[[NSString alloc] initWithCharacters:&c length:1] autorelease]];
	}
	if (trailingWildcard) { [pattern appendString:@"%"]; }
	return [pattern autorelease];
}

/* NSPREDICATE'S `LIKE` IS ICU'S, NOT SQLITE'S: `*` is any sequence and `?` is one character, while SQL has `%` and
 * `_`. The pattern therefore has to be TRANSLATED, not passed through — the first version passed it through, and
 * `name LIKE "person-1%"` matched 1,111 rows in SQL and none in the scan, which is the equivalence test doing its
 * job. A literal `%` or `_` in the pattern is escaped so it stays literal. */
static NSString *CDSQLLikeFromPredicateLike(NSString *pattern)
{
	NSMutableString *out = [[NSMutableString alloc] init];
	NSUInteger i, n = [pattern length];

	for (i = 0; i < n; i++) {
		unichar c = [pattern characterAtIndex:i];

		if (c == '*') {
			[out appendString:@"%"];
		} else if (c == '?') {
			[out appendString:@"_"];
		} else {
			if (c == '%' || c == '_' || c == '\\') { [out appendString:@"\\"]; }
			[out appendString:[[[NSString alloc] initWithCharacters:&c length:1] autorelease]];
		}
	}
	return [out autorelease];
}

static NSString *CDSQLForComparison(NSComparisonPredicate *predicate,
                                    NSEntityDescription *entity,
                                    NSMutableArray *bindings)
{
	NSExpressionType leftType = [[predicate leftExpression] expressionType];
	NSExpressionType rightType = [[predicate rightExpression] expressionType];
	NSString *key = nil;
	NSExpression *valueExpression = nil;
	NSAttributeDescription *attribute;
	NSString *column;
	NSString *typeName;
	NSString *op = nil;
	id value;
	/* ⚠ THIS WAS UNINITIALIZED AND IT COST AN HOUR. `if (valueSQL == nil)` then read GARBAGE, which happened to hold
	 * a pointer to the LIKE clause — so `age >= 50` generated `v.ival LIKE ? ESCAPE '\'`, bound no parameter, and
	 * matched zero rows while every string operator worked. A local that only some branches assign is a bug whether
	 * or not the garbage happens to look like a string (§0.15). */
	NSString *valueSQL = nil;
	NSUInteger opType = [predicate predicateOperatorType];

	/* THE KEY PATH MAY BE ON EITHER SIDE — `40 < age` is the same comparison — and only a key path against a
	 * CONSTANT is translatable. A comparison between two key paths needs a join per row, which is not this slice. */
	if (leftType == NSKeyPathExpressionType && rightType == NSConstantValueExpressionType) {
		key = [[predicate leftExpression] keyPath];
		valueExpression = [predicate rightExpression];
	} else if (leftType == NSConstantValueExpressionType && rightType == NSKeyPathExpressionType) {
		key = [[predicate rightExpression] keyPath];
		valueExpression = [predicate leftExpression];
		/* THE OPERATOR READS RIGHT-TO-LEFT HERE: `40 < age` is `age > 40`, so the ORDERING operators flip. The
		 * symmetric ones (==, !=, IN, BETWEEN) do not, and the string prefixes are refused above because a
		 * `CONTAINS` with its operands the other way round is not the same predicate. */
		switch (opType) {
		case NSLessThanPredicateOperatorType:
			opType = NSGreaterThanPredicateOperatorType;
			break;
		case NSLessThanOrEqualToPredicateOperatorType:
			opType = NSGreaterThanOrEqualToPredicateOperatorType;
			break;
		case NSGreaterThanPredicateOperatorType:
			opType = NSLessThanPredicateOperatorType;
			break;
		case NSGreaterThanOrEqualToPredicateOperatorType:
			opType = NSLessThanOrEqualToPredicateOperatorType;
			break;
		case NSBeginsWithPredicateOperatorType:
		case NSEndsWithPredicateOperatorType:
		case NSContainsPredicateOperatorType:
			return nil;
		default:
			break;
		}
	} else {
		return nil;
	}
	if (key == nil) {
		return nil;
	}
	attribute = [[entity attributesByName] objectForKey:key];
	if (attribute == nil) {
		return nil;
	}
	column = CDSQLColumnForAttribute(attribute);
	typeName = CDSQLTypeForAttribute(attribute);
	if (column == nil || typeName == nil) {
		return nil;	/* a blob or a transformable: not a column this translator knows */
	}
	value = [valueExpression constantValue];
	switch (opType) {
	case NSLessThanPredicateOperatorType: op = @"<"; break;
	case NSLessThanOrEqualToPredicateOperatorType: op = @"<="; break;
	case NSGreaterThanPredicateOperatorType: op = @">"; break;
	case NSGreaterThanOrEqualToPredicateOperatorType: op = @">="; break;
	case NSEqualToPredicateOperatorType: op = @"="; break;
	case NSNotEqualToPredicateOperatorType: op = @"<>"; break;
	case NSBeginsWithPredicateOperatorType:
	case NSEndsWithPredicateOperatorType:
	case NSContainsPredicateOperatorType:
	case NSLikePredicateOperatorType: {
		BOOL leading = (opType == NSEndsWithPredicateOperatorType ||
		                opType == NSContainsPredicateOperatorType);
		BOOL trailing = (opType == NSBeginsWithPredicateOperatorType ||
		                 opType == NSContainsPredicateOperatorType);
		NSString *pattern;

		if (![value isKindOfClass:[NSString class]] || ![typeName isEqualToString:@"string"]) {
			return nil;
		}
		if (opType == NSLikePredicateOperatorType) {
			pattern = CDSQLLikeFromPredicateLike(value);
		} else {
			pattern = CDSQLLikeOperand(value, leading, trailing);
		}
		[bindings addObject:pattern];
		valueSQL = @"LIKE ? ESCAPE '\\'";
		op = nil;
		break;
	}
	case NSInPredicateOperatorType: {
		NSArray *members = nil;
		NSMutableString *list = [[NSMutableString alloc] init];
		NSUInteger i;

		value = [valueExpression constantValue];
		if ([value isKindOfClass:[NSSet class]]) {
			members = [value allObjects];
		} else if ([value isKindOfClass:[NSArray class]]) {
			members = value;
		}
		if ([members count] == 0) {
			[list release];
			return @"0=1";
		}
		for (i = 0; i < [members count]; i++) {
			if (i > 0) { [list appendString:@", "]; }
			[list appendString:@"?"];
			[bindings addObject:CDSQLBindValue([members objectAtIndex:i], attribute)];
		}
		[bindings insertObject:@"" atIndex:0];	/* placeholder, removed below */
		[bindings removeObjectAtIndex:0];
		{
			NSString *fragment = [NSString stringWithFormat:
			    @"EXISTS (SELECT 1 FROM agora_value v WHERE v.entity_id = o.entity_id"
			     " AND v.object_key = o.object_key AND v.name = '%@' AND v.type = '%@'"
			     " AND v.%@ IN (%@))",
			    CDSQLEscape(key), typeName, column, list];
			[list release];
			return fragment;
		}
	}
	case NSBetweenPredicateOperatorType: {
		NSArray *bounds = nil;

		value = [valueExpression constantValue];
		if ([value isKindOfClass:[NSSet class]]) {
			bounds = [value allObjects];
		} else if ([value isKindOfClass:[NSArray class]]) {
			bounds = value;
		}
		if ([bounds count] != 2) {
			return nil;
		}
		[bindings addObject:CDSQLBindValue([bounds objectAtIndex:0], attribute)];
		[bindings addObject:CDSQLBindValue([bounds objectAtIndex:1], attribute)];
		return [NSString stringWithFormat:
		        @"EXISTS (SELECT 1 FROM agora_value v WHERE v.entity_id = o.entity_id"
		         " AND v.object_key = o.object_key AND v.name = '%@' AND v.type = '%@'"
		         " AND v.%@ BETWEEN ? AND ?)",
		        CDSQLEscape(key), typeName, column];
	}
	default:
		return nil;	/* MATCHES, custom selectors, and anything with a quantifier */
	}

	if (valueSQL == nil) {
		if (value == nil || value == [NSNull null]) {
			return nil;	/* a comparison with nil is a NULL test, which this schema writes as absence */
		}
		valueSQL = [NSString stringWithFormat:@"v.%@ %@ ?", column, op];
		[bindings addObject:CDSQLBindValue(value, attribute)];
	} else {
		valueSQL = [NSString stringWithFormat:@"v.%@ %@", column, valueSQL];
	}
	return [NSString stringWithFormat:
	        @"EXISTS (SELECT 1 FROM agora_value v WHERE v.entity_id = o.entity_id"
	         " AND v.object_key = o.object_key AND v.name = '%@' AND v.type = '%@' AND %@)",
	        CDSQLEscape(key), typeName, valueSQL];
}

NSString *CDSQLTranslatePredicate(NSPredicate *predicate,
                                  NSEntityDescription *entity,
                                  NSMutableArray *bindings)
{
	if (predicate == nil) {
		return @"1=1";
	}
	if ([predicate isKindOfClass:[NSCompoundPredicate class]]) {
		NSCompoundPredicate *compound = (NSCompoundPredicate *)predicate;
		NSArray *subpredicates = [compound subpredicates];
		NSMutableArray *parts = [[NSMutableArray alloc] init];
		NSString *joined;
		NSUInteger i;

		if ([compound compoundPredicateType] == NSNotPredicateType) {
			NSString *inner = ([subpredicates count] > 0)
			    ? CDSQLTranslatePredicate([subpredicates objectAtIndex:0], entity, bindings) : nil;

			[parts release];
			return (inner != nil) ? [NSString stringWithFormat:@"NOT (%@)", inner] : nil;
		}
		for (i = 0; i < [subpredicates count]; i++) {
			NSString *part = CDSQLTranslatePredicate([subpredicates objectAtIndex:i], entity, bindings);

			if (part == nil) {
				[parts release];
				return nil;
			}
			[parts addObject:part];
		}
		joined = [parts componentsJoinedByString:([compound compoundPredicateType] == NSAndPredicateType)
		          ? @" AND " : @" OR "];
		[parts release];
		return [NSString stringWithFormat:@"(%@)", joined];
	}
	if ([predicate isKindOfClass:[NSComparisonPredicate class]]) {
		return CDSQLForComparison((NSComparisonPredicate *)predicate, entity, bindings);
	}
	return nil;
}
