/*
 * $Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/lisp/validate.c,v 1.1 1992/07/28 20:15:36 wlott Exp $
 *
 * Memory Validation
 */

#include <stdio.h>
#include "lisp.h"
#include "os.h"
#include "globals.h"
#include "validate.h"

static void ensure_space(lispobj *start, unsigned long size)
{
    if(os_validate((os_vm_address_t)start,(os_vm_size_t)size)==NULL){
	fprintf(stderr,
		"ensure_space: Failed to validate %ld bytes at 0x%08X\n",
		size,
		(unsigned long)start);
	exit(1);
    }
}

void validate(void)
{
#ifdef PRINTNOISE
	printf("Validating memory ...");
	fflush(stdout);
#endif

	/* Read-Only Space */
	read_only_space = (lispobj *) READ_ONLY_SPACE_START;
	ensure_space(read_only_space, READ_ONLY_SPACE_SIZE);

	/* Static Space */
	static_space = (lispobj *) STATIC_SPACE_START;
	ensure_space(static_space, STATIC_SPACE_SIZE);

	/* Dynamic-0 Space */
	dynamic_0_space = (lispobj *) DYNAMIC_0_SPACE_START;
	ensure_space(dynamic_0_space, DYNAMIC_SPACE_SIZE);

	current_dynamic_space = dynamic_0_space;

	/* Dynamic-1 Space */
	dynamic_1_space = (lispobj *) DYNAMIC_1_SPACE_START;
	ensure_space(dynamic_1_space, DYNAMIC_SPACE_SIZE);

	/* Control Stack */
	control_stack = (lispobj *) CONTROL_STACK_START;
	ensure_space(control_stack, CONTROL_STACK_SIZE);

	/* Binding Stack */
	binding_stack = (lispobj *) BINDING_STACK_START;
	ensure_space(binding_stack, BINDING_STACK_SIZE);

	/* Number stack */
	ensure_space((lispobj *)NUMBER_STACK_START, NUMBER_STACK_SIZE);

#ifdef PRINTNOISE
	printf(" done.\n");
#endif
}
