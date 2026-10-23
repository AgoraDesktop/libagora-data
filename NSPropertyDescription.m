/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSPropertyDescription.m — the flags, the validation pair, and the version hash every subclass inherits.
 */

#import <CoreData/NSPropertyDescription.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSArray.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSCoder.h>
#import <Foundation/NSException.h>

@implementation NSPropertyDescription

- (id)init
{
	self = [super init];
	if (self != nil) {
		_name = @"";
		_optional = YES;	/* Apple's default: a property is optional unless the model says otherwise */
	}
	return self;
}

- (void)dealloc
{
	[_name release];
	[_renamingIdentifier release];
	[_versionHashModifier release];
	[_validationPredicates release];
	[_validationWarnings release];
	[_userInfo release];
	[super dealloc];
}

- (NSEntityDescription *)entity { return _entity; }

- (NSString *)name { return _name; }
- (void)setName:(NSString *)name
{
	NSString *copy = (name != nil) ? [[NSString alloc] initWithString:name] : [[NSString alloc] initWithString:@""];
	[_name release];
	_name = copy;
}

- (BOOL)isOptional { return _optional; }
- (void)setOptional:(BOOL)flag { _optional = flag; }

- (BOOL)isTransient { return _transient; }
- (void)setTransient:(BOOL)flag { _transient = flag; }

- (NSArray *)validationPredicates { return _validationPredicates; }
- (NSArray *)validationWarnings { return _validationWarnings; }

- (void)setValidationPredicates:(NSArray *)validationPredicates
        withValidationWarnings:(NSArray *)validationWarnings
{
	/* THE TWO ARRAYS ARE PARALLEL BY CONTRACT: predicate i produces warning i. A mismatched pair is a model
	 * error, and it is caught here rather than at the first failed save. */
	if ((validationPredicates == nil) != (validationWarnings == nil) ||
	    [validationPredicates count] != [validationWarnings count]) {
		[NSException raise:NSInvalidArgumentException
		            format:@"NSPropertyDescription: %lu validation predicates but %lu warnings",
		                   (unsigned long)[validationPredicates count],
		                   (unsigned long)[validationWarnings count]];
	}
	[_validationPredicates release];
	[_validationWarnings release];
	_validationPredicates = (validationPredicates != nil)
	    ? [[NSMutableArray alloc] initWithArray:validationPredicates] : nil;
	_validationWarnings = (validationWarnings != nil)
	    ? [[NSMutableArray alloc] initWithArray:validationWarnings] : nil;
}

- (NSDictionary *)userInfo { return _userInfo; }
- (void)setUserInfo:(NSDictionary *)dictionary
{
	NSDictionary *copy = (dictionary != nil) ? [[NSDictionary alloc] initWithDictionary:dictionary] : nil;
	[_userInfo release];
	_userInfo = (NSMutableDictionary *)copy;
}

- (BOOL)isIndexed { return _indexed; }
- (void)setIndexed:(BOOL)flag { _indexed = flag; }

- (NSString *)versionHashModifier { return _versionHashModifier; }
- (void)setVersionHashModifier:(NSString *)modifierString
{
	NSString *copy = (modifierString != nil) ? [[NSString alloc] initWithString:modifierString] : nil;
	[_versionHashModifier release];
	_versionHashModifier = copy;
}

- (BOOL)isIndexedBySpotlight { return _indexedBySpotlight; }
- (void)setIndexedBySpotlight:(BOOL)flag { _indexedBySpotlight = flag; }

- (BOOL)isStoredInExternalRecord { return _storedInExternalRecord; }
- (void)setStoredInExternalRecord:(BOOL)flag { _storedInExternalRecord = flag; }

- (NSString *)renamingIdentifier { return _renamingIdentifier; }
- (void)setRenamingIdentifier:(NSString *)value
{
	NSString *copy = (value != nil) ? [[NSString alloc] initWithString:value] : nil;
	[_renamingIdentifier release];
	_renamingIdentifier = copy;
}

/* ---- the hash ------------------------------------------------------------------------------------ */

