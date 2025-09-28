package main

import "base:intrinsics"
import "core:math/rand"
import "core:testing"
import "core:thread"
import "core:time"

PoolState :: enum u8 {
	Free,
	InUse,
}
#assert(size_of(PoolState) == 1)

PoolHeadIndex :: bit_field u64 {
	index: int | 32,
	gen:   u32 | 32,
}

Pool :: struct($N: int, $T: typeid) {
	nodes: [N]T,
	next:  [N]int,
	head:  PoolHeadIndex, // atomic
	state: [N]PoolState,
}

pool_init :: proc(pool: ^Pool($N, $T)) {
	pool.head.index = 0
	pool.head.gen = 0

	for i in 0 ..< len(pool.next) - 1 {
		pool.next[i] = int(i + 1)
	}

	pool.next[len(pool.next) - 1] = -1
}

pool_pop :: proc(pool: ^Pool($N, $T)) -> (^T, int, bool) {
	for {
		old_head := intrinsics.atomic_load_explicit(&pool.head, .Acquire)
		if old_head.index < 0 {
			return nil, -1, false
		}

		new_head_index := pool.next[old_head.index]
		new_head: PoolHeadIndex
		new_head.index = new_head_index
		new_head.gen = old_head.gen + 1

		if value, ok := intrinsics.atomic_compare_exchange_weak(&pool.head, old_head, new_head);
		   ok {
			pool.nodes[old_head.index] = {}
			pool.state[old_head.index] = .InUse
			return &pool.nodes[old_head.index], old_head.index, true
		}
	}
}

pool_release :: proc(pool: ^Pool($N, $T), index: int) {
	assert(pool.state[index] == .InUse, "Double free")

	pool.state[index] = .Free

	for {
		old_head := intrinsics.atomic_load(&pool.head)
		pool.next[index] = old_head.index

		new_head: PoolHeadIndex
		new_head.index = index
		new_head.gen = old_head.gen + 1

		if value, ok := intrinsics.atomic_compare_exchange_weak(&pool.head, old_head, new_head);
		   ok {
			return
		}
	}
}

pool_get :: proc(pool: ^Pool($N, $T), index: int) -> ^T {
	return &pool.nodes[index]
}

@(test)
stress_pool_with_threads :: proc(t: ^testing.T) {
	TestingStruct :: struct {
		a: u32,
		b: bool,
	}

	test: Pool(16, TestingStruct)
	pool_init(&test)

	thread_pool: thread.Pool
	thread.pool_init(&thread_pool, context.allocator, 10)

	worker_proc :: proc(task: thread.Task) {
		test := cast(^Pool(16, TestingStruct))task.data
		for i in 0 ..< 100_000 {
			_, a_handle, a_ok := pool_pop(test)
			if a_ok {
				time.sleep(time.Duration(rand.int63() % 100))
				pool_release(test, a_handle)
			}
		}
	}

	for i in 0 ..< 10 {
		thread.pool_add_task(&thread_pool, context.allocator, worker_proc, &test)
	}

	thread.pool_start(&thread_pool)
	thread.pool_finish(&thread_pool)
	thread.pool_destroy(&thread_pool)
}
