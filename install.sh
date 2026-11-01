#!/bin/sh
# Installs (or removes) the tclvenv command on Linux and other POSIX systems.
#
#   sh install.sh                  ask where (when run from a terminal)
#   sh install.sh --user           ~/.local/bin/tclvenv, files in ~/.local/share/tclvenv
#   sh install.sh --user-bin       ~/bin/tclvenv, files in ~/.local/share/tclvenv
#   sudo sh install.sh --system    /usr/local/bin/tclvenv, files in /usr/local/share/tclvenv
#   sh install.sh --prefix DIR     DIR/bin/tclvenv, files in DIR/share/tclvenv
#   sh install.sh --uninstall ...  remove what an install with the same options made
#
# Run with --help for every option. Only POSIX sh and core utilities are used.
set -eu

PROGRAM=tclvenv
MARK="# Installed by tclvenv install.sh"

usage() {
    cat <<'EOF'
Usage: sh install.sh [WHERE] [OPTIONS]

Where (default: ask on a terminal, else --user):
  --user            command in ~/.local/bin, files in ~/.local/share/tclvenv
  --user-bin        command in ~/bin, files in ~/.local/share/tclvenv
  --system          command in /usr/local/bin, files in /usr/local/share/tclvenv
                    (needs root: run with sudo)
  --prefix DIR      command in DIR/bin, files in DIR/share/tclvenv
  --bindir DIR      put the command in DIR (with any of the above)
  --datadir DIR     put tclvenv's files in DIR (with any of the above)

Options:
  --tcl EXECUTABLE  Tcl 8.6+ interpreter that runs tclvenv (default: the first
                    of tclsh, tclsh9.0, tclsh8.6 on PATH); environments use it
                    unless created with --tcl
  --path            add the command's directory to PATH in your shell startup
                    files (~/.profile, and ~/.bashrc and ~/.zshrc if present)
  --no-path         never change startup files (just say what to do)
  --uninstall       remove the command, its files and the PATH lines added
  --force           replace a tclvenv command this script didn't install
  --dry-run         show what would be done, change nothing
  -y, --yes         don't ask; use the defaults for anything not given
  -h, --help        show this help
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'install.sh: %s\n' "$*" >&2; }
die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

# A word for sh: single-quoted, with any ' escaped.
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }

# ~ and ~/... at the start of a path the user typed.
expand() {
    case $1 in
        "~") printf '%s' "$HOME" ;;
        "~/"*) printf '%s/%s' "$HOME" "${1#\~/}" ;;
        *) printf '%s' "$1" ;;
    esac
}

