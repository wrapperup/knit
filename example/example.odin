package main

import "base:intrinsics"
import "core:fmt"
import "core:math/rand"

import "../"

bar_atomic_counter := 0
foo_atomic_counter := 0

main :: proc() {
	knit.init() // Automatically chooses thread_num = logical processor count

	LEN_A :: 50
	LEN_B :: 2

	ResultType :: [LEN_B][LEN_A]int
	results: ResultType

	bar :: proc(data: ^int) {
        value := data^
        for i in 0..<1000000000 {
            value += 1
        }
        data^ = value
	}

	foo :: proc(data: ^[LEN_A]int) {
		tasks: [LEN_A]knit.TaskDecl
		for &task, i in tasks {
			task = knit.task(bar, &data[i])
		}
		counter := knit.run_tasks(tasks[:])

		knit.wait_for_counter(counter)
	}

	tasks: [LEN_B]knit.TaskDecl
	for &task, i in tasks {
		task = knit.task(foo, &results[i])
	}

	counter_id := knit.run_tasks(tasks[:])
	knit.wait_for_counter(counter_id)

	fmt.println(results)
}
