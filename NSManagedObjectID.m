/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSManagedObjectID.h>
#import <CoreData/NSEntityDescription.h>
#import <Foundation/NSString.h>
#import <Foundation/NSNumber.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSException.h>

@implementation NSManagedObjectID

- (id)initWithEntity:(NSEntityDescription *)entity
      persistentStore:(id)store
          primaryKey:(id)key
           temporary:(BOOL)temporary
{
	self = [super init];
	if (self != nil) {
		_entity = entity;
		_store = store;
		_primaryKey = [key retain];
		_temporary = temporary;
	}
	return self;
}

- (void)dealloc { [_primaryKey release]; [super dealloc]; }

- (NSEntityDescription *)entity { return _entity; }
- (NSPersistentStore *)persistentStore { return _store; }
- (id)primaryKey { return _primaryKey; }
- (BOOL)isTemporaryID { return _temporary; }

- (NSURL *)URIRepresentation
{
	/* `<store>` is a UUID once a store exists (W4); until then the empty component is honest about there being no
	 * store yet, which is exactly the state a temporary ID describes. */
	NSString *store = @"";
	NSString *identifier;

	if (_store != nil && [_store respondsToSelector:@selector(identifier)]) {
		store = [NSString stringWithFormat:@"%@", [_store identifier]];
	}
	identifier = [NSString stringWithFormat:@"x-coredata://%@/%@/%@%@",
	              store, [_entity name], _temporary ? @"t" : @"p", _primaryKey];
	return [NSURL URLWithString:identifier];
}

- (BOOL)isEqual:(id)other
{
	NSManagedObjectID *o = other;

	if (o == self) {
		return YES;
	}
	if (o == nil || ![o isKindOfClass:[NSManagedObjectID class]]) {
		return NO;
	}
	if (_temporary != o->_temporary || _store != o->_store) {
		return NO;	/* a temporary ID never equals a permanent one, and IDs from two stores never agree */
	}
	if (_entity != o->_entity && ![[_entity name] isEqualToString:[o->_entity name]]) {
		return NO;
	}
	return (_primaryKey == o->_primaryKey) || [_primaryKey isEqual:o->_primaryKey];
}

- (NSUInteger)hash
{
	/* THE ENTITY NAME, NOT THE ENTITY: two models that describe the same entity must be able to agree that two
	 * IDs name the same row, and hashing a pointer would make that impossible across a model reload. */
	return [[_entity name] hash] ^ [_primaryKey hash] ^ (NSUInteger)_temporary;
}

- (id)copyWithZone:(NSZone *)zone
{
	(void)zone;
	return [self retain];
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<NSManagedObjectID: %@ %@%@>",
	         [_entity name], _temporary ? @"temporary " : @"", _primaryKey];
}

@end
