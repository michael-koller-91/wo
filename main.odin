// TODO: unit test for intersection

package main

import "core:flags"
import "core:fmt"
import "core:mem"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync/chan"
import "core:terminal/ansi"
import "core:text/regex"
import "core:thread"

VERSION :: "0.1.0"
// changelog
// 0.0.2: colors for file path and line number
// 0.0.3: color for content matches
// 0.0.4: multiple threads
// 0.1.0: content pattern is an optional positional argument

NUM_THREADS :: 7

BLUE :: ansi.CSI + ansi.FG_BRIGHT_BLUE + ansi.SGR
GREEN :: ansi.CSI + ansi.FG_BRIGHT_GREEN + ansi.SGR
RED :: ansi.CSI + ansi.FG_BRIGHT_RED + ansi.SGR
RESET :: ansi.CSI + ansi.RESET + ansi.SGR

Task_Data :: struct {
	chan:     chan.Chan(string),
	quiet:    bool,
	cpattern: string,
	ccounter: int,
}

write_examples :: proc() {
	fmt.println("Examples:")

	fmt.println("\tFind all Odin files")
	fmt.println("\t\two \".odin$\"")

	fmt.println("\tFind all Odin files but don't search through .git")
	fmt.println("\t\two \".odin$\" -e:\".git\"")

	fmt.println("\tFind all Odin files that contain 'gingerBill' (with word boundaries)")
	fmt.println("\t\two \".odin$\" -c:\"\\bgingerBill\\b\"")
}

less :: proc(i, j: [2]int) -> (le: bool) {
	le = false
	if i[0] < j[0] {
		le = true
	} else if i[0] == j[0] {
		if i[1] < j[1] {
			le = true
		}
	}
	return
}

interval_union :: proc(intervals: [][2]int) -> [][2]int {
	slice.sort_by(intervals, less)
	merge: [dynamic][2]int
	for interval in intervals {
		if len(merge) == 0 {
			append(&merge, interval)
		} else if merge[len(merge) - 1][1] < interval[0] { 	// no interval overlap
			append(&merge, interval)
		} else { 	// interval overlap
			merge[len(merge) - 1][1] = max(merge[len(merge) - 1][1], interval[1])
		}
	}
	return merge[:]
}

highlight :: proc(
	builder: ^strings.Builder,
	s: string,
	intervals: [][2]int,
	allocator := context.allocator,
) {
	if len(intervals) == 0 {
		strings.write_string(builder, s)
		return
	}
	iu := interval_union(intervals)
	defer delete(iu)
	left := 0
	right := iu[0][0]
	for interval, i in iu {
		strings.write_string(builder, fmt.aprintf("%v", s[left:right], allocator = allocator))
		strings.write_string(
			builder,
			fmt.aprintf("%v%v%v", RED, s[interval[0]:interval[1]], RESET, allocator = allocator),
		)
		left = interval[1]
		if i + 1 == len(iu) {
			right = len(s)
		} else {
			right = iu[i + 1][0]
		}
	}
	strings.write_string(builder, fmt.aprintf("%v", s[left:right], allocator = allocator))
}

file_matcher :: proc(task: thread.Task) {
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
					"[TASK(%v)] context.temp_allocator tracking was active (no missed frees)",
					task.user_index,
				)
			}
			mem.tracking_allocator_destroy(&track)
		}
	}

	when ODIN_DEBUG {fmt.printfln("[TASK(%v)] starting", task.user_index)}
	task_data := cast(^Task_Data)task.data

	cpat, cpat_err := regex.create(task_data.cpattern)
	defer regex.destroy_regex(cpat)
	if cpat_err != nil {
		if task.user_index == 0 {
			fmt.eprintfln(
				"ERROR: Failed to create regular expression from content pattern \"%v\": %v. Maybe escaping is missing?",
				task_data.cpattern,
				cpat_err,
			)
		}
		os.exit(1)
	}

	ccapture := regex.preallocate_capture()
	defer regex.destroy_capture(ccapture)

	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)

	ccounter := 0 // count content hits
	chan_rec := task_data^.chan

	for {
		filepath, ok := chan.recv(chan_rec)
		defer delete(filepath)
		defer free_all(context.temp_allocator)
		if !ok {
			task_data^.ccounter = ccounter
			break
		}
		ccounter += match_file(&cpat, &ccapture, &builder, task_data.quiet, filepath)
	}
	when ODIN_DEBUG {fmt.printfln("[TASK(%v)] channel closed, stopping", task.user_index)}
}

