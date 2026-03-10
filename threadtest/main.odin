package main
import "base:runtime"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:strings"
import "core:sync/chan"
import "core:thread"

consumer :: proc(task: thread.Task) {
	fmt.println("[CONSUMER] Starting.")
	chan_rec := cast(^chan.Chan(string))task.data
	for {
		value, ok := chan.recv(chan_rec^)
		defer delete(value)
		if !ok {
			break // More idiomatic than return here
		}
		process_file(value)
	}
	fmt.println("[CONSUMER] Channel closed, stopping.")
}

process_file :: proc(filepath: string) {
	if !strings.ends_with(filepath, ".txt") {
		return
	}

	file_read, file_read_ok := os.read_entire_file(filepath, context.allocator)
	defer delete(file_read)
	if file_read_ok != os.ERROR_NONE {
		fmt.eprintfln("ERROR: Could not open file %v. %v", filepath, file_read_ok)
		return
	}

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

	NUM_THREADS :: 8

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

	for i in 0 ..< NUM_THREADS {
		thread.pool_add_task(&pool, context.allocator, consumer, &c)
	}

	thread.pool_start(&pool)
	send_chan := chan.as_send(c)

	for walk in os.walker_walk(&w) {
		filepath, filepath_ok := os.get_relative_path(cwd, walk.fullpath, context.allocator)
		success := chan.send(send_chan, filepath)
		if !success {
			fmt.println("[PRODUCER] Failed to send, channel may be closed.")
			return
		}
	}

	chan.close(send_chan)
	thread.pool_join(&pool)
}
