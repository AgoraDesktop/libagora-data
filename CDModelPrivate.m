/*
 * Copyright © 2026 Kyle J. Cardoza.
 * SPDX-FileCopyrightText: 2026 Kyle J. Cardoza
 * SPDX-License-Identifier: LGPL-3.0-or-later
 */
/*
 * CDModelPrivate.m — SHA-256 through the same system OpenSSL the rest of the tree uses (libagora-base's
 * WebSocket handshake takes SHA1 from it). Agora does not vendor or pin a crypto library, and one digest for a
 * version hash is not a reason to start.
 */

#import <CoreData/CDModelPrivate.h>
#import <Foundation/NSString.h>
#import <Foundation/NSData.h>
#include <openssl/sha.h>

NSData *CDVersionHashOfCanonicalString(NSString *canonical)
{
	const char *bytes = [canonical UTF8String];
	unsigned char digest[SHA256_DIGEST_LENGTH];

	if (bytes == NULL) {
		bytes = "";
	}
	SHA256((const unsigned char *)bytes, strlen(bytes), digest);
	return [[[NSData alloc] initWithBytes:digest length:SHA256_DIGEST_LENGTH] autorelease];
}

NSString *CDHexOfData(NSData *data)
{
	static const char *digits = "0123456789abcdef";
	NSUInteger i, n = [data length];
	const unsigned char *bytes = (const unsigned char *)[data bytes];
	char *out;
	NSString *result;

	if (bytes == NULL || n == 0) {
		return @"";
	}
	out = (char *)malloc((n * 2) + 1);
	if (out == NULL) {
		return @"";
	}
	for (i = 0; i < n; i++) {
		out[i * 2] = digits[(bytes[i] >> 4) & 0xf];
		out[i * 2 + 1] = digits[bytes[i] & 0xf];
	}
	out[n * 2] = '\0';
	result = [[[NSString alloc] initWithUTF8String:out] autorelease];
	free(out);
	return result;
}
