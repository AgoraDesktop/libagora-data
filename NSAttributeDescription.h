/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSAttributeDescription — one scalar on one entity. The type table is Apple's, including the hundreds-wide
 * gaps (`NSInteger16AttributeType = 100`, `NSDecimalAttributeType = 400`): those numbers are archived in models
 * and would be a source-compatible way to be wrong if renumbered.
 *
 * `-attributeValueClassName` IS DERIVED WHEN NOT SET, which is the behaviour a model editor relies on: an
 * attribute declared as a string and never given a class name still answers "NSString". Setting it explicitly
 * wins, and is how a transformable attribute names its destination type.
 */

#ifndef COREDATA_NSATTRIBUTEDESCRIPTION_H
#define COREDATA_NSATTRIBUTEDESCRIPTION_H

#import <Foundation/Foundation.h>
#import <CoreData/NSPropertyDescription.h>

typedef NSUInteger NSAttributeType;

enum {
	NSUndefinedAttributeType = 0,
	NSInteger16AttributeType = 100,
	NSInteger32AttributeType = 200,
	NSInteger64AttributeType = 300,
	NSDecimalAttributeType = 400,
	NSDoubleAttributeType = 500,
	NSFloatAttributeType = 600,
	NSStringAttributeType = 700,
	NSBooleanAttributeType = 800,
	NSDateAttributeType = 900,
	NSBinaryDataAttributeType = 1000,
	NSTransformableAttributeType = 1800,
	NSObjectIDAttributeType = 2000
};

@interface NSAttributeDescription : NSPropertyDescription
{
	NSAttributeType _attributeType;
	NSString *_attributeValueClassName;
	id _defaultValue;
	NSString *_valueTransformerName;
}

- (NSAttributeType)attributeType;
- (void)setAttributeType:(NSAttributeType)type;

- (NSString *)attributeValueClassName;
- (void)setAttributeValueClassName:(NSString *)className;

- (id)defaultValue;
- (void)setDefaultValue:(id)value;

- (NSString *)valueTransformerName;
- (void)setValueTransformerName:(NSString *)string;

@end

#endif /* COREDATA_NSATTRIBUTEDESCRIPTION_H */
