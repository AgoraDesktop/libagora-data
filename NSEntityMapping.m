/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSEntityMapping.h>
#import <Foundation/NSExpression.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSData.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSCoder.h>

@implementation NSEntityMapping

- (void)dealloc
{
	[_name release];
	[_sourceEntityName release];
	[_sourceEntityVersionHash release];
	[_destinationEntityName release];
	[_destinationEntityVersionHash release];
	[_sourceExpression release];
	[_attributeMappings release];
	[_relationshipMappings release];
	[_userInfo release];
	[_entityMigrationPolicyClassName release];
	[super dealloc];
}

- (NSString *)name { return _name; }
- (void)setName:(NSString *)name
{
	NSString *copy = (name != nil) ? [name copy] : nil;
	[_name release];
	_name = copy;
}

- (NSEntityMappingType)mappingType { return _mappingType; }
- (void)setMappingType:(NSEntityMappingType)type { _mappingType = type; }

- (NSString *)sourceEntityName { return _sourceEntityName; }
- (void)setSourceEntityName:(NSString *)name
{
	NSString *copy = (name != nil) ? [name copy] : nil;
	[_sourceEntityName release];
	_sourceEntityName = copy;
}

- (NSData *)sourceEntityVersionHash { return _sourceEntityVersionHash; }
- (void)setSourceEntityVersionHash:(NSData *)vhash
{
	NSData *copy = (vhash != nil) ? [vhash copy] : nil;
	[_sourceEntityVersionHash release];
	_sourceEntityVersionHash = copy;
}

- (NSString *)destinationEntityName { return _destinationEntityName; }
- (void)setDestinationEntityName:(NSString *)name
{
	NSString *copy = (name != nil) ? [name copy] : nil;
	[_destinationEntityName release];
	_destinationEntityName = copy;
}

- (NSData *)destinationEntityVersionHash { return _destinationEntityVersionHash; }
- (void)setDestinationEntityVersionHash:(NSData *)vhash
{
	NSData *copy = (vhash != nil) ? [vhash copy] : nil;
	[_destinationEntityVersionHash release];
	_destinationEntityVersionHash = copy;
}

- (NSArray *)attributeMappings { return _attributeMappings; }
- (void)setAttributeMappings:(NSArray *)mappings
{
	NSArray *copy = (mappings != nil) ? [[NSArray alloc] initWithArray:mappings] : nil;
	[_attributeMappings release];
	_attributeMappings = copy;
}

- (NSArray *)relationshipMappings { return _relationshipMappings; }
- (void)setRelationshipMappings:(NSArray *)mappings
{
	NSArray *copy = (mappings != nil) ? [[NSArray alloc] initWithArray:mappings] : nil;
	[_relationshipMappings release];
	_relationshipMappings = copy;
}

- (NSExpression *)sourceExpression { return _sourceExpression; }
- (void)setSourceExpression:(NSExpression *)source
{
	id copy = [source copy];
	[_sourceExpression release];
	_sourceExpression = copy;
}

- (NSDictionary *)userInfo { return _userInfo; }
- (void)setUserInfo:(NSDictionary *)dict
{
	NSDictionary *copy = (dict != nil) ? [[NSDictionary alloc] initWithDictionary:dict] : nil;
	[_userInfo release];
	_userInfo = copy;
}

- (NSString *)entityMigrationPolicyClassName { return _entityMigrationPolicyClassName; }
- (void)setEntityMigrationPolicyClassName:(NSString *)name
{
	NSString *copy = (name != nil) ? [name copy] : nil;
	[_entityMigrationPolicyClassName release];
	_entityMigrationPolicyClassName = copy;
}

- (id)copy
{
	NSEntityMapping *m = [[NSEntityMapping alloc] init];
	NSUInteger i;

	m->_name = [_name copy];
	m->_mappingType = _mappingType;
	m->_sourceEntityName = [_sourceEntityName copy];
	m->_sourceEntityVersionHash = [_sourceEntityVersionHash copy];
	m->_destinationEntityName = [_destinationEntityName copy];
	m->_destinationEntityVersionHash = [_destinationEntityVersionHash copy];
	m->_sourceExpression = [_sourceExpression copy];
	m->_userInfo = [_userInfo retain];
	m->_entityMigrationPolicyClassName = [_entityMigrationPolicyClassName copy];
	{
		NSMutableArray *attributes = [[NSMutableArray alloc] init];
		NSMutableArray *relationships = [[NSMutableArray alloc] init];

		for (i = 0; i < [_attributeMappings count]; i++) {
			[attributes addObject:[[_attributeMappings objectAtIndex:i] copy]];
		}
		for (i = 0; i < [_relationshipMappings count]; i++) {
			[relationships addObject:[[_relationshipMappings objectAtIndex:i] copy]];
		}
		m->_attributeMappings = attributes;
		m->_relationshipMappings = relationships;
	}
	return m;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:_name forKey:@"name"];
	[coder encodeInteger:(NSInteger)_mappingType forKey:@"mappingType"];
	[coder encodeObject:_sourceEntityName forKey:@"sourceEntityName"];
	[coder encodeObject:_sourceEntityVersionHash forKey:@"sourceHash"];
	[coder encodeObject:_destinationEntityName forKey:@"destinationEntityName"];
	[coder encodeObject:_destinationEntityVersionHash forKey:@"destinationHash"];
	[coder encodeObject:_sourceExpression forKey:@"sourceExpression"];
	[coder encodeObject:_attributeMappings forKey:@"attributeMappings"];
	[coder encodeObject:_relationshipMappings forKey:@"relationshipMappings"];
	[coder encodeObject:_userInfo forKey:@"userInfo"];
	[coder encodeObject:_entityMigrationPolicyClassName forKey:@"policyClassName"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super init];
	if (self != nil) {
		_name = [[coder decodeObjectForKey:@"name"] retain];
		_mappingType = (NSEntityMappingType)[coder decodeIntegerForKey:@"mappingType"];
		_sourceEntityName = [[coder decodeObjectForKey:@"sourceEntityName"] retain];
		_sourceEntityVersionHash = [[coder decodeObjectForKey:@"sourceHash"] retain];
		_destinationEntityName = [[coder decodeObjectForKey:@"destinationEntityName"] retain];
		_destinationEntityVersionHash = [[coder decodeObjectForKey:@"destinationHash"] retain];
		_sourceExpression = [[coder decodeObjectForKey:@"sourceExpression"] retain];
		_attributeMappings = [[coder decodeObjectForKey:@"attributeMappings"] retain];
		_relationshipMappings = [[coder decodeObjectForKey:@"relationshipMappings"] retain];
		_userInfo = [[coder decodeObjectForKey:@"userInfo"] retain];
		_entityMigrationPolicyClassName = [[coder decodeObjectForKey:@"policyClassName"] retain];
	}
	return self;
}

@end