absolute() {
    case $1 in
        /*) printf '%s' "$1" ;;
        *) printf '%s/%s' "$(pwd)" "$1" ;;
    esac
}

interactive() { [ "$YES" = 0 ] && [ -t 0 ] && [ -r /dev/tty ]; }

ask() {
    # ask PROMPT DEFAULT: the answer, or DEFAULT for an empty one.
    printf '%s ' "$1" > /dev/tty
    IFS= read -r answer < /dev/tty || answer=
    [ -n "$answer" ] || answer=$2
    printf '%s' "$answer"
}

run() {
    if [ "$DRY" = 1 ]; then say "would run: $*"; else "$@"; fi
}

# --- Options -----------------------------------------------------------------

WHERE=
BINDIR=
DATADIR=
TCL=
PATHMODE=ask
UNINSTALL=0
FORCE=0
DRY=0
YES=0
PREFIX=

while [ $# -gt 0 ]; do
    case $1 in
        --user|--user-bin|--system) WHERE=${1#--} ;;
        --prefix|--bindir|--datadir|--tcl)
            [ $# -ge 2 ] || die "$1 needs a value"
            case $1 in
                --prefix) WHERE=prefix; PREFIX=$(expand "$2") ;;
                --bindir) BINDIR=$(expand "$2") ;;
                --datadir) DATADIR=$(expand "$2") ;;
                --tcl) TCL=$(expand "$2") ;;
            esac
            shift ;;
        --path) PATHMODE=yes ;;
        --no-path) PATHMODE=no ;;
        --uninstall) UNINSTALL=1 ;;
        --force) FORCE=1 ;;
        --dry-run) DRY=1 ;;
        -y|--yes) YES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; die "unknown option: $1" ;;
    esac
    shift
done

SOURCE=$(CDPATH= cd -P -- "$(dirname -- "$0")" && pwd)
[ -n "${HOME-}" ] || die "HOME is not set"

if [ -z "$WHERE" ]; then
    if interactive && [ -z "$BINDIR$DATADIR" ]; then
        if [ "$UNINSTALL" = 1 ]; then verb=Remove; else verb=Install; fi
        say "$verb tclvenv for:" > /dev/tty
        say "  1) just me, command in ~/.local/bin (recommended)" > /dev/tty
        say "  2) just me, command in ~/bin" > /dev/tty
        say "  3) everyone on this system, in /usr/local (needs root)" > /dev/tty
        say "  4) a directory I choose" > /dev/tty
        case $(ask "Choice [1]:" 1) in
            1) WHERE=user ;;
            2) WHERE=user-bin ;;
            3) WHERE=system ;;
            4) WHERE=prefix; PREFIX=$(expand "$(ask "Directory (command goes in DIR/bin):" "")")
               [ -n "$PREFIX" ] || die "no directory given" ;;
            *) die "no such choice" ;;
        esac
    else
        WHERE=user
    fi
fi

case $WHERE in
    user) dBin=$HOME/.local/bin; dData=$HOME/.local/share/$PROGRAM ;;
    user-bin) dBin=$HOME/bin; dData=$HOME/.local/share/$PROGRAM ;;
    system) dBin=/usr/local/bin; dData=/usr/local/share/$PROGRAM ;;
    prefix) dBin=$PREFIX/bin; dData=$PREFIX/share/$PROGRAM ;;
esac
[ -n "$BINDIR" ] || BINDIR=$dBin
[ -n "$DATADIR" ] || DATADIR=$dData
BINDIR=$(absolute "$BINDIR")
DATADIR=$(absolute "$DATADIR")
COMMAND=$BINDIR/$PROGRAM
MANIFEST=$DATADIR/.install-manifest

NL='
'
case $BINDIR in *:*) die "the command's directory can't go on PATH (it contains ':'): $BINDIR" ;; esac
case $BINDIR$DATADIR in *"$NL"*) die "a directory name contains a newline: choose another" ;; esac

# Startup files get one block per install, marked with the command's
# directory, so installs elsewhere never touch each other's lines.
set_markers() {
    BLOCK_BEGIN="# >>> tclvenv PATH $1 >>>"
    BLOCK_END="# <<< tclvenv PATH $1 <<<"
}
set_markers "$BINDIR"

# Startup files a PATH block may go in: ~/.profile (login shells), and the
# interactive files of bash and zsh when they exist (or are links). System
# installs edit no one's files.
startup_names='.profile .bashrc .zshrc'
startup_wanted() {
    [ "$1" = .profile ] || [ -e "$HOME/$1" ] || [ -L "$HOME/$1" ]
}

# A regular file we may append to (through a link to one), or one we may
# create; never a dangling link, a directory or a read-only file.
can_edit() {
    if [ -L "$1" ] && [ ! -e "$1" ]; then return 1; fi
    if [ -e "$1" ]; then [ -f "$1" ] && [ -w "$1" ]; else [ -w "$(dirname -- "$1")" ]; fi
}

# Removes this install's block from a file. With a second argument of 1,
# also the final newline the install added before the block, if the block
# was still the last thing in the file. Rewrites in place, keeping the
# file's owner, mode and links.
remove_block() {
    [ -f "$1" ] || return 0
    grep -qxF "$BLOCK_BEGIN" "$1" || return 0
    if [ "$DRY" = 1 ]; then say "would remove the PATH lines from $1"; return 0; fi
    can_edit "$1" || { warn "can't change $1: remove the lines between '$BLOCK_BEGIN' and '$BLOCK_END' yourself"; return 0; }
    tmp=$1.tclvenv-tmp
    B=$BLOCK_BEGIN E=$BLOCK_END S=${2:-0} awk '
        BEGIN { b = ENVIRON["B"]; e = ENVIRON["E"]; strip = ENVIRON["S"] == "1" }
        !skip && $0 == b { skip = 1; found = 1; last = 1; next }
        skip { if ($0 == e) skip = 0; next }
        { lines[n++] = $0; if (found) last = 0 }
        END {
            for (i = 0; i < n; i++) {
                printf "%s", lines[i]
                if (i < n - 1 || !(strip && last)) printf "\n"
            }
        }' "$1" > "$tmp"
    cat "$tmp" > "$1"
    rm -f "$tmp"
    say "Removed the PATH lines from $1"
}

on_path() {
    case ":${PATH-}:" in *":$1:"*) return 0 ;; esac
    return 1
}

# --- Uninstall ---------------------------------------------------------------

if [ "$UNINSTALL" = 1 ]; then
    found=0
    # The manifest knows where the command went (for a --bindir install).
    if [ -f "$MANIFEST" ]; then
        recorded=$(sed -n 's/^command //p' "$MANIFEST" | head -n 1)
        if [ -n "$recorded" ]; then COMMAND=$recorded; set_markers "$(dirname -- "$COMMAND")"; fi
    fi
    if [ -f "$COMMAND" ] && grep -qxF "$MARK" "$COMMAND"; then
        run rm -f -- "$COMMAND"; found=1
        [ "$DRY" = 1 ] || say "Removed $COMMAND"
    elif [ -e "$COMMAND" ]; then
        say "Left $COMMAND: this script didn't install it"
    fi
    files=
    newlines=
    if [ -f "$MANIFEST" ]; then
        files=$(sed -n 's/^startup-file //p' "$MANIFEST")
        newlines=$(sed -n 's/^startup-newline //p' "$MANIFEST")
        run rm -rf -- "$DATADIR"; found=1
        [ "$DRY" = 1 ] || say "Removed $DATADIR"
    elif [ -e "$DATADIR" ]; then
        say "Left $DATADIR: it has no install manifest from this script"
    fi
    if [ -n "$files" ]; then
        while IFS= read -r file; do
            strip=0
            case "$NL$newlines$NL" in *"$NL$file$NL"*) strip=1 ;; esac
            remove_block "$file" "$strip"
        done <<LIST
$files
LIST
    fi
    [ "$found" = 1 ] || die "no tclvenv installed by this script at $COMMAND or $DATADIR"
    say "tclvenv is uninstalled. Environments you created still work: each holds its own copy."
    exit 0
fi

# --- Install -----------------------------------------------------------------

[ -f "$SOURCE/tclvenv.tcl" ] && [ -f "$SOURCE/lib/manager.tcl" ] ||
    die "run install.sh from a tclvenv checkout (tclvenv.tcl and lib/ beside it)"

# The interpreter: Tcl 8.6 or newer.
tcl_version() {
    printf 'puts [info patchlevel]\n' | "$1" 2>/dev/null | tail -n 1
}
if [ -n "$TCL" ]; then
    case $TCL in */*) TCL=$(absolute "$TCL") ;; *) TCL=$(command -v "$TCL" 2>/dev/null) || die "no Tcl named $TCL on PATH" ;; esac
