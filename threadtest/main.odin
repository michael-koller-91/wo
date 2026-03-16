package main
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync/chan"
import "core:text/regex"
import "core:thread"

consumer :: proc(task: thread.Task) {
	when ODIN_DEBUG {
		track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track, context.temp_allocator)
		context.temp_allocator = mem.tracking_allocator(&track)

		defer {
			if len(track.allocation_map) > 0 {
				fmt.eprintf(
					"[TASK(%v)] === %v context.temp_allocator allocations not freed: ===\n",
					task.user_index,
					len(track.allocation_map),
				)
				for _, entry in track.allocation_map {
					fmt.eprintf(
						"(%v) - %v bytes @ %v\n",
						task.user_index,
						entry.size,
						entry.location,
					)
				}
			} else {
				fmt.printfln(
					"[TASK(%v)] context.temp_allocator tracking was active",
					task.user_index,
				)
			}
			mem.tracking_allocator_destroy(&track)
		}

		track_allocator: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track_allocator, context.allocator)
		context.allocator = mem.tracking_allocator(&track_allocator)

		defer {
			if len(track_allocator.allocation_map) > 0 {
				fmt.eprintf(
					"[TASK(%v)] === %v context.allocator allocations not freed: ===\n",
					task.user_index,
					len(track_allocator.allocation_map),
				)
				for _, entry in track_allocator.allocation_map {
					fmt.eprintf(
						"(%v) - %v bytes @ %v\n",
						task.user_index,
						entry.size,
						entry.location,
					)
				}
			} else {
				fmt.printfln("[TASK(%v)] context.allocator tracking was active", task.user_index)
			}
			mem.tracking_allocator_destroy(&track_allocator)
		}

	}

	when ODIN_DEBUG {fmt.printfln("[TASK(%v)] starting", task.user_index)}
	chan_rec := cast(^chan.Chan(string))task.data
	for {
		value, ok := chan.recv(chan_rec^)
		defer free_all(context.temp_allocator)
		if !ok {
			break // More idiomatic than return here
		}
		process_file(value, context.temp_allocator)
	}
	when ODIN_DEBUG {fmt.printfln("[TASK(%v)] channel closed, stopping", task.user_index)}
}

process_file :: proc(filepath: string, allocator: mem.Allocator) {
	if !strings.ends_with(filepath, ".txt") {
		return
	}

	file_read, file_read_ok := os.read_entire_file(filepath, allocator)
	if file_read_ok != os.ERROR_NONE {
		fmt.eprintfln("ERROR: Could not open file %v. %v", filepath, file_read_ok)
		return
	}

	asdf := fmt.aprintf("foo bar", allocator = allocator)

	it := string(file_read)
	linecount := 0
	for str in strings.split_lines_after_iterator(&it) {
		linecount += 1
	}
	fmt.printfln("File %v has %v lines.", filepath, linecount)
}

main :: proc() {
	when ODIN_DEBUG {
		track1: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track1, context.allocator)
		context.allocator = mem.tracking_allocator(&track1)

		defer {
			if len(track1.allocation_map) > 0 {
				fmt.eprintf(
					"=== %v context.allocator allocations not freed: ===\n",
					len(track1.allocation_map),
				)
				for _, entry in track1.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			} else {
				fmt.printfln("=== context.allocator tracking was active ===")
			}
			mem.tracking_allocator_destroy(&track1)
		}

		track2: mem.Tracking_Allocator
		mem.tracking_allocator_init(&track2, context.temp_allocator)
		context.temp_allocator = mem.tracking_allocator(&track2)

		defer {
			if len(track2.allocation_map) > 0 {
				fmt.eprintf(
					"=== %v context.temp_allocator allocations not freed: ===\n",
					len(track2.allocation_map),
				)
				for _, entry in track2.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			} else {
				fmt.printfln("=== context.temp_allocator tracking was active ===")
			}
			mem.tracking_allocator_destroy(&track2)
		}
	}


	// fmt.println("threads is supported:", thread.IS_SUPPORTED)

	NUM_THREADS :: 2

	/*
	cpats: [NUM_THREADS]regex.Regular_Expression
	cpat_err: regex.Error
	for i in 0 ..< NUM_THREADS {
		cpats[i], cpat_err = regex.create("def")
	}
	defer for cpat in cpats {
		regex.destroy_regex(cpat)
	}
	*/

	cwd, cwd_ok := os.get_working_directory(context.allocator)
	defer delete(cwd)

	w := os.walker_create(cwd)
	defer os.walker_destroy(&w)

	c, err := chan.create(chan.Chan(string), context.allocator)
	assert(err == .None)
	defer chan.destroy(c)

	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, NUM_THREADS)
	defer thread.pool_destroy(&pool)

	arenas: [NUM_THREADS]mem.Dynamic_Arena
	allocators: [NUM_THREADS]mem.Allocator
	for i in 0 ..< NUM_THREADS {
		mem.dynamic_arena_init(&arenas[i], alignment = 64) // alignment is here due to a bug: https://github.com/odin-lang/Odin/issues/4195
		allocators[i] = mem.dynamic_arena_allocator(&arenas[i])
		thread.pool_add_task(&pool, allocators[i], consumer, &c, i)
	}

	defer for i in 0 ..< NUM_THREADS {
		mem.dynamic_arena_destroy(&arenas[i])
	}

	thread.pool_start(&pool)
	send_chan := chan.as_send(c)

	for walk in os.walker_walk(&w) {
		filepath, filepath_ok := os.get_relative_path(cwd, walk.fullpath, context.temp_allocator)
		success := chan.send(send_chan, filepath)
		if !success {
			fmt.println("[PRODUCER] Failed to send, channel may be closed.")
			return
		}
	}
	defer free_all(context.temp_allocator) // I don't know how to free `filepath` when `context.allocator` is used, so I do this.

	chan.close(send_chan)
	//thread.pool_join(&pool)
	thread.pool_finish(&pool)
}
