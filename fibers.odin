package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:math/rand"
import "core:mem"
import "core:thread"
import "core:time"

when ODIN_OS == .Windows {
	when ODIN_ARCH == .amd64 {
		foreign import fiber_helpers "fibers_windows_amd64.asm"
	}
}

@(default_calling_convention = "c")
foreign fiber_helpers {
	get_fiber_context :: proc(c: ^FiberContext) ---
	set_fiber_context :: proc(c: ^FiberContext) ---

	// Stores the current context into old, and sets the context to new.
	swap_fiber_context :: proc(old: ^FiberContext, new: ^FiberContext) ---
}

when ODIN_OS == .Windows {
	when ODIN_ARCH == .amd64 {
		FiberContext :: struct {
			rip, rsp:                          rawptr,
			rbx, rbp, r12, r13:                rawptr,
			r14, r15, rdi, rsi:                rawptr,

            // WINDOWS ABI ONLY
			xmm6, xmm7, xmm8, xmm9, xmm10:     [2]u64,
			xmm11, xmm12, xmm13, xmm14, xmm15: [2]u64,
		}
	}
}

TaskId :: int
Task :: struct {
	using decl: TaskDecl,
}

@(thread_local)
_worker_state_tls: ^WorkerThread

WorkerThread :: struct {
	init_fiber_context: FiberContext,
	current_fiber:      FiberId,
	ready_tasks:        Deque(Task),
}

foo :: proc "contextless" (data: rawptr) {
	context = runtime.default_context()
	fmt.println("Hello from fiber!")
}

main :: proc() {
	_worker_state_tls = &WorkerThread{}

    counter := run_task({
        foo,
        nil,
    })

    wait_for_counter(counter)
}

FiberId :: int
CounterId :: int

Fiber :: struct {
	ctx:   FiberContext,
	stack: ^u8,
}

Counter :: struct {
	count:              int, // atomic
	waiting_fiber_head: int,
}

WaitingFiber :: struct {
	fiber: FiberId,
	next:  int,
}

TaskScheduler :: struct {
	fibers:         Pool(160, Fiber),
	waiting_fibers: Pool(160, WaitingFiber),
	counters:       Pool(1024, Counter),
	workers:        []WorkerThread,
}

TaskDecl :: struct {
	procedure: proc "contextless" (data: rawptr),
	data:      rawptr,
}

scheduler: TaskScheduler

run_task :: proc(decl: TaskDecl) -> CounterId {
	counter, counter_id, counter_ok := pool_pop(&scheduler.counters)
	assert(counter_ok)

	intrinsics.atomic_store_explicit(&counter.count, 1, .Relaxed)

	deque_push_bottom(&_worker_state_tls.ready_tasks, Task{decl = decl})

	return counter_id
}

wait_for_counter :: proc(id: CounterId) {
	counter := pool_get(&scheduler.counters, id)
	count := intrinsics.atomic_load_explicit(&counter.count, .Relaxed)

	// Fast path
	if count == 0 {
		return
	}

	// Add current fiber to the counter's wait list
	{
		node_ptr, idx, ok := pool_pop(&scheduler.waiting_fibers)
		assert(ok)

		node_ptr.fiber = _worker_state_tls.current_fiber

		for {
			old_head := intrinsics.atomic_load_explicit(&counter.waiting_fiber_head, .Acquire)
			node_ptr.next = old_head
			if _, ok := intrinsics.atomic_compare_exchange_weak_explicit(
				&counter.waiting_fiber_head,
				old_head,
				idx,
				.Acq_Rel,
				.Acquire,
			); ok {
				break
			}
		}
	}

    // Switch to next ready task
    switch_to_next_ready_task()
}

fiber_exit :: proc "contextless" () {
    // Release this fiber, switch to next ready task.
    context = runtime.default_context()

	if _worker_state_tls.current_fiber != -1 {
        pool_release(&scheduler.fibers, _worker_state_tls.current_fiber)
        _worker_state_tls.current_fiber = -1

        switch_to_next_ready_task()
    } else {
        unreachable()
    }
}

switch_to_next_ready_task  :: proc() {
	task, task_ok := deque_pop_bottom(&_worker_state_tls.ready_tasks)
	if task_ok {
		new_fiber, new_fiber_id, new_fiber_ok := pool_pop(&scheduler.fibers)
		assert(new_fiber_ok, "No fibers are available.")

		// Allocate stack
		if new_fiber.stack == nil {
			stack, err := mem.alloc_bytes(4096)
			assert(err == .None)

			new_fiber.stack = cast(^u8)raw_data(stack)
		}

        new_fiber.ctx = make_fiber_context(task.procedure, new_fiber.stack, 4096)

        if _worker_state_tls.current_fiber == -1 {
            old_fiber := pool_get(&scheduler.fibers, _worker_state_tls.current_fiber)
            _worker_state_tls.current_fiber = new_fiber_id

            swap_fiber_context(&old_fiber.ctx, &new_fiber.ctx)
        } else {
            set_fiber_context(&new_fiber.ctx)
        }
	} else {
		// Steal task TODO
        // Assuming there are no more tasks left... spinlock?
		unreachable()
	}
}

make_fiber_context :: proc(
	proc_ptr: proc "contextless" (data: rawptr),
	stack_ptr: ^u8,
	stack_len: int,
) -> FiberContext {
	sp := mem.ptr_offset(stack_ptr, stack_len)

	// Align stack pointer on 16-byte boundary.
	sp = cast(^u8)mem.align_backward(sp, 16)

	// win64: reserve 32 bytes of shadow space
	sp = mem.ptr_offset(sp, -32)

	sp = mem.ptr_offset(sp, -size_of(^u8))
	(cast(^proc "contextless" ())sp)^ = fiber_exit

	c: FiberContext
	c.rip = cast(rawptr)proc_ptr
	c.rsp = sp

	return c
}
