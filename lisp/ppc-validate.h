/*

 $Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/lisp/ppc-validate.h,v 1.6 2005/09/15 18:26:52 rtoy Exp $

 This code was written as part of the CMU Common Lisp project at
 Carnegie Mellon University, and has been placed in the public domain.

*/

#ifndef _PPC_VALIDATE_H_
#define _PPC_VALIDATE_H_

#ifdef LINKAGE_TABLE
/*
 * This space start better match the value of
 * target-foreign-linkage-space-start defined in sparc/parms.lisp!
 *
 * See the notes there!
 */

#ifdef LinkageSpaceStart
#define FOREIGN_LINKAGE_SPACE_START (LinkageSpaceStart)
#else
#define FOREIGN_LINKAGE_SPACE_START (0x17000000)
#endif
/*
 * This allows for about 510K symbols (assuming each entry is 16 bytes
 * long).  Hope that's enough!  Make sure this doesn't overlap the
 * READ_ONLY_SPACE_START!
 */
#define FOREIGN_LINKAGE_SPACE_SIZE  (0x00800000)	/* 8 MB */
#endif

/* 
 * The read-only space must be in low memory because the BA
 * instruction only has 26-bits to specify the address.  When this is
 * fixed, the read-only space can be moved.  (The BA instruction is
 * used to jump to assembly routines.)
 */
#define READ_ONLY_SPACE_START	(0x01000000)
#define READ_ONLY_SPACE_SIZE	(0x07ff8000)	/* 128 MB, almost */

#define STATIC_SPACE_START  	(0x10000000)
#define STATIC_SPACE_SIZE   	(0x07ff8000)	/* 128 MB, almost */

#define CONTROL_STACK_START 	(0x30000000)
#define CONTROL_STACK_SIZE  	(0x07ff8000)	/* 128 MB, almost */

#define BINDING_STACK_START 	(0x38000000)
#define BINDING_STACK_SIZE  	(0x07ff8000)	/* 128 MB, almost */

#if 0
#define DYNAMIC_0_SPACE_START	(0x40000000)
#define DYNAMIC_1_SPACE_START	(0x48000000)
#define DYNAMIC_SPACE_SIZE  	(0x07fff000)

#define CONTROL_STACK_START 	(0x57000000)
#define CONTROL_STACK_SIZE  	(0x00ff0000)

#define BINDING_STACK_START 	(0x56000000)
#define BINDING_STACK_SIZE  	(0x00ff0000)
#endif

#define DEFAULT_DYNAMIC_SPACE_SIZE (0x08000000)	/* 128 MB */
#define DYNAMIC_0_SPACE_START	(0x40000000)
#define DYNAMIC_1_SPACE_START	(0x60000000)
#define DYNAMIC_SPACE_SIZE  	(0x1fff0000)	/* 512 MB, almost */

#if 0
#define HOLES {0x04ff8000, 0x06ff8000, 0x0aff8000, 0x1fff8000}
#define HOLE_SIZE 0x2000
#endif

#endif /* _PPC_VALIDATE_H_ */
