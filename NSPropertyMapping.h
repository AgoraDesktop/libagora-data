/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSPropertyMapping — one property of the destination, and the expression that produces it. W6 of
 * COREDATA-PLAN.md §12.
 *
 * THE EXPRESSION IS EVALUATED WITH `$source` BOUND, which is why the migration pass hands a context dictionary
 * down: `$source.name` and `$source.first + " " + $source.last` are the two shapes nearly every mapping model
 * uses, and both are `NSExpression` (restored in P0 for exactly this kind of work).
 */

#ifndef COREDATA_NSPROPERTYMAPPING_H
#define COREDATA_NSPROPERTYMAPPING_H

#import <Foundation/Foundation.h>

@class NSExpression;

@interface NSPropertyMapping : NSObject
{
	NSString *_name;
	NSExpression *_valueExpression;
	NSDictionary *_userInfo;
}

- (NSString *)name;
- (void)setName:(NSString *)name;
- (NSExpression *)valueExpression;
- (void)setValueExpression:(NSExpression *)expression;
- (NSDictionary *)userInfo;
- (void)setUserInfo:(NSDictionary *)userInfo;

@end

#endif /* COREDATA_NSPROPERTYMAPPING_H */
