/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSFetchRequestExpression — an expression whose VALUE is the result of a fetch. W5 of COREDATA-PLAN.md §12.
 *
 * IT EXISTS FOR `NSFetchedPropertyDescription` (W1): a fetched property is a request evaluated per object, so the
 * model needs a way to say "run this" inside an expression. `-expressionValueWithObject:context:` therefore does
 * the work, and `countOnly` is the difference between a list and a number.
 *
 * THE TYPE VALUE IS 50 AND IT IS APPLE'S. `NSExpressionType` numbers the first eleven in NSExpression.h and this
 * one separately, which is why the constant lives in this header rather than that one.
 */

#ifndef COREDATA_NSFETCHREQUESTEXPRESSION_H
#define COREDATA_NSFETCHREQUESTEXPRESSION_H

#import <Foundation/Foundation.h>
#import <Foundation/NSExpression.h>

enum {
	NSFetchRequestExpressionType = 50
};

@class NSFetchRequest;

@interface NSFetchRequestExpression : NSExpression
{
	NSExpression *_requestExpression;
	NSExpression *_contextExpression;
	BOOL _countOnly;
}

+ (NSExpression *)expressionForFetch:(NSExpression *)fetch
                             context:(NSExpression *)context
                           countOnly:(BOOL)countFlag;

- (NSExpression *)requestExpression;
- (NSExpression *)contextExpression;
- (BOOL)isCountOnlyRequest;

@end

#endif /* COREDATA_NSFETCHREQUESTEXPRESSION_H */
