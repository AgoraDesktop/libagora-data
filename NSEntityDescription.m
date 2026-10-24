/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSEntityDescription.h>
#import <CoreData/NSAttributeDescription.h>
#import <CoreData/NSRelationshipDescription.h>
#import <CoreData/NSManagedObjectModel.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSEnumerator.h>
#import <Foundation/NSCoder.h>
#import <Foundation/NSException.h>

@implementation NSEntityDescription

- (id)init
{
	self = [super init];
	if (self != nil) {
		_name = @"";
		_managedObjectClassName = @"NSManagedObject";	/* Apple's default */
		_properties = [[NSMutableArray alloc] init];
		_subentities = [[NSMutableArray alloc] init];
	}
	return self;
}

- (void)dealloc
{
	[_name release];
	[_managedObjectClassName release];
	[_renamingIdentifier release];
	[_versionHashModifier release];
	[_properties release];
	[_subentities release];
	[_byNameCache release];
	[_attributesCache release];
	[_relationshipsCache release];
	[_userInfo release];
	[super dealloc];
}

/* ---- the two forward-compatible class doors ------------------------------------------------------ */

+ (NSEntityDescription *)entityForName:(NSString *)entityName
                inManagedObjectContext:(NSManagedObjectContext *)context
{
	NSManagedObjectModel *model = nil;

	if (context == nil) {
		[NSException raise:NSInvalidArgumentException
		            format:@"NSEntityDescription: +entityForName:inManagedObjectContext: needs a context; "
		                   @"NSManagedObjectContext arrives in COREDATA-PLAN.md W3"];
	}
	if (![context respondsToSelector:@selector(persistentStoreCoordinator)]) {
		[NSException raise:NSInvalidArgumentException
		            format:@"NSEntityDescription: %@ is not an NSManagedObjectContext", context];
	}
	model = [[(id)context persistentStoreCoordinator] managedObjectModel];
	if (model == nil) {
		return nil;
	}
	{
		NSEntityDescription *entity = [[model entitiesByName] objectForKey:entityName];
		if (entity == nil) {
			[NSException raise:NSInvalidArgumentException
			            format:@"NSEntityDescription: the model has no entity named `%@`", entityName];
		}
		return entity;
	}
}

+ (id)insertNewObjectForEntityForName:(NSString *)entityName
              inManagedObjectContext:(NSManagedObjectContext *)context
{
	NSEntityDescription *entity = [self entityForName:entityName inManagedObjectContext:context];
	Class cls = NSClassFromString([entity managedObjectClassName]);
	id object;

	if (cls == Nil) {
		[NSException raise:NSInvalidArgumentException
		            format:@"NSEntityDescription: entity `%@` names the class `%@`, which does not exist",
		                   entityName, [entity managedObjectClassName]];
	}
	object = [[cls alloc] init];
	/* The context owns it from here; W3's `-insertObject:` also assigns a temporary ID. */
	[(id)context insertObject:object];
	[object release];
	return object;
}

/* ---- identity ------------------------------------------------------------------------------------ */

- (NSManagedObjectModel *)managedObjectModel { return _model; }
- (void)cd_setManagedObjectModel:(id)model { _model = model; }

- (NSString *)name { return _name; }

- (void)setName:(NSString *)name
{
	NSString *copy = (name != nil) ? [[NSString alloc] initWithString:name] : [[NSString alloc] initWithString:@""];
	[_name release];
	_name = copy;
}

- (NSString *)managedObjectClassName { return _managedObjectClassName; }
- (void)setManagedObjectClassName:(NSString *)name
{
	NSString *copy = (name != nil) ? [[NSString alloc] initWithString:name] : [[NSString alloc] initWithString:@"NSManagedObject"];
	[_managedObjectClassName release];
	_managedObjectClassName = copy;
}

- (BOOL)isAbstract { return _abstract; }
- (void)setAbstract:(BOOL)flag { _abstract = flag; }

/* ---- properties ---------------------------------------------------------------------------------- */

- (NSArray *)properties { return _properties; }

- (void)setProperties:(NSArray *)properties
{
	NSMutableDictionary *seen = [[NSMutableDictionary alloc] init];
	NSUInteger i, n = [properties count];

	[_properties removeAllObjects];
	for (i = 0; i < n; i++) {
		NSPropertyDescription *p = [properties objectAtIndex:i];
		NSString *key = [p name];

		if ([seen objectForKey:key] != nil) {
			[seen release];
			[NSException raise:NSInvalidArgumentException
			            format:@"NSEntityDescription: entity `%@` has two properties named `%@`", _name, key];
		}
		[seen setObject:p forKey:key];
		[_properties addObject:p];
		[self cd_setEntity:self forProperty:p];
	}
	[seen release];
	[self cd_invalidatePropertyCaches];
}

