#!/usr/bin/env bash
set -x
odin build . -o:speed -show-timings
set +x