else
    for name in tclsh tclsh9.0 tclsh8.6; do
        if found=$(command -v "$name" 2>/dev/null); then TCL=$found; break; fi
    done
    [ -n "$TCL" ] || die "no tclsh found: install Tcl 8.6 or newer (Debian/Ubuntu: sudo apt install tcl) or give --tcl"
fi
[ -x "$TCL" ] || die "not an executable: $TCL"
VERSION=$(tcl_version "$TCL") || VERSION=
case $VERSION in
    8.6*|8.7*|9.*|[1-9][0-9].*) ;;
    "") die "$TCL didn't run as a Tcl interpreter" ;;
    *) die "$TCL is Tcl $VERSION; tclvenv needs 8.6 or newer" ;;
esac

if [ -e "$COMMAND" ] && ! grep -qxF "$MARK" "$COMMAND" 2>/dev/null && [ "$FORCE" = 0 ]; then
    die "$COMMAND exists and this script didn't install it (use --force to replace it)"
fi
if [ -e "$DATADIR" ] && [ ! -f "$MANIFEST" ]; then
    die "$DATADIR exists and isn't an install by this script: choose another --datadir"
fi

# Writable? Make the parents, or explain how to get the rights.
for dir in "$BINDIR" "$(dirname -- "$DATADIR")"; do
    if [ "$DRY" = 0 ] && ! mkdir -p -- "$dir" 2>/dev/null; then
        if [ "$WHERE" = system ] && [ "$(id -u)" != 0 ]; then
            die "can't write $dir: a system-wide install needs root (sudo sh install.sh --system)"
        fi
        die "can't create $dir"
    fi
    if [ "$DRY" = 0 ] && [ ! -w "$dir" ]; then
        if [ "$WHERE" = system ] && [ "$(id -u)" != 0 ]; then
            die "can't write $dir: a system-wide install needs root (sudo sh install.sh --system)"
        fi
        die "can't write $dir"
    fi
