/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * CDSQLPredicate — a predicate tree to a SQL `WHERE` fragment, which is §8.2's table made executable.
 *
 * THE SCHEMA IS ENTITY-ATTRIBUTE-VALUE (`store/sqlite/SCHEMA.md`), so one attribute comparison is not a column test
 * but an EXISTS over `agora_value`. `age >= 50` becomes
 *
 *   EXISTS (SELECT 1 FROM agora_value v WHERE v.entity_id = o.entity_id
 *            AND v.object_key = o.object_key AND v.name = 'age'
 *            AND v.type = 'integer' AND v.ival >= ?)
 *
 * That is more SQL than a column store would need and it is what the documented schema costs; the alternative was a
 * column per attribute, which D1-b rejected because a store nobody can read is the failure mode the whole decision
 * exists to avoid.
 *
 * EVERY VALUE IS A BOUND PARAMETER, never interpolated — §8.2's rule, and the reason is both injection and a typo
 * that would silently compare the wrong thing. Only the attribute NAME is a literal, and it is escaped.
 *
 * THE TRANSLATOR REFUSES WHAT IT CANNOT DO. A relationship quantifier, a FUNCTION expression, a block predicate or a
 * comparison against another key path returns nil, and the caller falls back to the in-memory scan — correct and
 * slow, rather than a SQL clause that means something else.
 */

#ifndef COREDATA_CDSQLPREDICATE_H
#define COREDATA_CDSQLPREDICATE_H

#import <Foundation/Foundation.h>

@class NSEntityDescription;
@class NSPredicate;

/* Returns the fragment to place after `WHERE ... AND`, or nil when the predicate cannot be translated.
 * Bound values are appended to `bindings` in the order their placeholders appear. */
NSString *CDSQLTranslatePredicate(NSPredicate *predicate,
                                  NSEntityDescription *entity,
                                  NSMutableArray *bindings);

#endif /* COREDATA_CDSQLPREDICATE_H */