match_file :: proc(
	cpat: ^regex.Regular_Expression,
	ccapture: ^regex.Capture,
	builder: ^strings.Builder,
	quiet: bool,
	filepath: string,
) -> (
	ccounter: int,
) {
	ccounter = 0

	strings.builder_reset(builder)
	filepath_color := fmt.aprintf("%v%v%v", BLUE, filepath, RESET)
	defer delete(filepath_color)

	// get content of files
	file_read, file_read_ok := os.read_entire_file(filepath, context.allocator)
	defer delete(file_read)
	if file_read_ok != os.ERROR_NONE {
		fmt.eprintfln("ERROR: Could not open file %v. %v", filepath, file_read_ok)
		return
	}

	it := string(file_read)
	linenr := 0
	had_match := false
	// search through file and print content matches
	for str in strings.split_lines_after_iterator(&it) {
		linenr += 1
		cnumgrps, cmatch := regex.match(cpat^, str, ccapture)
		if cmatch {
			had_match = true
			ccounter += 1
			strings.write_string(
				builder,
				fmt.aprintf(
					"%v:%v%v%v:",
					filepath_color,
					GREEN,
					linenr,
					RESET,
					allocator = context.temp_allocator,
				),
			)
			highlight(builder, str, ccapture^.pos[:cnumgrps], allocator = context.temp_allocator)
		}
	}

	if !quiet {
		fmt.print(strings.to_string(builder^))
		strings.builder_reset(builder)
	}
	return
}

main2 :: proc() {
	builder := strings.builder_make(context.temp_allocator)

	cpat1, cpat_err1 := regex.create("def.*(foo)")
	s1 := "my def: foo bar"
	s2 := " def: foo"
	s3 := "foo def: bar"
	ss: []string = {s1, s2, s3}
	for s in ss {
		capture, cmatch := regex.match(cpat1, s)
		iu := interval_union(capture.pos)
		highlight(&builder, s, iu)
		fmt.println("s =", strings.to_string(builder))
		strings.builder_reset(&builder)
	}

	s6 := "foo and bar"
	cpat2, cpat_err2 := regex.create("(bar|foo).*(foo|bar)")
	capture, cmatch := regex.match(cpat2, s6)
	fmt.println(capture)

	s := "this sentence is short"
	pos1: []int = {5, 16}
	fmt.printfln("%v%v%v%v%v", s[:pos1[0]], RED, s[pos1[0]:pos1[1]], RESET, s[pos1[1]:])

	pos2: [][2]int = {{5, 13}, {8, 16}}
	fmt.println("pos2 =", pos2)
	fmt.println("union =", interval_union(pos2))

	pos2 = {{5, 6}, {8, 16}}
	fmt.println("pos2 =", pos2)
	fmt.println("union =", interval_union(pos2))

	filepath := "foo/bar/baz"
	linenr := 123
	fmt.printfln("%v%v%v:%v%v%v", BLUE, filepath, RESET, GREEN, linenr, RESET)
}

