/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * CoreDataErrors.h — the 38 error codes and the 7 `userInfo` keys, transcribed from the 10.6 headers.
 *
 * THE SPELLINGS ARE NOT FROM MEMORY. They were read out of the SDK's `CoreDataErrors.h` and then re-read
 * against the generated manifest; `NSValidationMissingMandatoryPropertyError` and
 * `NSValidationMultipleErrorsError` are the two a recollection-based implementation gets wrong, which is exactly
 * why COREDATA-PLAN.md Appendix C names them. A wrong error code is not a cosmetic defect: a client switches on
 * it, and a client that switches on the wrong number refuses the wrong failure.
 *
 * THE CODES ARE APPLE'S NUMBERS. They are in the NSCocoaErrorDomain (Core Data does not declare a domain of its
 * own; `NSCoreDataError` is the umbrella code, not a domain), so `NSError -domain` on a Core Data failure is
 * `NSCocoaErrorDomain` and `-code` is one of these. `NSSQLiteErrorDomain` IS a domain and is declared with the
 * store's codes rather than here.
 *
 * EVERY CODE BELONGS TO A WAVE, and the header says which, because an error declared before the door that
 * produces it is speculation. This header is the exception: it is complete at Phase 0 because it is a
 * transcription, and a transcription that waits for its code is a transcription with no way to check it.
 */

#ifndef COREDATA_COREDATAERRORS_H
#define COREDATA_COREDATAERRORS_H

#import <Foundation/NSError.h>
#import <CoreData/CoreDataDefines.h>

/* Apple's umbrella: the code a Core Data failure reports when no more specific one applies. */
enum {
	NSCoreDataError = 134060,
	NSSQLiteError = 134070
};

/* ---- persistent store (W4, W7) ------------------------------------------------------------------- */
enum {
	NSPersistentStoreOpenError = 134080,
	NSPersistentStoreSaveError,
	NSPersistentStoreOperationError,
	NSPersistentStoreTimeoutError,
	NSPersistentStoreInvalidTypeError,
	NSPersistentStoreTypeMismatchError,
	NSPersistentStoreIncompatibleSchemaError,
	NSPersistentStoreIncompatibleVersionHashError,
	NSPersistentStoreIncompleteSaveError,
	NSPersistentStoreCoordinatorLockingError
};

/* ---- managed object and context (W2, W3) --------------------------------------------------------- */
enum {
	NSManagedObjectValidationError = 1550,
	NSValidationMultipleErrorsError,
	NSValidationMissingMandatoryPropertyError,
	NSValidationRelationshipLacksMinimumCountError,
	NSValidationRelationshipExceedsMaximumCountError,
	NSValidationRelationshipDeniedDeleteError,
	NSValidationNumberTooLargeError,
	NSValidationNumberTooSmallError,
	NSValidationDateTooLateError,
	NSValidationDateTooSoonError,
	NSValidationInvalidDateError,
	NSValidationStringTooLongError,
	NSValidationStringTooShortError,
	NSValidationStringPatternMatchingError
};

enum {
	NSManagedObjectContextLockingError = 132000,
	NSManagedObjectMergeError,
	NSManagedObjectReferentialIntegrityError,
	NSManagedObjectExternalRelationshipError
};

/* ---- migration (W6) ------------------------------------------------------------------------------ */
enum {
	NSMigrationError = 134100,
	NSMigrationCancelledError,
	NSMigrationMissingSourceModelError,
	NSMigrationMissingMappingModelError,
	NSMigrationManagerSourceStoreError,
	NSMigrationManagerDestinationStoreError,
	NSInferredMappingModelError,
	NSEntityMigrationPolicyError,
	NSExternalRecordImportError
};

/* ---- the store's own domain, and the userInfo keys ------------------------------------------------ */
COREDATA_EXTERN NSString *const NSSQLiteErrorDomain
    AVAILABLE_MAC_OS_X_VERSION_10_5_AND_LATER;

COREDATA_EXTERN NSString *const NSAffectedObjectsErrorKey;
COREDATA_EXTERN NSString *const NSAffectedStoresErrorKey;
COREDATA_EXTERN NSString *const NSDetailedErrorsKey;
COREDATA_EXTERN NSString *const NSValidationKeyErrorKey;
COREDATA_EXTERN NSString *const NSValidationObjectErrorKey;
COREDATA_EXTERN NSString *const NSValidationPredicateErrorKey;
COREDATA_EXTERN NSString *const NSValidationValueErrorKey;

#endif /* COREDATA_COREDATAERRORS_H */
