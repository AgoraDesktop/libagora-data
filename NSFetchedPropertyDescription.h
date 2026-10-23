/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSFetchedPropertyDescription — a property whose value is a FETCH, evaluated per object. Two selectors, and
 * both of them matter: the request here is a template whose `$variable` is bound to SELF, which is why
 * `NSPredicate`'s substitution door had to exist before this class could (COREDATA-PLAN.md §4.1).
 */

#ifndef COREDATA_NSFETCHEDPROPERTYDESCRIPTION_H
#define COREDATA_NSFETCHEDPROPERTYDESCRIPTION_H

#import <Foundation/Foundation.h>
#import <CoreData/NSPropertyDescription.h>

@class NSFetchRequest;

@interface NSFetchedPropertyDescription : NSPropertyDescription
{
	NSFetchRequest *_fetchRequest;
}

- (NSFetchRequest *)fetchRequest;
- (void)setFetchRequest:(NSFetchRequest *)fetchRequest;

@end

#endif /* COREDATA_NSFETCHEDPROPERTYDESCRIPTION_H */
