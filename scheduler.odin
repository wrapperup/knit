package knit

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:mem"

@(private, thread_local)
_worker_index: int

TaskId :: int
Task :: struct {
	using decl: TaskDecl,
	counter:    CounterId,
}

Worker :: struct {
	init_fiber_context: FiberContext,
	task_to_start:      Task,
	current_fiber:      FiberId,
	release_fiber:      FiberId,
	ready_fibers:       Deque(FiberId),
}

CounterId :: int
Counter :: struct {
	count:              int, // atomic
	waiting_fiber_head: int,
}

requeue_waiting_fibers :: proc(counter: ^Counter) {
	head := intrinsics.atomic_exchange_explicit(&counter.waiting_fiber_head, -1, .Acq_Rel)
	i := head
	for i != -1 {
		n := pool_get(&_scheduler.waiting_fibers, i)
		next := n.next // store raw next when using NIL scheme

		deque_push_bottom(&get_current_worker().ready_fibers, n.fiber)
		pool_release(&_scheduler.waiting_fibers, i)

		i = next
	}
}

WaitingFiber :: struct {
	fiber: FiberId,
	next:  int, // index = next - 1 (0 is none)
}

TaskScheduler :: struct {
	fibers:         Pool(160, Fiber),
	waiting_fibers: Pool(160, WaitingFiber),
	counters:       Pool(1024, Counter),
	task_queue:     Deque(Task), // TODO: This should probably not live here.
	workers:        []Worker,
	tasks_count:    int,
}

TaskDecl :: struct {
	procedure: proc(data: rawptr),
	data:      rawptr,
}

_scheduler: TaskScheduler

init :: proc(thread_num: int) {
	pool_init(&_scheduler.fibers)
	pool_init(&_scheduler.waiting_fibers)
	pool_init(&_scheduler.counters)
	deque_init(&_scheduler.task_queue, 128)
	_scheduler.tasks_count = 0

	_scheduler.workers = make([]Worker, thread_num)
	for &worker in _scheduler.workers {
		worker.current_fiber = -1
		deque_init(&worker.ready_fibers, 128)
	}

	// TODO: Spin up threads.

	// Main thread gets index 0 always.
	_worker_index = 0
}

get_current_worker :: proc() -> ^Worker {
	return &_scheduler.workers[_worker_index]
}

task_typed :: proc(procedure: proc(_: ^$T), data: ^T = nil) -> TaskDecl {
	return {cast(proc(_: rawptr))procedure, cast(rawptr)data}
}

task_raw :: proc(procedure: proc(_: rawptr), data: rawptr = nil) -> TaskDecl {
	return {procedure, data}
}

task :: proc {
	task_typed,
	task_raw,
}

run_tasks :: proc(decls: []TaskDecl) -> CounterId {
	counter, counter_id, counter_ok := pool_pop(&_scheduler.counters)
	counter.waiting_fiber_head = -1
	assert(counter_ok)

	for decl in decls {
		task := Task {
			decl    = decl,
			counter = counter_id,
		}

		deque_push_bottom(&_scheduler.task_queue, task)
	}

	// Increment counter.
	intrinsics.atomic_add_explicit(&counter.count, len(decls), .Acq_Rel)

	// Increment task counter
	intrinsics.atomic_add_explicit(&_scheduler.tasks_count, len(decls), .Acq_Rel)

	return counter_id
}

wait_for_counter :: proc(id: CounterId) {
	c := pool_get(&_scheduler.counters, id)

	// Fast path
	if intrinsics.atomic_load_explicit(&c.count, .Acquire) == 0 {
		return
	}

	// Only fibers park
	if get_current_worker().current_fiber == -1 {
		swap_to_next_ready_fiber(release_old_fiber = false)
		cleanup_released_fiber()
		return
	}

    // Add our fiber to the waiting list for this counter.
    {
        node, idx, ok := pool_pop(&_scheduler.waiting_fibers)
        assert(ok)
        node.fiber = get_current_worker().current_fiber
        node.next = -1
        for {
            old_head := intrinsics.atomic_load_explicit(&c.waiting_fiber_head, .Acquire)
            node.next = old_head
            _, ok := intrinsics.atomic_compare_exchange_weak_explicit(
                &c.waiting_fiber_head,
                old_head,
                idx,
                .Acq_Rel,
                .Acquire,
            )
            if ok {
                break
            }
        }

        // Check if the counter decremented while we were detaching
        if intrinsics.atomic_load_explicit(&c.count, .Acquire) == 0 {
            head := intrinsics.atomic_exchange_explicit(&c.waiting_fiber_head, -1, .Acq_Rel)
            i := head
            for i != -1 {
                n := &_scheduler.waiting_fibers.nodes[i]
                next := n.next
                deque_push_bottom(&get_current_worker().ready_fibers, n.fiber)
                pool_release(&_scheduler.waiting_fibers, i)
                i = next
            }
            return
        }
    }

	assert(get_current_worker().release_fiber != get_current_worker().current_fiber)

	swap_to_next_ready_fiber(release_old_fiber = false)
	cleanup_released_fiber()
}

