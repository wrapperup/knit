package main

import "core:mem"
import "base:runtime"
import "core:fmt"

original_context: FiberContext

main :: proc() {
   stack: [4096]u8

	fmt.println("Hello from main!")

    ctx := make_fiber_context(foo, &stack[0], 4096)
    swap_fiber_context(&original_context, &ctx)

	fmt.println("exiting from main!")
}

foo :: proc "contextless" (data: rawptr) {
	context = runtime.default_context()
	fmt.println("Hello from fiber!")
    set_fiber_context(&original_context)
}

make_fiber_context :: proc(
	proc_ptr: proc "contextless" (data: rawptr),
	stack_ptr: ^u8,
	stack_len: int,
) -> FiberContext {
	sp := mem.ptr_offset(stack_ptr, stack_len)

	// Align stack pointer on 16-byte boundary.
	sp = cast(^u8)mem.align_backward(sp, 16)

    // Reserve shadow space
	sp = mem.ptr_offset(sp, -32 - 8)

	c: FiberContext
	c.rip = cast(rawptr)proc_ptr
	c.rsp = sp

	return c
}
