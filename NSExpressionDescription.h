/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSExpressionDescription — a named expression, which is how a fetch returns a computed column
 * (`NSDictionaryResultType` + `-propertiesToFetch:`). It is a PROPERTY but not a stored one: it names a result,
 * not a column, which is why the store layer treats it as a projection and the model layer treats it as a
 * property like any other.
 */

#ifndef COREDATA_NSEXPRESSIONDESCRIPTION_H
#define COREDATA_NSEXPRESSIONDESCRIPTION_H

#import <Foundation/Foundation.h>
#import <CoreData/NSPropertyDescription.h>
#import <CoreData/NSAttributeDescription.h>

@class NSExpression;

@interface NSExpressionDescription : NSPropertyDescription
{
	NSExpression *_expression;
	NSAttributeType _expressionResultType;
}

- (NSExpression *)expression;
- (void)setExpression:(NSExpression *)expression;

- (NSAttributeType)expressionResultType;
- (void)setExpressionResultType:(NSAttributeType)type;

@end

#endif /* COREDATA_NSEXPRESSIONDESCRIPTION_H */