- (void)cd_setEntity:(NSEntityDescription *)entity forProperty:(NSPropertyDescription *)property
{
	[property cd_setEntity:entity];
}

/* ⚠ **THESE DICTIONARIES USED TO BE COMPUTED ON EVERY CALL, AND THAT WAS MEASURED WRONG (§0.12).** The note below
 * says a stale dictionary "is a bug that survives review"; the measurement says the opposite trade: sorting 5,000
 * managed objects took **63.76 s** because every comparison reads a property and every read rebuilt this dictionary
 * — 1 ms per `-valueForKeyPath:`, 10^5 comparisons at 10^5 rows. So they are CACHED now, and the cache is dropped
 * by every door that changes what would be in it: `-setProperties:`, `-setSubentities:` and `-setSuperentity:` (and
 * a superentity's change invalidates its whole subtree, because inherited properties are part of every descendant's
 * dictionary). An entity is mutated by a model being built and read by everything afterwards, which is exactly the
 * shape a cache is for.
 *
 * INHERITED PROPERTIES ARE PART OF `-propertiesByName`, WHICH IS APPLE'S CONTRACT AND NOT AN OPTIMISATION: an
 * Employee answers `name` because a Person has one, and a class with its own property list would make every
 * inherited write an unmodelled key. The chain is walked root-first so a nearer definition wins by name. */
- (NSArray *)cd_propertiesIncludingInherited
{
	NSMutableArray *chain = [[NSMutableArray alloc] init];
	NSMutableArray *all = [[NSMutableArray alloc] init];
	NSEntityDescription *e;
	NSUInteger i;

	for (e = self; e != nil; e = e->_superentity) {
		[chain insertObject:e atIndex:0];
	}
	for (i = 0; i < [chain count]; i++) {
		NSEntityDescription *step = [chain objectAtIndex:i];
		[all addObjectsFromArray:step->_properties];
	}
	[chain release];
	return [all autorelease];
}

- (NSDictionary *)propertiesByName
{
	NSUInteger i;

	if (_byNameCache == nil) {
		NSArray *all = [self cd_propertiesIncludingInherited];

		_byNameCache = [[NSMutableDictionary alloc] init];
		for (i = 0; i < [all count]; i++) {
			NSPropertyDescription *p = [all objectAtIndex:i];
			[_byNameCache setObject:p forKey:[p name]];
		}
	}
	return _byNameCache;
}

/* EVERYTHING THAT CHANGES WHAT THESE DICTIONARIES HOLD DROPS THEM, down the subentity tree: a parent's property is
 * part of a child's `-propertiesByName`. */
- (void)cd_invalidatePropertyCaches
{
	NSUInteger i;

	[_byNameCache release];
	_byNameCache = nil;
	[_attributesCache release];
	_attributesCache = nil;
	[_relationshipsCache release];
	_relationshipsCache = nil;
	for (i = 0; i < [_subentities count]; i++) {
		[[_subentities objectAtIndex:i] cd_invalidatePropertyCaches];
	}
}

- (NSDictionary *)attributesByName
{
	NSArray *all;
	NSUInteger i, n;

	if (_attributesCache == nil) {
		all = [self cd_propertiesIncludingInherited];
		n = [all count];
		_attributesCache = [[NSMutableDictionary alloc] init];
		for (i = 0; i < n; i++) {
			NSPropertyDescription *p = [all objectAtIndex:i];
			if ([p isKindOfClass:[NSAttributeDescription class]]) {
				[_attributesCache setObject:p forKey:[p name]];
			}
		}
	}
	return _attributesCache;
}

- (NSDictionary *)relationshipsByName
{
	NSArray *all;
	NSUInteger i, n;

	if (_relationshipsCache == nil) {
		all = [self cd_propertiesIncludingInherited];
		n = [all count];
		_relationshipsCache = [[NSMutableDictionary alloc] init];
		for (i = 0; i < n; i++) {
			NSPropertyDescription *p = [all objectAtIndex:i];
			if ([p isKindOfClass:[NSRelationshipDescription class]]) {
				[_relationshipsCache setObject:p forKey:[p name]];
			}
		}
	}
	return _relationshipsCache;
}