cleanup_released_fiber :: proc() {
	worker := get_current_worker()
	if worker.release_fiber != -1 {
		pool_release(&_scheduler.fibers, worker.release_fiber)
		worker.release_fiber = -1
	}
}

swap_to_next_ready_fiber :: proc(release_old_fiber := false) {
	worker := get_current_worker()

	if release_old_fiber {
		worker.release_fiber = worker.current_fiber
	} else {
		worker.release_fiber = -1
	}

	// 1) Ready fibers first (do NOT gate on tasks_count)
	if !deque_is_empty(&worker.ready_fibers) {
		new_id, ok := deque_pop_bottom(&worker.ready_fibers)
		assert(ok)
		new_fiber := pool_get(&_scheduler.fibers, new_id)

		was_from_init := worker.current_fiber == -1
		if !was_from_init {
			old := pool_get(&_scheduler.fibers, worker.current_fiber)
			worker.current_fiber = new_id
			swap_fiber_context(&old.ctx, &new_fiber.ctx)
		} else {
			worker.current_fiber = new_id
			swap_fiber_context(&worker.init_fiber_context, &new_fiber.ctx)
		}
		return
	}

	// 2) No ready fibers; try to admit a task
	if task, ok := deque_pop_bottom(&_scheduler.task_queue); ok {
		new_fiber, new_id, got := pool_pop(&_scheduler.fibers, keep_uninitialized = true)
		assert(got, "Increase fiber pool")

		if new_fiber.stack == nil {
			stack, err := mem.alloc_bytes(128 * 64 * 1024)
			assert(err == .None)
			new_fiber.stack = cast(^u8)raw_data(stack)
		}

		new_fiber.ctx = make_fiber_context(_worker_entry, new_fiber.stack, 128 * 64 * 1024)
		worker.task_to_start = task

		was_from_init := worker.current_fiber == -1
		if !was_from_init {
			old := pool_get(&_scheduler.fibers, worker.current_fiber)
			worker.current_fiber = new_id
			swap_fiber_context(&old.ctx, &new_fiber.ctx)
		} else {
			worker.current_fiber = new_id
			swap_fiber_context(&worker.init_fiber_context, &new_fiber.ctx)
		}
		return
	}

	// 3) Nothing to run
	set_fiber_context(&worker.init_fiber_context)
}

check_ctx :: #force_inline proc(c: ^FiberContext) {
	// stack pointer should be 16-aligned after subtracting 8 (call pushes ret)
	assert((uintptr(c.rsp) & 15) == 0 || ((uintptr(c.rsp) - 8) & 15) == 0, "Unaligned RSP")
}

_worker_entry :: proc "contextless" () {
	context = runtime.default_context()

	worker := get_current_worker()
	task := get_current_worker().task_to_start

	cleanup_released_fiber()

	task.procedure(task.data)

	if task.counter != -1 {
		counter := pool_get(&_scheduler.counters, task.counter)
		old_count := intrinsics.atomic_sub(&counter.count, 1)
		if old_count <= 1 {
			requeue_waiting_fibers(counter)
		}
	}

	// Decrement task count
	old_count := intrinsics.atomic_sub_explicit(&_scheduler.tasks_count, 1, .Acq_Rel)
	assert(old_count > 0, "Task count went negative. This shouldn't happen.")

	swap_to_next_ready_fiber(release_old_fiber = true)
}
