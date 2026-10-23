/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSFetchedPropertyDescription.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSCoder.h>

@implementation NSFetchedPropertyDescription

- (void)dealloc { [_fetchRequest release]; [super dealloc]; }

- (NSFetchRequest *)fetchRequest { return _fetchRequest; }
- (void)setFetchRequest:(NSFetchRequest *)fetchRequest
{
	id copy = [fetchRequest copy];
	[_fetchRequest release];
	_fetchRequest = copy;
}

- (NSString *)cd_kind { return @"fetched property"; }

- (NSString *)cd_details
{
	return [NSString stringWithFormat:@"fetch=%@", (_fetchRequest != nil) ? _fetchRequest : @""];
}

- (id)copy
{
	NSFetchedPropertyDescription *f = [super copy];
	f->_fetchRequest = [_fetchRequest retain];
	return f;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[super encodeWithCoder:coder];
	[coder encodeObject:_fetchRequest forKey:@"fetchRequest"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super initWithCoder:coder];
	if (self != nil) { _fetchRequest = [[coder decodeObjectForKey:@"fetchRequest"] retain]; }
	return self;
}

@end
