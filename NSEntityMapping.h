/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * NSEntityMapping — how one entity becomes another, or stops existing. W6 of COREDATA-PLAN.md §12.
 *
 * THE TYPE VALUES ARE APPLE'S AND THEY ARE NOT INCREMENTAL IN THE OBVIOUS ORDER: `NSCustomEntityMappingType` is
 * 1 and `NSCopyEntityMappingType` is 4, because the 10.5 additions were numbered after the original three. A
 * mapping's type is archived in a `.cdm` and in an inferred model, so renumbering it would be a source-compatible
 * way to be wrong.
 *
 * THE TWO VERSION HASHES ARE THE POINT OF THE CLASS. A mapping model records the entity hashes it was written
 * against, so W1's D1-b digest is what decides whether a mapping still applies — and a store whose hashes no longer
 * match is refused by name rather than migrated by guess.
 */

#ifndef COREDATA_NSENTITYMAPPING_H
#define COREDATA_NSENTITYMAPPING_H

#import <Foundation/Foundation.h>

typedef NSUInteger NSEntityMappingType;

enum {
	NSUndefinedEntityMappingType = 0x00,
	NSCustomEntityMappingType = 0x01,
	NSAddEntityMappingType = 0x02,
	NSRemoveEntityMappingType = 0x03,
	NSCopyEntityMappingType = 0x04,
	NSTransformEntityMappingType = 0x05
};

@class NSExpression;

@interface NSEntityMapping : NSObject
{
	NSString *_name;
	NSEntityMappingType _mappingType;
	NSString *_sourceEntityName;
	NSData *_sourceEntityVersionHash;
	NSString *_destinationEntityName;
	NSData *_destinationEntityVersionHash;
	NSExpression *_sourceExpression;
	NSArray *_attributeMappings;
	NSArray *_relationshipMappings;
	NSDictionary *_userInfo;
	NSString *_entityMigrationPolicyClassName;
}

- (NSString *)name;
- (void)setName:(NSString *)name;

- (NSEntityMappingType)mappingType;
- (void)setMappingType:(NSEntityMappingType)type;

- (NSString *)sourceEntityName;
- (void)setSourceEntityName:(NSString *)name;
- (NSData *)sourceEntityVersionHash;
- (void)setSourceEntityVersionHash:(NSData *)vhash;

- (NSString *)destinationEntityName;
- (void)setDestinationEntityName:(NSString *)name;
- (NSData *)destinationEntityVersionHash;
- (void)setDestinationEntityVersionHash:(NSData *)vhash;

- (NSArray *)attributeMappings;
- (void)setAttributeMappings:(NSArray *)mappings;
- (NSArray *)relationshipMappings;
- (void)setRelationshipMappings:(NSArray *)mappings;

- (NSExpression *)sourceExpression;
- (void)setSourceExpression:(NSExpression *)source;

- (NSDictionary *)userInfo;
- (void)setUserInfo:(NSDictionary *)dict;

- (NSString *)entityMigrationPolicyClassName;
- (void)setEntityMigrationPolicyClassName:(NSString *)name;

@end

#endif /* COREDATA_NSENTITYMAPPING_H */
