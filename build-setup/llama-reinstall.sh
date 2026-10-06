#!/bin/sh
# llama-reinstall: move freshly-installed llama binaries out of ~/.local/bin
# and replace them with thin wrappers that set up the library path.
#
# Why: the installed ELF binaries have no RPATH (CMake clears it at install
# time), so they cannot find the shared libs in ~/.local/lib. Instead of a
# single wrapper for `llama`, we wrap the whole suite here so llama-server,
# llama-bench, etc. all work too. Running this after `cmake --install` makes
# the wrappers immune to the install clobbering them.
#
# Usage:  llama-reinstall        (after `cmake --install build --prefix $HOME/.local`)
set -e

LOCAL_BIN="$HOME/.local/bin"
REAL_DIR="$HOME/.local/lib/llama/bin"
SRC_DIR="$HOME/Documents/code/llama.cpp"

mkdir -p "$REAL_DIR"

# 1. Move every installed llama/test binary from LOCAL_BIN to REAL_DIR.
#    Skip the wrapper infrastructure: llama-reinstall itself, llama-bin (a
#    stale leftover from the old manual wrapper), and any wrapper script.
for f in "$LOCAL_BIN"/llama* "$LOCAL_BIN"/test-*; do
    [ -f "$f" ] || continue
    name="${f##*/}"
    case "$name" in
        llama-reinstall | llama-bin) continue ;;
    esac
    # only move real ELF executables, never wrapper scripts
    if file "$f" | grep -q 'ELF'; then
        mv -f "$f" "$REAL_DIR/$name"
    fi
done
# drop a stale llama-bin if one wandered into REAL_DIR
rm -f "$REAL_DIR/llama-bin"

# 2. Generate a thin wrapper for each real binary.
for f in "$REAL_DIR"/*; do
    [ -f "$f" ] || continue
    name="${f##*/}"
    cat > "$LOCAL_BIN/$name" <<WRAP
#!/bin/sh
# auto-generated wrapper for $name (see llama-reinstall)
export LD_LIBRARY_PATH="$HOME/.local/lib:\$LD_LIBRARY_PATH"
export LLAMA_SRC_DIR="$SRC_DIR"
exec "$REAL_DIR/$name" "\$@"
WRAP
    chmod +x "$LOCAL_BIN/$name"
done

echo "llama-reinstall: wrapped $(ls "$REAL_DIR" | wc -l) binaries"
llama --version