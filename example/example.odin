package main

import "core:math/rand"
import "core:fmt"

import "../"

main :: proc() {
	knit.init(10)

    LEN_A :: 5
    LEN_B :: 5

    ThingType :: [LEN_A][LEN_B]int
	thing: ThingType

    bar :: proc(data: ^int) {
        data^ = cast(int)rand.int63()
        fmt.println("Hello from bar!")
    }

    foo :: proc(data: ^[LEN_A]int) {
        fmt.println("Hello from foo!")
        
        tasks: [LEN_B]knit.TaskDecl
        for &task, i in tasks {
            task = knit.task(bar, &data[i])
        }
        counter := knit.run_tasks(tasks[:])

        knit.wait_for_counter(counter)
    }

    tasks: [5]knit.TaskDecl
    for &task, i in tasks {
        task = knit.task(foo, &thing[i])
    }

    counter := knit.run_tasks(tasks[:])
	knit.wait_for_counter(counter)

    fmt.println(thing)
}