main :: proc() {
	// allocation tracking
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
				fmt.printfln("=== context.allocator tracking was active (no missed frees) ===")
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
				fmt.printfln(
					"=== context.temp_allocator tracking was active (no missed frees) ===",
				)
			}
			mem.tracking_allocator_destroy(&track2)
		}
	}

	// this is kind of a hack but I don't see how to handle this when a flag is marked required
	if len(os.args) == 2 && os.args[1] == "-v" {
		fmt.printfln("wo %v", VERSION)
		os.exit(0)
	}

	Args :: struct {
		filename_pattern: string `args:"pos=0,required" usage:"Filename pattern. Find every file whose name matches this pattern."`,
		exclude_pattern:  string `args:"name=e" usage:"Exclude pattern. Exclude every file whose path matches this pattern."`,
		content_pattern:  string `args:"pos=1,name=c" usage:"Content pattern. Within every found file, find every line which matches this pattern."`,
		quiet:            bool `args:"name=q" usage:"Quiet mode. Don't print matches, only print the hit count."`,
		version:          bool `args:"name=v" usage:"Print the verison number and exit."`,
	}
	args: Args
	parse_err := flags.parse(&args, os.args[1:])
	switch e in parse_err {
	case flags.Validation_Error:
		flags.write_usage(os.to_stream(os.stdout), Args, os.args[0])
		write_examples()
		fmt.eprintfln("\n[%T] %s", e, e.message)
		os.exit(1)
	case flags.Parse_Error:
		fmt.eprintfln("[%T.%v] %s", e, e.reason, e.message)
		os.exit(1)
	case flags.Open_File_Error:
		fmt.panicf("Unable to open file due to %v", e)
	case flags.Help_Request:
		flags.write_usage(os.to_stream(os.stdout), Args, os.args[0])
		write_examples()
		os.exit(0)
	}

	cwd, cwd_ok := os.get_working_directory(context.allocator)
	defer delete(cwd)
	if cwd_ok != os.ERROR_NONE {
		fmt.eprintfln("ERROR: Could not determine the current working directory. %v", cwd_ok)
	}

	fpat, fpat_err := regex.create(args.filename_pattern, {.No_Capture})
	defer regex.destroy_regex(fpat)
	if fpat_err != nil {
		fmt.eprintfln(
			"ERROR: Failed to create regular expression from filename pattern \"%v\": %v. Maybe escaping is missing?",
			args.filename_pattern,
			fpat_err,
		)
		os.exit(1)
	}

	do_ematch := args.exclude_pattern != ""
	epat, epat_err := regex.create(args.exclude_pattern, {.No_Capture})
	defer regex.destroy_regex(epat)
	if epat_err != nil {
		fmt.eprintfln(
			"ERROR: Failed to create regular expression from exclude pattern \"%v\": %v. Maybe escaping is missing?",
			args.exclude_pattern,
			epat_err,
		)
		os.exit(1)
	}

	do_cmatch := args.content_pattern != ""

	ecapture := regex.preallocate_capture()
	defer regex.destroy_capture(ecapture)

	fcapture := regex.preallocate_capture()
	defer regex.destroy_capture(fcapture)

	fcounter := 0 // count file hits

	c, err := chan.create(chan.Chan(string), context.allocator)
	assert(err == .None)
	defer chan.destroy(c)

	pool: thread.Pool
	thread.pool_init(&pool, context.allocator, NUM_THREADS)
	defer thread.pool_destroy(&pool)

	task_data: [NUM_THREADS]Task_Data
	for i in 0 ..< NUM_THREADS {
		task_data[i] = {
			chan     = c,
			quiet    = args.quiet,
			cpattern = args.content_pattern,
			ccounter = 0,
		}
		thread.pool_add_task(&pool, context.allocator, file_matcher, &task_data[i], i)
	}

	send_chan := chan.as_send(c)
	thread.pool_start(&pool)

	// walk through current directory
	w := os.walker_create(cwd)
	defer os.walker_destroy(&w)
	for walk in os.walker_walk(&w) {
		// only search for regular files
		if walk.type != .Regular {
			continue
		}

		// exclude files not matching the file pattern
		_, fmatch := regex.match(fpat, walk.name, &fcapture)
		if !fmatch {
			continue
		}

		// split into relative path
		filepath, filepath_ok := os.get_relative_path(cwd, walk.fullpath, context.allocator)
		if filepath_ok != os.ERROR_NONE {
			fmt.eprintfln(
				"ERROR: Could not determine the relative file path for %v. %v",
				walk.fullpath,
				filepath_ok,
			)
			continue
		}

		// exclude files matching the exclude pattern
		if do_ematch {
			_, ematch := regex.match(epat, filepath, &ecapture)
			if ematch {
				continue
			}
		}

		fcounter += 1

		if do_cmatch {
			success := chan.send(send_chan, filepath)
			if !success {
				fmt.println("ERROR: Failed to send.")
				os.exit(1)
			}

		} else {
			if !args.quiet {
				fmt.println(filepath)
			}
			delete(filepath)
		}
	}

	chan.close(send_chan)
	thread.pool_finish(&pool)

	ccounter := 0 // count content hits
	for i in 0 ..< NUM_THREADS {
		ccounter += task_data[i].ccounter
	}

	fmt.printf("%v file hits.", fcounter)
	if args.content_pattern != "" {
		fmt.printfln(" %v content hits.", ccounter)
	} else {
		fmt.println()
	}

	free_all(context.temp_allocator)
}
