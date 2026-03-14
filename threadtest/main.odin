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
					"=== %v task(%v).context.temp_allocator allocations not freed: ===\n",
					len(track.allocation_map),
					task.user_index,
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
					"=== task(%v).context.temp_allocator tracking was active ===",
					task.user_index,
				)
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	when ODIN_DEBUG {fmt.printfln("[TASK(%v)] Starting.", task.user_index)}
	chan_rec := cast(^chan.Chan(string))task.data
	for {
		value, ok := chan.recv(chan_rec^)
		defer delete(value)
		defer free_all(context.temp_allocator)
		if !ok {
			break // More idiomatic than return here
		}
		process_file(value, context.temp_allocator)
	}
	when ODIN_DEBUG {fmt.printfln("[TASK(%v)] Channel closed, stopping.", task.user_index)}
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

	for i in 0 ..< NUM_THREADS {
		thread.pool_add_task(&pool, context.allocator, consumer, &c, i)
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
	//thread.pool_finish(&pool)

	/*
	{
		temp_arena: mem.Dynamic_Arena
		mem.dynamic_arena_init(&temp_arena)
		temp_allocator := mem.dynamic_arena_allocator(&temp_arena)

		temp_track: mem.Tracking_Allocator
		mem.tracking_allocator_init(&temp_track, temp_allocator)
		temp_allocator = mem.tracking_allocator(&temp_track)
		defer mem.dynamic_arena_destroy(&temp_arena)

		defer {
			if len(temp_track.allocation_map) > 0 {
				fmt.eprintf(
					"=== %v temp_allocator (2) allocations not freed: ===\n",
					len(temp_track.allocation_map),
				)
				for _, entry in temp_track.allocation_map {
					fmt.eprintf("- %v bytes @ %v\n", entry.size, entry.location)
				}
			} else {
				fmt.printfln("=== temp_allocator (2) tracking was active ===")
			}
			mem.tracking_allocator_destroy(&temp_track)
		}

		a := fmt.aprintf("foo = %v", 5, allocator = temp_allocator)
		free_all(temp_allocator)
	}
	*/
}
