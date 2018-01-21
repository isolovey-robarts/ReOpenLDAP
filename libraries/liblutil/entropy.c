/* $ReOpenLDAP$ */
/* Copyright 1992-2018 ReOpenLDAP AUTHORS: please see AUTHORS file.
 * All rights reserved.
 *
 * This file is part of ReOpenLDAP.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted only as authorized by the OpenLDAP
 * Public License.
 *
 * A copy of this license is available in the file LICENSE in the
 * top-level directory of the distribution or, alternatively, at
 * <http://www.OpenLDAP.org/license.html>.
 */

/* This work was initially developed by Kurt D. Zeilenga for
 * inclusion in OpenLDAP Software based, in part, on publically
 * available works (as noted below).
 */

#include "reldap.h"

#include <ac/string.h>
#include <ac/time.h>
#include <ac/unistd.h>

#ifdef HAVE_PROCESS_H
#include <process.h>
#endif

#include <fcntl.h>

#include <lutil.h>
#include <lutil_md5.h>

/*
 * lutil_entropy() provides nbytes of entropy in buf.
 * Quality offerred is suitable for one-time uses, such as "once" keys.
 * Values may not be suitable for multi-time uses.
 *
 * Note:  Callers are encouraged to provide additional bytes of
 * of entropy in the buf argument.  This information is used in
 * fallback mode to improve the quality of bytes returned.
 *
 * This routinue should be extended to support additional sources
 * of entropy.
 */
int lutil_entropy( unsigned char *buf, ber_len_t nbytes )
{
	if( nbytes == 0 ) return 0;

#ifdef URANDOM_DEVICE
#define URANDOM_NREADS 4
	/* Linux and *BSD offer a urandom device */
	{
		int rc, fd, n=0;

		fd = open( URANDOM_DEVICE, O_RDONLY );

		if( fd < 0 ) return -1;

		do {
			rc = read( fd, buf, nbytes );
			if( rc <= 0 ) break;

			buf+=rc;
			nbytes-=rc;

			if( ++n >= URANDOM_NREADS ) break;
		} while( nbytes > 0 );

		close(fd);
		return nbytes > 0 ? -1 : 0;
	}
#else
	{
		/* based upon Phil Karn's "practical randomness" idea
		 * but implementation 100% OpenLDAP.  So don't blame Phil.
		 *
		 * Worse case is that this is a MD5 hash of a counter, if
		 * MD5 is a strong cryptographic hash, this should be fairly
		 * resistant to attack
		 */

		/*
		 * the caller may need to provide external synchronization OR
		 * provide entropy (in buf) to ensure quality results as
		 * access to this counter may not be atomic.
		 */
		static int counter = 0;
		ber_len_t n;

		struct rdata_s {
			int counter;
			unsigned char *buf;
			struct rdata_s *stack;
			pid_t	pid;
			struct timespec tv;
			unsigned long	junk;	/* purposely not initialized */
		} rdata;

		/* make sure rdata differs for each process */
		rdata.pid = getpid();

		/* make sure rdata differs for each program */
		rdata.buf = buf;
		rdata.stack = &rdata;

		for( n = 0; n < nbytes; n += 16 ) {
			struct lutil_MD5Context ctx;
			unsigned char digest[16];

			/* poor resolution */
			clock_gettime(CLOCK_MONOTONIC, &rdata.tv);

			/* make sure rdata differs */
			rdata.counter = ++counter;
			rdata.pid++;
			rdata.junk++;

			lutil_MD5Init( &ctx );
			lutil_MD5Update( &ctx, (unsigned char *) &rdata, sizeof( rdata ) );

			/* allow caller to provided additional entropy */
			lutil_MD5Update( &ctx, buf, nbytes );

			lutil_MD5Final( digest, &ctx );

			memcpy( &buf[n], digest,
				nbytes - n >= 16 ? 16 : nbytes - n );
		}

		return 0;
	}
#endif
	return -1;
}
