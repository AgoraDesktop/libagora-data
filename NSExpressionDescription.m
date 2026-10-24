/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSExpressionDescription.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSCoder.h>

@implementation NSExpressionDescription

- (void)dealloc { [_expression release]; [super dealloc]; }

- (NSExpression *)expression { return _expression; }
- (void)setExpression:(NSExpression *)expression
{
	id copy = [expression copy];
	[_expression release];
	_expression = copy;
}

- (NSAttributeType)expressionResultType { return _expressionResultType; }
- (void)setExpressionResultType:(NSAttributeType)type { _expressionResultType = type; }

- (NSString *)cd_kind { return @"expression"; }

- (NSString *)cd_details
{
	return [NSString stringWithFormat:@"resultType=%lu|expression=%@",
	         (unsigned long)_expressionResultType, (_expression != nil) ? _expression : @""];
}

- (id)copyWithZone:(NSZone *)zone
{
	(void)zone;
	NSExpressionDescription *e = [super copyWithZone:zone];
	e->_expression = [_expression retain];
	e->_expressionResultType = _expressionResultType;
	return e;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[super encodeWithCoder:coder];
	[coder encodeObject:_expression forKey:@"expression"];
	[coder encodeInteger:(NSInteger)_expressionResultType forKey:@"expressionResultType"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super initWithCoder:coder];
	if (self != nil) {
		_expression = [[coder decodeObjectForKey:@"expression"] retain];
		_expressionResultType = (NSAttributeType)[coder decodeIntegerForKey:@"expressionResultType"];
	}
	return self;
}

@end