done

MANAGER_VERSION=$(sed -n 's/^ *variable version \([0-9][^ ]*\)$/\1/p' "$SOURCE/lib/manager.tcl" | head -n 1)
say "Installing tclvenv ${MANAGER_VERSION:-?} (Tcl $VERSION: $TCL)"
say "  command: $COMMAND"
say "  files:   $DATADIR"

# PATH: decided now, so the manifest can record the files changed.
CHANGE_PATH=0
if [ "$WHERE" != system ] && ! on_path "$BINDIR"; then
    case $PATHMODE in
        yes) CHANGE_PATH=1 ;;
        no) ;;
        ask)
            if interactive; then
                case $(ask "$BINDIR is not on your PATH. Add it in your shell startup files? [Y/n]" y) in
                    [Yy]*) CHANGE_PATH=1 ;;
                esac
            fi ;;
    esac
fi

if [ "$DRY" = 1 ]; then
    say "would copy tclvenv.tcl, lib/, README.md, docs/ and examples/ to $DATADIR"
    say "would write $COMMAND"
    if [ "$CHANGE_PATH" = 1 ]; then
        for name in $startup_names; do
            startup_wanted "$name" || continue
            if can_edit "$HOME/$name"; then say "would add $BINDIR to PATH in $HOME/$name"
            else say "would skip $HOME/$name (can't change it)"; fi
        done
    fi
    exit 0
fi