- (void)cd_setEntity:(NSEntityDescription *)entity { _entity = entity; }

- (NSString *)cd_kind { return @"property"; }
- (NSString *)cd_details { return @""; }

- (NSData *)versionHash
{
	/* SORTED AND EXPLICIT, never a dictionary description: the digest has to be reproducible byte for byte on
	 * another machine, another run and another locale, or every store on disk "changes schema" after a rebuild. */
	NSString *canonical = [NSString stringWithFormat:
	    @"P|kind=%@|name=%@|optional=%d|transient=%d|indexed=%d|spotlight=%d|external=%d|modifier=%@|%@",
	    [self cd_kind], _name, (int)_optional, (int)_transient, (int)_indexed,
	    (int)_indexedBySpotlight, (int)_storedInExternalRecord,
	    (_versionHashModifier != nil) ? _versionHashModifier : @"", [self cd_details]];

	return CDVersionHashOfCanonicalString(canonical);
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@: %@>", [self cd_kind], _name];
}

/*
 * THE OVERRIDE POINT IS `-copy`, NOT `-copyWithZone:`: libagora-base removed every NSZone-taking method
 * (NSObject.h's copying-protocol note records the decision), so a class that can be copied implements `-copy`.
 * A Cocoa class implementing `-copyWithZone:` would not conform to this Foundation's NSCopying at all.
 */
- (id)copy
{
	NSPropertyDescription *p = [[[self class] alloc] init];
	p->_name = [_name retain];
	p->_renamingIdentifier = [_renamingIdentifier retain];
	p->_versionHashModifier = [_versionHashModifier retain];
	p->_validationPredicates = [_validationPredicates retain];
	p->_validationWarnings = [_validationWarnings retain];
	p->_userInfo = [_userInfo retain];
	p->_optional = _optional;
	p->_transient = _transient;
	p->_indexed = _indexed;
	p->_indexedBySpotlight = _indexedBySpotlight;
	p->_storedInExternalRecord = _storedInExternalRecord;
	return p;
}

- (void)encodeWithCoder:(NSCoder *)coder
{
	[coder encodeObject:_name forKey:@"name"];
	[coder encodeObject:_renamingIdentifier forKey:@"renamingIdentifier"];
	[coder encodeObject:_versionHashModifier forKey:@"versionHashModifier"];
	[coder encodeObject:_validationPredicates forKey:@"validationPredicates"];
	[coder encodeObject:_validationWarnings forKey:@"validationWarnings"];
	[coder encodeObject:_userInfo forKey:@"userInfo"];
	[coder encodeBool:_optional forKey:@"optional"];
	[coder encodeBool:_transient forKey:@"transient"];
	[coder encodeBool:_indexed forKey:@"indexed"];
	[coder encodeBool:_indexedBySpotlight forKey:@"indexedBySpotlight"];
	[coder encodeBool:_storedInExternalRecord forKey:@"storedInExternalRecord"];
}

- (id)initWithCoder:(NSCoder *)coder
{
	self = [super init];
	if (self != nil) {
		_name = [[coder decodeObjectForKey:@"name"] retain];
		if (_name == nil) { _name = @""; }
		_renamingIdentifier = [[coder decodeObjectForKey:@"renamingIdentifier"] retain];
		_versionHashModifier = [[coder decodeObjectForKey:@"versionHashModifier"] retain];
		_validationPredicates = [[coder decodeObjectForKey:@"validationPredicates"] retain];
		_validationWarnings = [[coder decodeObjectForKey:@"validationWarnings"] retain];
		_userInfo = [[coder decodeObjectForKey:@"userInfo"] retain];
		_optional = [coder decodeBoolForKey:@"optional"];
		_transient = [coder decodeBoolForKey:@"transient"];
		_indexed = [coder decodeBoolForKey:@"indexed"];
		_indexedBySpotlight = [coder decodeBoolForKey:@"indexedBySpotlight"];
		_storedInExternalRecord = [coder decodeBoolForKey:@"storedInExternalRecord"];
	}
	return self;
}

@end
