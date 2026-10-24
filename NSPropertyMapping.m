/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSPropertyMapping.h>
#import <Foundation/NSExpression.h>
#import <Foundation/NSString.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSCoder.h>

@implementation NSPropertyMapping

- (void)dealloc
{
	[_name release];
	[_valueExpression release];
	[_userInfo release];
	[super dealloc];
}

- (NSString *)name { return _name; }
- (void)setName:(NSString *)name
{
	NSString *copy = (name != nil) ? [name copy] : nil;
	[_name release];
	_name = copy;
}

- (NSExpression *)valueExpression { return _valueExpression; }
- (void)setValueExpression:(NSExpression *)expression
{
	id copy = [expression copy];
	[_valueExpression release];
	_valueExpression = copy;
}

- (NSDictionary *)userInfo { return _userInfo; }
- (void)setUserInfo:(NSDictionary *)userInfo
{
	NSDictionary *copy = (userInfo != nil) ? [[NSDictionary alloc] initWithDictionary:userInfo] : nil;
	[_userInfo release];
	_userInfo = copy;
}

- (id)copyWithZone:(NSZone *)zone
{
	(void)zone;
	NSPropertyMapping *m = [[NSPropertyMapping allocWithZone:zone] init];
	m->_name = [_name copy];
	m->_valueExpression = [_valueExpression copy];
	m->_userInfo = [_userInfo retain];
	return m;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:_name forKey:@"name"];
	[coder encodeObject:_valueExpression forKey:@"valueExpression"];
	[coder encodeObject:_userInfo forKey:@"userInfo"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super init];
	if (self != nil) {
		_name = [[coder decodeObjectForKey:@"name"] retain];
		_valueExpression = [[coder decodeObjectForKey:@"valueExpression"] retain];
		_userInfo = [[coder decodeObjectForKey:@"userInfo"] retain];
	}
	return self;
}

@end
