/* $Header: /Volumes/share2/src/cmucl/cvs2git/cvsroot/src/ldb/Attic/mips-assem.s,v 1.3 1990/03/28 22:49:10 ch Exp $ */
#include <machine/regdef.h>

#include "lisp.h"
#include "lispregs.h"
#include "globals.h"

/*
 * Function to save the global pointer.
 */
	.text
	.globl	current_global_pointer
	.ent	current_global_pointer
current_global_pointer:
	move	v0, gp
	j	ra
	.end	current_global_pointer

/*
 * And a function to restore the global pointer.
 */
	.text
	.globl	set_global_pointer
	.ent	set_global_pointer
set_global_pointer:
	move	gp, a0
	j	ra
	.end	set_global_pointer

#if !defined(s8)
#define s8 $30
#endif

/*
 * Function to transfer control into lisp.
 */
	.text
	.globl	call_into_lisp
	.ent	call_into_lisp
call_into_lisp:
#define framesize 11*4
	subu	sp, framesize
	.frame	sp, framesize, ra
	/* Save all the C regs. */
	.mask	0xd0ff0000, 0
	sw	ra, framesize(sp)
	sw	s8, framesize-4(sp)
	sw	gp, framesize-8(sp)
	sw	s7, framesize-12(sp)
	sw	s6, framesize-16(sp)
	sw	s5, framesize-20(sp)
	sw	s4, framesize-24(sp)
	sw	s3, framesize-28(sp)
	sw	s2, framesize-32(sp)
	sw	s1, framesize-36(sp)
	sw	s0, framesize-40(sp)

	/* Clear descriptor regs */
	move	t0, zero
	move	t1, zero
	move	t2, zero
	move	t3, zero
	move	t4, zero
	move	t5, zero
	move	t6, zero
	move	t7, zero
	move	s0, zero
	move	s1, zero
	move	s2, zero
	move	s3, zero
	move	gp, zero
	move	ra, zero

	.set	noreorder

	/* The saved FLAGS has the pseudo-atomic bit set. */
	li	NULLREG, NIL
	lw	FLAGS, current_flags_register

	/* No longer in foreign call. */
	sw	zero, foreign_function_call_active

	/* Load the rest of the LISP state. */
	lw	ALLOC, current_dynamic_space_free_pointer
	lw	BSP, current_binding_stack_pointer
	lw	CSP, current_control_stack_pointer

	/* Check for interrupt */
	and	FLAGS, (0xffff^(1<<flag_Atomic))
	and	v0, FLAGS, (1<<flag_Interrupted)
	beq	v0, zero, 1f
	nop

	/* We were interrupted. Hit the trap. */
	break	trap_PendingInterrupt
1:

	.set	reorder

	/* Pass in args */
	move	CNAME, $4
	move	LEXENV, $5
	move	ARGS, $6
	sll	NARGS, $7, 2
	lw	A0, 0(ARGS)
	lw	A1, 4(ARGS)
	lw	A2, 8(ARGS)
	lw	A3, 12(ARGS)
	lw	A4, 16(ARGS)
	lw	A5, 20(ARGS)

	/* Calculate LRA */
	la	LRA, lra + type_OtherPointer

	/* Establish context pointers */
	move	OLDCONT, $0 /* C doesn't have a context ptr */
	move	CONT, CSP

	/* Indirect closure */
	lw	CODE, 4-1(LEXENV)

	/* Jump into lisp land. */
	addu	$2, CODE, 6*4 - type_FunctionPointer
	j	$2

	.set	noreorder

	.align	3
lra:
	.word	type_ReturnPcHeader

	/* Multiple value return spot, clear stack */
	move	CSP, ARGS
	nop

	/* Pass one return value back to C land. */
	move	v0, A0

	/* Set pseudo-atomic flag. */
	or	FLAGS, (1<<flag_Atomic)

	/* Save LISP registers. */
	sw	ALLOC, current_dynamic_space_free_pointer
	sw	BSP, current_binding_stack_pointer
	sw	CSP, current_control_stack_pointer
	sw	FLAGS, current_flags_register

	/* Back in foreign function call */
	li	t0, 1
	sw	t0, foreign_function_call_active

	/* Check for interrupt */
	and	FLAGS, (0xffff^(1<<flag_Atomic))
	and	v1, FLAGS, (1<<flag_Interrupted)
	beq	v1, zero, 1f
	nop

	/* We were interrupted. Hit the trap. */
	break	trap_PendingInterrupt
1:

	.set	reorder

	/* Restore C regs */
	lw	ra, framesize(sp)
	lw	s8, framesize-4(sp)
	lw	gp, framesize-8(sp)
	lw	s7, framesize-12(sp)
	lw	s6, framesize-16(sp)
	lw	s5, framesize-20(sp)
	lw	s4, framesize-24(sp)
	lw	s3, framesize-28(sp)
	lw	s2, framesize-32(sp)
	lw	s1, framesize-36(sp)
	lw	s0, framesize-40(sp)

	/* Restore C stack. */
	addu	sp, framesize

	/* Back we go. */
	j	ra

	.end	call_into_lisp

/*
 * Transfering control from Lisp into C
 */
	.text
	.globl	call_into_c
	.ent	call_into_c
call_into_c:
	.set	noreorder
	/* Note: the C stack is already set up. */
	
	/* Set the pseudo-atomic flag. */
	or	FLAGS, (1<<flag_Atomic)

	/* Save lisp state. */
	sw	ALLOC, current_dynamic_space_free_pointer
	sw	BSP, current_binding_stack_pointer
	sw	CSP, current_control_stack_pointer
	sw	FLAGS, current_flags_register

	/* Mark us as in C land. */
	li	t0, 1
	sw	t0, foreign_function_call_active

	/* Restore GP */
	lw	gp, current_global_pointer

	/* Were we interrupted? */
	and	FLAGS, (0xffff^(1<<flag_Atomic))
	and	v1, FLAGS, (1<<flag_Interrupted)
	beq	v1, zero, 1f
	nop

	/* We were interrupted. Hit the trap. */
	break	trap_PendingInterrupt
1:

	.set	reorder

	/* Get first 4 args. */
	lw	a0, 0(sp)
	lw	a1, 4(sp)
	lw	a2, 8(sp)
	lw	a3, 12(sp)

	/* Into C land we go. */
	jal	v0

	/* Clear unsaved descriptor regs */
	move	t0, zero
	move	t1, zero
	move	t2, zero
	move	t3, zero
	move	t4, zero
	move	t5, zero
	move	t6, zero
	move	t7, zero
	move	gp, zero
	move	ra, zero

	.set	noreorder

	/* Restore FLAGS (which set the pseudo-atomic flag) */
	lw	FLAGS, current_flags_register

	/* Mark us at in Lisp land. */
	sw	zero, foreign_function_call_active

	/* Restore other lisp state. */
	lw	ALLOC, current_dynamic_space_free_pointer
	lw	BSP, current_binding_stack_pointer
	lw	CSP, current_control_stack_pointer

	/* Check for interrupt */
	and	FLAGS, (0xffff^(1<<flag_Atomic))
	and	a0, FLAGS, (1<<flag_Interrupted)
	beq	a0, zero, 1f
	nop

	/* We were interrupted. Hit the trap. */
	break	trap_PendingInterrupt
1:

	.set	reorder

	/* Return to LISP. */
	addu	a0, LRA, 4-type_OtherPointer
	j	a0

	.end	call_into_c
