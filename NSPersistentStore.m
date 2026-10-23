/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
#import <CoreData/NSPersistentStore.h>
#import <CoreData/NSPersistentStoreCoordinator.h>
#import <CoreData/NSManagedObjectModel.h>
#import <CoreData/CoreDataErrors.h>
#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSDictionary.h>
#import <Foundation/NSURL.h>
#import <Foundation/NSError.h>
#include <time.h>
#include <unistd.h>

static NSUInteger CDStoreSequence = 0;

static NSError *CDStoreError(NSInteger code, NSString *why)
{
	return [NSError errorWithDomain:@"NSCocoaErrorDomain" code:code
	                      userInfo:[NSDictionary dictionaryWithObject:why forKey:@"reason"]];
}

@implementation NSPersistentStore

+ (NSDictionary *)metadataForPersistentStoreWithURL:(NSURL *)url error:(NSError **)error
{
	return [NSPersistentStoreCoordinator metadataForPersistentStoreOfType:nil URL:url error:error];
}

+ (BOOL)setMetadata:(NSDictionary *)metadata forPersistentStoreWithURL:(NSURL *)url error:(NSError **)error
{
	return [NSPersistentStoreCoordinator setMetadata:metadata forPersistentStoreOfType:nil
	                                             URL:url error:error];
}

+ (Class)migrationManagerClass
{
	/* NSMigrationManager IS W6's, and answering Nil is the honest form of "not yet": Apple returns the class a
	 * caller should subclass, and there is nothing to subclass. */
	return Nil;
}

- (id)initWithPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)root
                        configurationName:(NSString *)name
                                      URL:(NSURL *)url
                                  options:(NSDictionary *)options
{
	self = [super init];
	if (self != nil) {
		_coordinator = root;
		_configurationName = [name copy];
		_URL = [url retain];
		_options = (options != nil) ? [[NSDictionary alloc] initWithDictionary:options] : [[NSDictionary alloc] init];
		_readOnly = ([[_options objectForKey:NSReadOnlyPersistentStoreOption] boolValue]);
	}
	return self;
}

- (void)dealloc
{
	[_configurationName release];
	[_identifier release];
	[_type release];
	[_URL release];
	[_options release];
	[_metadata release];
	[super dealloc];
}

- (void)cd_setType:(NSString *)type
{
	NSString *copy = (type != nil) ? [type copy] : nil;
	[_type release];
	_type = copy;
}

- (NSManagedObjectModel *)cd_model { return [(id)_coordinator managedObjectModel]; }

- (BOOL)loadMetadata:(NSError **)error
{
	NSMutableDictionary *built = [[NSMutableDictionary alloc] init];

	/* A NEW STORE'S METADATA IS CREATED HERE, and it carries the three keys a coordinator needs to decide whether
	 * the store may be opened: the type, a UUID that names this store in every object ID, and the model's version
	 * hashes (D1-b's digest, §7.1). */
	[built setObject:(_type != nil) ? _type : @"NSUnknownStoreType" forKey:NSStoreTypeKey];
	[built setObject:[NSString stringWithFormat:@"agora-store-%lu-%lu-%lu",
	                  (unsigned long)++CDStoreSequence, (unsigned long)getpid(),
	                  (unsigned long)time(NULL)] forKey:NSStoreUUIDKey];
	if ([self cd_model] != nil) {
		[built setObject:[[self cd_model] entityVersionHashesByName] forKey:NSStoreModelVersionHashesKey];
		if ([[[self cd_model] versionIdentifiers] count] > 0) {
			[built setObject:[[[self cd_model] versionIdentifiers] allObjects]
			          forKey:NSStoreModelVersionIdentifiersKey];
		}
	}
	if (_readOnly && error != NULL) {
		*error = CDStoreError(NSPersistentStoreOperationError, @"a read-only store cannot be created");
		[built release];
		return NO;
	}
	[self setMetadata:built];
	[_identifier release];
	_identifier = [[built objectForKey:NSStoreUUIDKey] copy];
	[built release];
	return YES;
}

- (NSPersistentStoreCoordinator *)persistentStoreCoordinator { return _coordinator; }
- (NSString *)configurationName { return _configurationName; }
- (NSDictionary *)options { return _options; }

- (NSURL *)URL { return _URL; }

- (void)setURL:(NSURL *)url
{
	NSURL *previous = _URL;
	_URL = [url retain];
	[previous release];
}

- (NSString *)identifier { return _identifier; }

- (void)setIdentifier:(NSString *)identifier
{
	NSString *copy = (identifier != nil) ? [identifier copy] : nil;
	[_identifier release];
	_identifier = copy;
}

- (NSString *)type { return _type; }

- (BOOL)isReadOnly { return _readOnly; }
- (void)setReadOnly:(BOOL)flag { _readOnly = flag; }

- (NSDictionary *)metadata { return _metadata; }

- (void)setMetadata:(NSDictionary *)storeMetadata
{
	NSDictionary *copy = (storeMetadata != nil)
	    ? [[NSDictionary alloc] initWithDictionary:storeMetadata] : nil;
	[_metadata release];
	_metadata = copy;
}

- (void)didAddToPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator
{
	(void)coordinator;
}

- (void)willRemoveFromPersistentStoreCoordinator:(NSPersistentStoreCoordinator *)coordinator
{
	(void)coordinator;
}

- (NSString *)description
{
	return [NSString stringWithFormat:@"<%@: %@ %@>", _type, _configurationName, _URL];
}

@end
