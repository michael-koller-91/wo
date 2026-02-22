#!/usr/bin/env bash
cmd="odin build . -o:speed -show-timings"
echo "$cmd"
eval "$cmd"
