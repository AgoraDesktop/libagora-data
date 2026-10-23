/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSFetchRequestExpression.h>
#import <CoreData/NSFetchRequest.h>
#import <CoreData/NSManagedObjectContext.h>
#import <Foundation/NSString.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSCoder.h>

@implementation NSFetchRequestExpression

+ (NSExpression *)expressionForFetch:(NSExpression *)fetch
                             context:(NSExpression *)context
                           countOnly:(BOOL)countFlag
{
	NSFetchRequestExpression *e = [[NSFetchRequestExpression alloc]
	                               initWithExpressionType:NSFetchRequestExpressionType];

	e->_requestExpression = [fetch retain];
	e->_contextExpression = [context retain];
	e->_countOnly = countFlag;
	return [e autorelease];
}

- (id)initWithExpressionType:(NSExpressionType)type
{
	/* THE TYPE IS THIS CLASS'S OWN; a caller asking for another one gets the class it asked for. */
	return [super initWithExpressionType:NSFetchRequestExpressionType];
}

- (void)dealloc
{
	[_requestExpression release];
	[_contextExpression release];
	[super dealloc];
}

- (NSExpression *)requestExpression { return _requestExpression; }
- (NSExpression *)contextExpression { return _contextExpression; }
- (BOOL)isCountOnlyRequest { return _countOnly; }

- (id)expressionValueWithObject:(id)object context:(NSMutableDictionary *)context
{
	NSFetchRequest *request = [_requestExpression expressionValueWithObject:object context:context];
	NSManagedObjectContext *managedContext = [_contextExpression expressionValueWithObject:object context:context];

	/* THE CONTEXT IS AN EXPRESSION, NOT AN IVAR, because a fetched property is evaluated against whichever
	 * context asked — the same model serves every context in the application. */
	if (![managedContext isKindOfClass:[NSManagedObjectContext class]] || request == nil) {
		return nil;
	}
	if (_countOnly) {
		return [NSNumber numberWithInteger:(NSInteger)[managedContext countForFetchRequest:request error:NULL]];
	}
	return [managedContext executeFetchRequest:request error:NULL];
}

- (id)copy
{
	return [[NSFetchRequestExpression expressionForFetch:_requestExpression
	                                            context:_contextExpression
	                                          countOnly:_countOnly] retain];
}

- (NSString *)fn_expressionFormat
{
	return [NSString stringWithFormat:@"FETCH(%@, %@%@)", [_requestExpression fn_expressionFormat],
	         [_contextExpression fn_expressionFormat], _countOnly ? @", COUNT" : @""];
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[super encodeWithCoder:coder];
	[coder encodeObject:_requestExpression forKey:@"requestExpression"];
	[coder encodeObject:_contextExpression forKey:@"contextExpression"];
	[coder encodeBool:_countOnly forKey:@"countOnly"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super initWithCoder:coder];
	if (self != nil) {
		_requestExpression = [[coder decodeObjectForKey:@"requestExpression"] retain];
		_contextExpression = [[coder decodeObjectForKey:@"contextExpression"] retain];
		_countOnly = [coder decodeBoolForKey:@"countOnly"];
	}
	return self;
}

@end