- (NSArray *)relationshipsWithDestinationEntity:(NSEntityDescription *)entity
{
	NSMutableArray *out = [[NSMutableArray alloc] init];
	NSArray *inherited = [self cd_propertiesIncludingInherited];
	NSUInteger i, n = [inherited count];

	for (i = 0; i < n; i++) {
		NSPropertyDescription *p = [inherited objectAtIndex:i];
		if ([p isKindOfClass:[NSRelationshipDescription class]] &&
		    [(NSRelationshipDescription *)p destinationEntity] == entity) {
			[out addObject:p];
		}
	}
	return [out autorelease];
}

- (NSDictionary *)userInfo { return _userInfo; }
- (void)setUserInfo:(NSDictionary *)dictionary
{
	NSDictionary *copy = (dictionary != nil) ? [[NSDictionary alloc] initWithDictionary:dictionary] : nil;
	[_userInfo release];
	_userInfo = (NSMutableDictionary *)copy;
}

/* ---- inheritance --------------------------------------------------------------------------------- */

- (NSArray *)subentities { return _subentities; }
- (void)cd_setSuperentity:(NSEntityDescription *)entity { _superentity = entity; }
- (NSEntityDescription *)superentity { return _superentity; }

- (void)setSuperentity:(NSEntityDescription *)entity
{
	NSEntityDescription *previous = _superentity;
	NSUInteger i;

	if (previous == entity) {
		return;
	}
	/* DETACH FROM THE OLD PARENT FIRST, so an entity cannot appear in two `-subentities` arrays. */
	if (previous != nil) {
		for (i = 0; i < [previous->_subentities count]; i++) {
			if ([previous->_subentities objectAtIndex:i] == self) {
				[previous->_subentities removeObjectAtIndex:i];
				break;
			}
		}
	}
	_superentity = entity;
	[self cd_invalidatePropertyCaches];
	if (entity != nil) {
		for (i = 0; i < [entity->_subentities count]; i++) {
			if ([entity->_subentities objectAtIndex:i] == self) {
				return;
			}
		}
		[entity->_subentities addObject:self];
	}
}

- (void)setSubentities:(NSArray *)array
{
	NSUInteger i, n = [array count];

	/* `-setSubentities:` REPLACES the children: the ones no longer named are detached, and the ones named are
	 * linked, so the parent/child pair stays reciprocal in both directions. */
	{
		NSArray *previous = [_subentities copy];
		for (i = 0; i < [previous count]; i++) {
			NSEntityDescription *child = [previous objectAtIndex:i];
			if (![array containsObject:child]) {
				child->_superentity = nil;
			}
		}
		[previous release];
	}
	[_subentities removeAllObjects];
	for (i = 0; i < n; i++) {
		NSEntityDescription *child = [array objectAtIndex:i];
		[child setSuperentity:self];
	}
}

- (NSDictionary *)subentitiesByName
{
	NSMutableDictionary *out = [[NSMutableDictionary alloc] init];
	NSUInteger i, n = [_subentities count];

	for (i = 0; i < n; i++) {
		NSEntityDescription *e = [_subentities objectAtIndex:i];
		[out setObject:e forKey:[e name]];
	}
	return [out autorelease];
}

- (BOOL)isKindOfEntity:(NSEntityDescription *)entity
{
	NSEntityDescription *e = self;

	while (e != nil) {
		if (e == entity) {
			return YES;
		}
		e = e->_superentity;
	}
	return NO;
}

/* ---- versioning ---------------------------------------------------------------------------------- */

- (NSString *)versionHashModifier { return _versionHashModifier; }
- (void)setVersionHashModifier:(NSString *)modifierString
{
	NSString *copy = (modifierString != nil) ? [[NSString alloc] initWithString:modifierString] : nil;
	[_versionHashModifier release];
	_versionHashModifier = copy;
}

- (NSString *)renamingIdentifier { return _renamingIdentifier; }
- (void)setRenamingIdentifier:(NSString *)value
{
	NSString *copy = (value != nil) ? [[NSString alloc] initWithString:value] : nil;
	[_renamingIdentifier release];
	_renamingIdentifier = copy;
}