# Stage beside the destination, then move into place: an interrupted install
# leaves the old one (or nothing), never a mixture.
parent=$(dirname -- "$DATADIR")
stage=$(mktemp -d "$parent/.tclvenv-install.XXXXXX")
trap 'rm -rf -- "$stage" "$COMMAND.tclvenv-tmp"' EXIT HUP INT TERM
mkdir -p -- "$stage/lib"
cp -- "$SOURCE/tclvenv.tcl" "$stage/"
cp -- "$SOURCE"/lib/*.tcl "$stage/lib/"
[ ! -f "$SOURCE/README.md" ] || cp -- "$SOURCE/README.md" "$stage/"
if [ -d "$SOURCE/examples" ]; then mkdir -p -- "$stage/examples"; cp -- "$SOURCE"/examples/* "$stage/examples/"; fi
if [ -d "$SOURCE/docs" ]; then mkdir -p -- "$stage/docs"; cp -- "$SOURCE"/docs/*.md "$stage/docs/"; fi
chmod -R u=rwX,go=rX -- "$stage"
{
    say "tclvenv-install 1"
    say "version ${MANAGER_VERSION:-unknown}"
    say "command $COMMAND"
    say "tcl $TCL"
} > "$stage/.install-manifest"
# An upgrade keeps the records of the PATH lines an earlier install added;
# lines added now are recorded below, once they are written.
OLD_RECORDS=
if [ -f "$MANIFEST" ]; then
    OLD_RECORDS=$(grep '^startup-' "$MANIFEST" || :)
    [ -z "$OLD_RECORDS" ] || printf '%s\n' "$OLD_RECORDS" >> "$stage/.install-manifest"
fi

old=
if [ -e "$DATADIR" ]; then
    old=$(mktemp -d "$parent/.tclvenv-old.XXXXXX")
    rmdir -- "$old"
    mv -- "$DATADIR" "$old"
fi
mv -- "$stage" "$DATADIR"
[ -z "$old" ] || rm -rf -- "$old"

{
    say "#!/bin/sh"
    say "$MARK"
    say "# Remove with: sh install.sh --uninstall (with the same location options)."
    say "# TCLVENV_TCLSH selects another Tcl 8.6+ interpreter to run it."
    say "tcl=\${TCLVENV_TCLSH:-}"
    say "[ -n \"\$tcl\" ] || tcl=$(quote "$TCL")"
    say "exec \"\$tcl\" $(quote "$DATADIR/tclvenv.tcl") \"\$@\""
} > "$COMMAND.tclvenv-tmp"
chmod 755 -- "$COMMAND.tclvenv-tmp"
mv -f -- "$COMMAND.tclvenv-tmp" "$COMMAND"
trap - EXIT HUP INT TERM

"$COMMAND" --version > /dev/null || die "the installed command doesn't run: $COMMAND"

if [ "$CHANGE_PATH" = 1 ]; then
    line="case \":\$PATH:\" in *:$(quote "$BINDIR"):*) ;; *) PATH=$(quote "$BINDIR")\${PATH:+:\$PATH}; export PATH ;; esac"
    case $HOME in *"$NL"*) die "HOME contains a newline: add $BINDIR to PATH yourself" ;; esac
    added=0
    for name in $startup_names; do
        startup_wanted "$name" || continue
        file=$HOME/$name
        if ! can_edit "$file"; then
            warn "can't change $file (read-only, a dangling link, or not a file): add $BINDIR to PATH there yourself"
            continue
        fi
        record=
        if grep -qxF "$BLOCK_BEGIN" "$file" 2>/dev/null; then
            remove_block "$file" 0 > /dev/null    # reinstall: the same block again
        elif [ -s "$file" ] && [ -n "$(tail -c 1 -- "$file")" ]; then
            # No final newline: add one, so the block starts on its own line;
            # uninstall takes it away again.
            printf '\n' >> "$file"
            record="startup-newline $file"
        fi
        { say "$BLOCK_BEGIN"; say "$line"; say "$BLOCK_END"; } >> "$file"
        case "$NL$OLD_RECORDS$NL" in *"${NL}startup-file $file$NL"*) ;; *) say "startup-file $file" >> "$MANIFEST" ;; esac
        [ -z "$record" ] || say "$record" >> "$MANIFEST"
        say "Added $BINDIR to PATH in $file"
        added=1
    done
    [ "$added" = 0 ] || say "Open a new terminal (or run: . ~/.profile) to use it."
elif ! on_path "$BINDIR"; then
    say "Note: $BINDIR is not on your PATH. Add it, for example in ~/.profile:"
    say "  PATH=$(quote "$BINDIR"):\$PATH; export PATH"
    say "or run tclvenv as $COMMAND"
fi
say "Installed: $COMMAND --help"
[ ! -f "$DATADIR/docs/GUIDE.md" ] || say "Usage guide: $DATADIR/docs/GUIDE.md"
