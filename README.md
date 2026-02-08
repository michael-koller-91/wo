# wo

A command line tool written in Odin to find files and file contents matching (Odin) regex patterns.

## Example usage

Print the usage help:
```console
wo -h
```

Find all files ending with `.py`:
```console
wo ".py$"
```

Find all files ending with `.py` but exclude files in the folder `.venv`:
```console
wo ".py$" -e:".venv"
```

In all files ending with `.py` but excluding files in the folder `.venv`, find lines containing `def`:
```console
wo ".py$" -e:".venv" -c:"def"
```

In all files ending with `.py`, find lines containing `def`:
```console
wo ".py$" -c:"def"
```

## Installation
### Build

Run
```console
odin build . -o:speed
```
to get the executable `wo`.

### (Optional) Symlink

Symlink the executable to `/usr/local/bin` to make it available on PATH:
```console
sudo ln -s $PWD/wo /usr/local/bin
```
