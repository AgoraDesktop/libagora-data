/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSAttributeDescription.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSCoder.h>

@implementation NSAttributeDescription

- (void)dealloc
{
	[_attributeValueClassName release];
	[_defaultValue release];
	[_valueTransformerName release];
	[super dealloc];
}

- (NSAttributeType)attributeType { return _attributeType; }

- (void)setAttributeType:(NSAttributeType)type
{
	/* A TYPE CHANGE INVALIDATES THE DERIVED CLASS NAME, and an explicit one is kept: that is how a model
	 * editor behaves, and it is what makes `setAttributeValueClassName:` mean something. */
	_attributeType = type;
}

- (NSString *)attributeValueClassName
{
	if (_attributeValueClassName != nil) {
		return _attributeValueClassName;
	}
	switch (_attributeType) {
	case NSInteger16AttributeType:
	case NSInteger32AttributeType:
	case NSInteger64AttributeType:
	case NSDecimalAttributeType:
	case NSDoubleAttributeType:
	case NSFloatAttributeType:
	case NSBooleanAttributeType:
		return @"NSNumber";
	case NSStringAttributeType:
		return @"NSString";
	case NSDateAttributeType:
		return @"NSDate";
	case NSBinaryDataAttributeType:
		return @"NSData";
	case NSTransformableAttributeType:
		return @"NSData";	/* the archive, until a transformer names the real type */
	case NSObjectIDAttributeType:
		return @"NSManagedObjectID";
	default:
		return nil;
	}
}

- (void)setAttributeValueClassName:(NSString *)className
{
	NSString *copy = (className != nil) ? [[NSString alloc] initWithString:className] : nil;
	[_attributeValueClassName release];
	_attributeValueClassName = copy;
}

- (id)defaultValue { return _defaultValue; }
- (void)setDefaultValue:(id)value
{
	id copy = (value != nil) ? [value copy] : nil;
	[_defaultValue release];
	_defaultValue = copy;
}

- (NSString *)valueTransformerName { return _valueTransformerName; }
- (void)setValueTransformerName:(NSString *)string
{
	NSString *copy = (string != nil) ? [[NSString alloc] initWithString:string] : nil;
	[_valueTransformerName release];
	_valueTransformerName = copy;
}

- (NSString *)cd_kind { return @"attribute"; }

- (NSString *)cd_details
{
	return [NSString stringWithFormat:@"type=%lu|class=%@|transformer=%@",
	         (unsigned long)_attributeType,
	         ([self attributeValueClassName] != nil) ? [self attributeValueClassName] : @"",
	         (_valueTransformerName != nil) ? _valueTransformerName : @""];
}

- (id)copy
{
	NSAttributeDescription *a = [super copy];
	a->_attributeType = _attributeType;
	a->_attributeValueClassName = [_attributeValueClassName retain];
	a->_defaultValue = [_defaultValue retain];
	a->_valueTransformerName = [_valueTransformerName retain];
	return a;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[super encodeWithCoder:coder];
	[coder encodeInteger:(NSInteger)_attributeType forKey:@"attributeType"];
	[coder encodeObject:_attributeValueClassName forKey:@"attributeValueClassName"];
	[coder encodeObject:_defaultValue forKey:@"defaultValue"];
	[coder encodeObject:_valueTransformerName forKey:@"valueTransformerName"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super initWithCoder:coder];
	if (self != nil) {
		_attributeType = (NSAttributeType)[coder decodeIntegerForKey:@"attributeType"];
		_attributeValueClassName = [[coder decodeObjectForKey:@"attributeValueClassName"] retain];
		_defaultValue = [[coder decodeObjectForKey:@"defaultValue"] retain];
		_valueTransformerName = [[coder decodeObjectForKey:@"valueTransformerName"] retain];
	}
	return self;
}

@end
