/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * CoreDataErrors.m — the eight string constants. Their VALUES are the names Apple uses, because these keys end
 * up inside `NSError -userInfo` and a client that reads `NSDetailedErrorsKey` by value — or logs it, or writes it
 * to a plist — must see the same string it would see on macOS. A constant whose value is prettier than Apple's is
 * a constant that breaks interop to look nicer in a debugger.
 */

#import <CoreData/CoreDataErrors.h>
#import <Foundation/NSString.h>

NSString *const NSSQLiteErrorDomain = @"NSSQLiteErrorDomain";

NSString *const NSAffectedObjectsErrorKey = @"NSAffectedObjectsErrorKey";
NSString *const NSAffectedStoresErrorKey = @"NSAffectedStoresErrorKey";
NSString *const NSDetailedErrorsKey = @"NSDetailedErrorsKey";
NSString *const NSValidationKeyErrorKey = @"NSValidationKeyErrorKey";
NSString *const NSValidationObjectErrorKey = @"NSValidationObjectErrorKey";
NSString *const NSValidationPredicateErrorKey = @"NSValidationPredicateErrorKey";
NSString *const NSValidationValueErrorKey = @"NSValidationValueErrorKey";