- (NSData *)versionHash
{
	/* PROPERTIES SORTED BY NAME, so the digest does not depend on the order a model editor emitted them. The
	 * inherited properties are part of a subentity's identity, which is why the superentity's name is in here. */
	NSMutableArray *names = [[NSMutableArray alloc] init];
	NSMutableString *canonical;
	NSUInteger i;

	{
		NSArray *all = [self cd_propertiesIncludingInherited];
		for (i = 0; i < [all count]; i++) {
			[names addObject:[[all objectAtIndex:i] name]];
		}
	}
	[names sortUsingSelector:@selector(compare:)];

	canonical = [[NSMutableString alloc] init];
	[canonical appendFormat:@"E|name=%@|class=%@|abstract=%d|super=%@|modifier=%@",
	    _name, _managedObjectClassName, (int)_abstract,
	    (_superentity != nil) ? [_superentity name] : @"",
	    (_versionHashModifier != nil) ? _versionHashModifier : @""];
	{
		NSDictionary *byName = [self propertiesByName];
		for (i = 0; i < [names count]; i++) {
			NSString *key = [names objectAtIndex:i];
			NSPropertyDescription *p = [byName objectForKey:key];
			[canonical appendFormat:@"|%@=%@", key, CDHexOfData([p versionHash])];
		}
	}
	[names release];

	{
		NSData *hash = CDVersionHashOfCanonicalString(canonical);
		[canonical release];
		return hash;
	}
}

/* ---- NSFastEnumeration over the properties ------------------------------------------------------- */

- (NSUInteger)countByEnumeratingWithState:(NSFastEnumerationState *)state
                                  objects:(id __unsafe_unretained [])buffer
                                    count:(NSUInteger)len
{
	return [_properties countByEnumeratingWithState:state objects:buffer count:len];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<NSEntityDescription: %@ (%lu properties)>",
	         _name, (unsigned long)[_properties count]];
}

/* ---- coding -------------------------------------------------------------------------------------- */

- (id)copyWithZone:(NSZone *)zone
{
	(void)zone;
	NSEntityDescription *e = [[NSEntityDescription allocWithZone:zone] init];
	NSUInteger i;

	e->_name = [_name retain];
	e->_managedObjectClassName = [_managedObjectClassName retain];
	e->_renamingIdentifier = [_renamingIdentifier retain];
	e->_versionHashModifier = [_versionHashModifier retain];
	e->_userInfo = [_userInfo retain];
	e->_abstract = _abstract;
	for (i = 0; i < [_properties count]; i++) {
		NSPropertyDescription *p = [[_properties objectAtIndex:i] copy];
		[e->_properties addObject:p];
		[p cd_setEntity:e];
		[p release];
	}
	for (i = 0; i < [_subentities count]; i++) {
		NSEntityDescription *child = [[_subentities objectAtIndex:i] copy];
		child->_superentity = e;
		[e->_subentities addObject:child];
		[child release];
	}
	return e;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:_name forKey:@"name"];
	[coder encodeObject:_managedObjectClassName forKey:@"managedObjectClassName"];
	[coder encodeObject:_renamingIdentifier forKey:@"renamingIdentifier"];
	[coder encodeObject:_versionHashModifier forKey:@"versionHashModifier"];
	[coder encodeObject:_userInfo forKey:@"userInfo"];
	[coder encodeObject:_properties forKey:@"properties"];
	[coder encodeObject:_subentities forKey:@"subentities"];
	[coder encodeBool:_abstract forKey:@"abstract"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super init];
	if (self != nil) {
		NSUInteger i;
		_name = [[coder decodeObjectForKey:@"name"] retain];
		if (_name == nil) { _name = @""; }
		_managedObjectClassName = [[coder decodeObjectForKey:@"managedObjectClassName"] retain];
		if (_managedObjectClassName == nil) { _managedObjectClassName = @"NSManagedObject"; }
		_renamingIdentifier = [[coder decodeObjectForKey:@"renamingIdentifier"] retain];
		_versionHashModifier = [[coder decodeObjectForKey:@"versionHashModifier"] retain];
		_userInfo = [[coder decodeObjectForKey:@"userInfo"] retain];
		_abstract = [coder decodeBoolForKey:@"abstract"];
		_properties = [[NSMutableArray alloc] initWithArray:[coder decodeObjectForKey:@"properties"]];
		_subentities = [[NSMutableArray alloc] init];
		for (i = 0; i < [_properties count]; i++) {
			[[_properties objectAtIndex:i] cd_setEntity:self];
		}
		{
			NSArray *children = [coder decodeObjectForKey:@"subentities"];
			for (i = 0; i < [children count]; i++) {
				[_subentities addObject:[children objectAtIndex:i]];
			}
			for (i = 0; i < [_subentities count]; i++) {
				((NSEntityDescription *)[_subentities objectAtIndex:i])->_superentity = self;
			}
		}
	}
	return self;
}

@end
