/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * bench — a MEASUREMENT, not a test: it is built and not registered with `add_test`, and it exists because
 * `ctest` reports pass or fail and §0.12 needed a number. Run it with a size argument.
 */
#include <stdio.h>
#include <time.h>
#include <stdlib.h>

static double Now(void) { struct timespec t; clock_gettime(CLOCK_MONOTONIC,&t); return t.tv_sec + t.tv_nsec/1e9; }

int main(int argc, char **argv)
{
	NSAutoreleasePool *pool = [[NSAutoreleasePool alloc] init];
	NSUInteger n = (argc > 1) ? (NSUInteger)strtoul(argv[1], NULL, 10) : 2000;
	double t;
	NSUInteger i;

	{
		NSMutableSet *set = [[NSMutableSet alloc] init];
		t = Now();
		for (i = 0; i < n; i++) { [set addObject:[NSString stringWithFormat:@"s%lu", (unsigned long)i]]; }
		printf("NSMutableSet addObject %lu strings: %.3fs\n", (unsigned long)n, Now() - t);
		[set release];
	}
	{
		NSMutableDictionary *dict = [[NSMutableDictionary alloc] init];
		t = Now();
		for (i = 0; i < n; i++) {
			[dict setObject:[NSNumber numberWithInteger:(NSInteger)i]
			         forKey:[NSString stringWithFormat:@"k%lu", (unsigned long)i]];
		}
		printf("NSMutableDictionary setObject %lu:   %.3fs\n", (unsigned long)n, Now() - t);
		[dict release];
	}
	{
		NSManagedObjectModel *model = [[[NSManagedObjectModel alloc] init] autorelease];
		NSEntityDescription *entity = [[[NSEntityDescription alloc] init] autorelease];
		NSAttributeDescription *a = [[[NSAttributeDescription alloc] init] autorelease];
		[a setName:@"name"]; [a setAttributeType:NSStringAttributeType];
		[entity setName:@"Person"]; [entity setProperties:[NSArray arrayWithObject:a]];
		[model setEntities:[NSArray arrayWithObject:entity]];

		t = Now();
		for (i = 0; i < n; i++) {
			(void)[[entity propertiesByName] objectForKey:@"name"];
		}
		printf("propertiesByName %lu calls:        %.3fs\n", (unsigned long)n, Now() - t);

		{
			NSMutableArray *objects = [[NSMutableArray alloc] init];
			t = Now();
			for (i = 0; i < n; i++) {
				NSManagedObject *o = [[NSManagedObject alloc] initWithEntity:entity
				                                    insertIntoManagedObjectContext:nil];
				[objects addObject:o];
				[o release];
			}
			printf("NSManagedObject init %lu (no ctx):  %.3fs\n", (unsigned long)n, Now() - t);

			{
				NSManagedObjectContext *ctx = [[NSManagedObjectContext alloc] init];
				t = Now();
				for (i = 0; i < n; i++) { [ctx insertObject:[objects objectAtIndex:i]]; }
				printf("context insertObject %lu:          %.3fs\n", (unsigned long)n, Now() - t);
				[ctx release];
			}
			[objects release];
		}
	}
	printf("done %lu\n", (unsigned long)n);
	[pool release];
	return 0;
}
