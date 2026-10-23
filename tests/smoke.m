/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * smoke — the Phase 0 library answers the two questions it can answer.
 *
 * IT IS NOT A PLACEHOLDER FOR THE REAL SUITE. COREDATA-PLAN.md §13 puts the behaviour tests in W1 onward, one
 * executable per subject, run twice (in-memory and on-disk) where it can be. This one exists so that the
 * component, its packaging and its include shim are MEASURED from the first commit rather than at W1 -- and so
 * that a header that stops being reachable through the umbrella fails here instead of in a consumer's build.
 */

#import <CoreData/CoreData.h>
#include <stdio.h>

static int failures = 0;
static int checks = 0;

#define CHECK(cond, what) do { \
	checks++; \
	if (!(cond)) { failures++; fprintf(stderr, "FAIL %s:%d  %s\n", __FILE__, __LINE__, (what)); } \
} while (0)

int main(void)
{
	NSString *keys[8];
	NSUInteger i, j;
	NSUInteger distinct = 0;

	/* The umbrella reaches the error header's declarations, and the values are Apple's. */
	CHECK(NSCoreDataError == 134060, "NSCoreDataError carries Apple's number");
	CHECK(NSPersistentStoreIncompatibleVersionHashError > NSPersistentStoreOpenError,
	      "the store codes are ordered as Apple orders them");
	CHECK(NSManagedObjectValidationError == 1550, "the validation block starts at Apple's number");

	keys[0] = NSSQLiteErrorDomain;
	keys[1] = NSAffectedObjectsErrorKey;
	keys[2] = NSAffectedStoresErrorKey;
	keys[3] = NSDetailedErrorsKey;
	keys[4] = NSValidationKeyErrorKey;
	keys[5] = NSValidationObjectErrorKey;
	keys[6] = NSValidationPredicateErrorKey;
	keys[7] = NSValidationValueErrorKey;

	/* Non-empty, and all different: a table of eight names that collapsed to one string would pass a nil check. */
	for (i = 0; i < 8; i++) {
		CHECK(keys[i] != nil && [keys[i] length] > 0, "an error key is non-empty");
		for (j = 0; j < i; j++) {
			CHECK(![keys[i] isEqualToString:keys[j]], "the error keys are distinct");
		}
		if ([keys[i] length] > 0) { distinct++; }
	}
	CHECK(distinct == 8, "all eight error keys are distinct");

	printf("smoke: %d checks, %d failure(s)\n", checks, failures);
	return (failures == 0) ? 0 : 1;
}
