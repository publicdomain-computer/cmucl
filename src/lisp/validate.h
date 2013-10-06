/*

 This code was written as part of the CMU Common Lisp project at
 Carnegie Mellon University, and has been placed in the public domain.

*/

#ifndef _VALIDATE_H_
#define _VALIDATE_H_

#ifdef parisc
#include "hppa-validate.h"
#endif

#ifdef mips
#include "mips-validate.h"
#endif

#ifdef ibmrt
#include "rt-validate.h"
#endif

#ifdef sparc
#include "sparc-validate.h"
#endif

#if defined(i386) || defined(__x86_64)
#include "x86-validate.h"
#endif

#ifdef alpha
#include "alpha-validate.h"
#endif

#ifdef ppc
#include "ppc-validate.h"
#endif

extern void validate(void);

#endif /* _VALIDATE_H_ */
