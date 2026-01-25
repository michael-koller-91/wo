package main

import "core:flags"
import "core:fmt"
import "core:os"
import "core:os/os2"
import "core:strings"
import "core:text/regex"

VERSION := "0.0.1"

write_examples :: proc() {
	fmt.println("Examples:")

	fmt.println("\tFind all Odin files")
	fmt.println("\t\two \".*.odin$\"")

	fmt.println("\tFind all Odin files but don't search through .git")
	fmt.println("\t\two \".*.odin$\" -e:\".git\"")

	fmt.println("\tFind all Odin files that contain 'gingerBill' (with word boundaries)")
	fmt.println("\t\two \".*.odin$\" -c:\"\\bgingerBill\\b\"")
}

main :: proc() {
	// this is kind of a hack but I don't see how to handle this when a flag is marked required
	if len(os.args) == 2 && os.args[1] == "-v" {
		fmt.printfln("wo %v", VERSION)
		os.exit(0)
	}

	Args :: struct {
		filename_pattern: string `args:"pos=0,required" usage:"Filename pattern. Find every file whose name matches this pattern."`,
		exclude_pattern:  string `args:"name=e" usage:"Exclude pattern. Exclude every file whose path matches this pattern."`,
		content_pattern:  string `args:"name=c" usage:"Content pattern. Within every found file, find every line which matches this pattern."`,
		quiet:            bool `args:"name=q" usage:"Quiet mode. Don't print matches, only print the hit count."`,
		version:          bool `args:"name=v" usage:"Print the verison number and exit."`,
	}
	args: Args
	parse_err := flags.parse(&args, os.args[1:])
	switch e in parse_err {
	case flags.Validation_Error:
		flags.write_usage(os.stream_from_handle(os.stdout), Args, os.args[0])
		write_examples()
		fmt.eprintfln("\n[%T] %s", e, e.message)
		os.exit(1)
	case flags.Parse_Error:
		fmt.eprintfln("[%T.%v] %s", e, e.reason, e.message)
		os.exit(1)
	case flags.Open_File_Error:
		fmt.eprintfln(
			"[%T#%i] Unable to open file with perms 0o%o in mode 0x%x: %s",
			e,
			e.errno,
			e.perms,
			e.mode,
			e.filename,
		)
		os.exit(1)
	case flags.Help_Request:
		flags.write_usage(os.stream_from_handle(os.stdout), Args, os.args[0])
		write_examples()
		os.exit(0)
	}

	fpat, fpat_err := regex.create(args.filename_pattern, {.No_Capture})
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
	if epat_err != nil {
		fmt.eprintfln(
			"ERROR: Failed to create regular expression from exclude pattern \"%v\": %v. Maybe escaping is missing?",
			args.exclude_pattern,
			epat_err,
		)
		os.exit(1)
	}

	do_cmatch := args.content_pattern != ""
	cpat, cpat_err := regex.create(args.content_pattern, {.No_Capture})
	if cpat_err != nil {
		fmt.eprintfln(
			"ERROR: Failed to create regular expression from content pattern \"%v\": %v. Maybe escaping is missing?",
			args.content_pattern,
			cpat_err,
		)
		os.exit(1)
	}

	cwd, cwd_ok := os2.get_working_directory(context.allocator)
	if cwd_ok != os2.ERROR_NONE {
		fmt.eprintfln("ERROR: Could not determine the current working directory. %v", cwd_ok)
	}
	if !args.quiet {
		fmt.printfln("Searching through %v\n", cwd)
	}

	fcounter := 0 // count file hits
	ccounter := 0 // count content hits

	// walk through current directory
	w := os2.walker_create(cwd)
	defer os2.walker_destroy(&w)
	for walk in os2.walker_walk(&w) {
		// only search for regular files
		if walk.type != .Regular {
			continue
		}

		// exclude files not matching the file pattern
		_, fmatch := regex.match(fpat, walk.name)
		if !fmatch {
			continue
		}

		// split into relative path
		filepath, filepath_ok := os2.get_relative_path(cwd, walk.fullpath, context.allocator)
		if filepath_ok != os2.ERROR_NONE {
			fmt.eprintfln(
				"ERROR: Could not determine the relative file path for %v. %v",
				walk.fullpath,
				cwd_ok,
			)
		}

		// exclude files matching the exclude pattern
		if do_ematch {
			_, ematch := regex.match(epat, filepath)
			if ematch {
				continue
			}
		}

		fcounter += 1
		if do_cmatch {
			// get content of files
			file_read, file_read_ok := os.read_entire_file(filepath, context.allocator)
			defer delete(file_read, context.allocator)
			if !file_read_ok {
				fmt.eprintfln("ERROR: Could not open file %v. %v", filepath, file_read_ok)
			}

			it := string(file_read)
			linenr := 0
			had_match := false
			// search through file and print content matches
			for str in strings.split_lines_after_iterator(&it) {
				linenr += 1
				_, cmatch := regex.match(cpat, str)
				if cmatch {
					had_match = true
					ccounter += 1
					if !args.quiet {
						fmt.printf("%v:%d : %v", filepath, linenr, str)
					}
				}
			}
			if !args.quiet {
				// an empty line between files if we print content matches
				if had_match {
					fmt.println()
				}
			}
		} else {
			if !args.quiet {
				fmt.println(filepath)
			}
		}
	}

	fmt.printfln("%v file hits", fcounter)
	if do_cmatch {
		fmt.printfln("%v content hits", ccounter)
	}
}
