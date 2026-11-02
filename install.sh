#!/bin/sh
# Installs (or removes) the tclvenv command on Linux and other POSIX systems.
#
#   sh install.sh                  ask where (when run from a terminal)
#   sh install.sh --user           ~/.local/bin/tclvenv, files in ~/.local/share/tclvenv
#   sh install.sh --user-bin       ~/bin/tclvenv, files in ~/.local/share/tclvenv
#   sudo sh install.sh --system    /usr/local/bin/tclvenv, files in /usr/local/share/tclvenv
#   sh install.sh --prefix DIR     DIR/bin/tclvenv, files in DIR/share/tclvenv
#   sh install.sh --upgrade        update the install already there, from this checkout
#   sh install.sh --uninstall      remove the install already there (or give where)
#   sh install.sh --venv [DIR]     run the command inside its own tclvenv
#
# Run with --help for every option. Only POSIX sh and core utilities are used.
set -eu

PROGRAM=tclvenv
VERSION_FILE=lib/manager.tcl
TCL_VARIABLE=TCLVENV_TCLSH
TCL_NOTE="environments use it
                    unless created with --tcl"
UNINSTALL_NOTE="Environments you created still work: each holds its own copy."
UPGRADE_NOTE="Environments you created keep the version they were made with."
# For --venv: the variable naming a tclvenv, this checkout's own tclvenv (if it has
# one) as the default, and packages to add to a new environment, if they can be found.
TCLVENV_VARIABLE=TCLVENV_TCLVENV
TCLVENV_GIVEN=${TCLVENV_TCLVENV:-}
TCLVENV_DEFAULT="tclvenv.tcl of this checkout"
OWN_TCLVENV=tclvenv.tcl
VENV_PACKAGES=

# ---- The rest of this file is the same in tclvenv and tclpkg ----

# The log: DATADIR/.install-log, kept across upgrades and reinstalls and removed with
# the install; --log FILE also writes to a file of your choice, which stays.
LOG=
EXTRA_LOG=

usage() {
    cat <<EOF
Usage: sh install.sh [WHERE] [OPTIONS]

Where (default: ask on a terminal, else --user):
  --user            command in ~/.local/bin, files in ~/.local/share/$PROGRAM
  --user-bin        command in ~/bin, files in ~/.local/share/$PROGRAM
  --system          command in /usr/local/bin, files in /usr/local/share/$PROGRAM
                    (needs root: run with sudo)
  --prefix DIR      command in DIR/bin, files in DIR/share/$PROGRAM
  --bindir DIR      put the command in DIR (with any of the above)
  --datadir DIR     put $PROGRAM's files in DIR (with any of the above)

Options:
  --upgrade         update an install already there, from this checkout: finds it
                    (or give WHERE), keeps its place, its Tcl and its PATH lines,
                    asks nothing, and refuses an older version unless --force
  --tcl EXECUTABLE  Tcl 8.6+ interpreter that runs $PROGRAM (default: the first
                    of tclsh, tclsh9.0, tclsh8.6 on PATH); $TCL_NOTE
  --path            add the command's directory to PATH in your shell startup
                    files (~/.profile, and ~/.bashrc and ~/.zshrc if present)
  --no-path         never change startup files (just say what to do)
  --uninstall       remove the command, its files and the PATH lines added: of the
                    install found as --upgrade finds it, or of WHERE
  --force           replace a $PROGRAM command this script didn't install; with
                    --upgrade, also go back to an older version or copy again
  --venv [DIR]      create a tclvenv and run the command inside it, isolated from
                    other packages (default DIR: DATADIR/venv); an existing one
                    is used as it is, and an install keeps its tclvenv after that
  --tclvenv CMD     tclvenv command or tclvenv.tcl that creates it (default:
                    $TCLVENV_DEFAULT, or $TCLVENV_VARIABLE)
  --log FILE        also log each file and action to FILE, which uninstall leaves
                    (the install's own log is DATADIR/.install-log)
  --dry-run         show what would be done, change nothing
  -y, --yes         don't ask; use the defaults for anything not given
  -h, --help        show this help

Examples:
  sh install.sh --venv                     command isolated in DATADIR/venv
  sudo sh install.sh --system --venv       the same, for everyone
  sh install.sh --venv ~/envs/$PROGRAM --tclvenv ~/src/tclvenv/tclvenv.tcl
EOF
}

say() { printf '%s\n' "$*"; }
warn() { printf 'install.sh: %s\n' "$*" >&2; }

# One line: TIME ACTION DETAIL. A log that can't be written doesn't stop the work.
log() {
    [ -n "$LOG$EXTRA_LOG" ] || return 0
    line="$(date +%Y-%m-%dT%H:%M:%S%z) $*"
    if [ -n "$LOG" ]; then printf '%s\n' "$line" 2>/dev/null >> "$LOG" || :; fi
    if [ -n "$EXTRA_LOG" ]; then printf '%s\n' "$line" 2>/dev/null >> "$EXTRA_LOG" || :; fi
}

die() {
    log "failed $*"
    printf 'install.sh: %s\n' "$*" >&2
    exit 1
}

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

# --- Options -----------------------------------------------------------------

WHERE=
BINDIR=
DATADIR=
TCL=
PATHMODE=ask
UNINSTALL=0
UPGRADE=0
FORCE=0
DRY=0
YES=0
PREFIX=
MAKE_VENV=0
VENV=
TCLVENV_ARG=$TCLVENV_GIVEN

while [ $# -gt 0 ]; do
    case $1 in
        --user|--user-bin|--system) WHERE=${1#--} ;;
        --venv)
            MAKE_VENV=1
            # DIR is optional: --venv --user uses the default.
            case ${2-} in
                ""|-*) ;;
                *) VENV=$(expand "$2"); shift ;;
            esac ;;
        --venv=*)
            MAKE_VENV=1
            VENV=$(expand "${1#*=}")
            [ -n "$VENV" ] || die "--venv= needs a directory" ;;
        --tclvenv=*)
            TCLVENV_ARG=$(expand "${1#*=}")
            [ -n "$TCLVENV_ARG" ] || die "--tclvenv= needs a command or script" ;;
        --prefix|--bindir|--datadir|--tcl|--log|--tclvenv)
            [ $# -ge 2 ] || die "$1 needs a value"
            case $1 in
                --prefix) WHERE=prefix; PREFIX=$(expand "$2") ;;
                --bindir) BINDIR=$(expand "$2") ;;
                --datadir) DATADIR=$(expand "$2") ;;
                --tcl) TCL=$(expand "$2") ;;
                --log) EXTRA_LOG=$(absolute "$(expand "$2")") ;;
                --tclvenv)
                    [ -n "$2" ] || die "--tclvenv needs a command or script"
                    TCLVENV_ARG=$(expand "$2") ;;
            esac
            shift ;;
        --path) PATHMODE=yes ;;
        --no-path) PATHMODE=no ;;
        --uninstall) UNINSTALL=1 ;;
        --upgrade) UPGRADE=1 ;;
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
[ "$UPGRADE$UNINSTALL" != 11 ] || die "--upgrade and --uninstall together"
if [ -n "$EXTRA_LOG" ]; then
    if [ "$DRY" = 1 ]; then
        EXTRA_LOG=    # (A dry run changes nothing.)
    else
        file=$EXTRA_LOG
        EXTRA_LOG=
        mkdir -p -- "$(dirname -- "$file")" 2>/dev/null || die "can't create the directory of the log: $file"
        { : >> "$file"; } 2>/dev/null || die "can't write the log: $file"
        EXTRA_LOG=$file
    fi
fi

MARK="# Installed by $PROGRAM install.sh"

# The files directory a command written by this script runs from.
command_data() {
    [ -f "$1" ] && grep -qxF "$MARK" "$1" || return 1
    sed -n "s/^exec \"\$tcl\" '\(.*\)\/$PROGRAM\.tcl' \"\$@\"\$/\1/p" "$1" | sed "s/'\\\\''/'/g"
}

# Finds the install to change: the command this PATH runs, else the usual places.
locate_install() {
    for candidate in "$(command -v "$PROGRAM" 2>/dev/null || :)" \
                     "$HOME/.local/bin/$PROGRAM" "$HOME/bin/$PROGRAM" "/usr/local/bin/$PROGRAM"; do
        [ -n "$candidate" ] || continue
        data=$(command_data "$candidate") || continue
        if [ -n "$data" ] && [ -f "$data/.install-manifest" ]; then DATADIR=$data; return 0; fi
    done
    return 1
}

GIVEN_BINDIR=$BINDIR
if [ "$UPGRADE" = 1 ] && [ -z "$WHERE$DATADIR" ]; then
    locate_install || die "no $PROGRAM found to upgrade (looked on PATH, in ~/.local/bin, ~/bin and /usr/local/bin): install it with sh install.sh, or say where it is"
    WHERE=located
elif [ "$UNINSTALL" = 1 ] && [ -z "$WHERE$BINDIR$DATADIR" ] && locate_install; then
    WHERE=located
fi

if [ -z "$WHERE" ]; then
    if [ "$UPGRADE" = 0 ] && interactive && [ -z "$BINDIR$DATADIR" ]; then
        if [ "$UNINSTALL" = 1 ]; then verb=Remove; else verb=Install; fi
        say "$verb $PROGRAM for:" > /dev/tty
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
    located) dBin=; dData= ;;
esac
[ -n "$BINDIR" ] || BINDIR=$dBin
[ -n "$DATADIR" ] || DATADIR=$dData
DATADIR=$(absolute "$DATADIR")
MANIFEST=$DATADIR/.install-manifest

# A value recorded in the manifest.
recorded() { sed -n "s/^$1 //p" "$MANIFEST" | head -n 1; }

# An upgrade stays where the install is, and never asks.
if [ "$UPGRADE" = 1 ]; then
    [ -f "$MANIFEST" ] || die "no $PROGRAM installed by this script at $DATADIR: install it with sh install.sh"
    [ "$PATHMODE" != ask ] || PATHMODE=no
fi
if [ "$UPGRADE" = 1 ] || [ "$WHERE" = located ]; then
    BINDIR=$(dirname -- "$(recorded command)")
    if [ -n "$GIVEN_BINDIR" ] && [ "$(absolute "$GIVEN_BINDIR")" != "$BINDIR" ]; then
        die "this install's command is in $BINDIR: an upgrade doesn't move it"
    fi
fi
BINDIR=$(absolute "$BINDIR")
COMMAND=$BINDIR/$PROGRAM

NL='
'
case $BINDIR in *:*) die "the command's directory can't go on PATH (it contains ':'): $BINDIR" ;; esac
case $BINDIR$DATADIR in *"$NL"*) die "a directory name contains a newline: choose another" ;; esac

# Startup files get one block per install, marked with the command's
# directory, so installs elsewhere never touch each other's lines.
set_markers() {
    BLOCK_BEGIN="# >>> $PROGRAM PATH $1 >>>"
    BLOCK_END="# <<< $PROGRAM PATH $1 <<<"
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
    tmp=$1.$PROGRAM-tmp
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
    log "path-remove $1"
    say "Removed the PATH lines from $1"
}

on_path() {
    case ":${PATH-}:" in *":$1:"*) return 0 ;; esac
    return 1
}

# --- Uninstall ---------------------------------------------------------------

if [ "$UNINSTALL" = 1 ]; then
    # Found rather than named: on a terminal, say which before removing it.
    if [ "$WHERE" = located ] && [ "$DRY" = 0 ] && interactive; then
        case $(ask "Remove $COMMAND and $DATADIR? [y/N]" n) in
            [Yy]*) ;;
            *) say "Nothing removed."; exit 0 ;;
        esac
    fi
    found=0
    if [ "$DRY" = 0 ]; then log "begin uninstall $PROGRAM command=$COMMAND files=$DATADIR user=$(id -un)"; fi
    # The manifest knows where the command went (for a --bindir install).
    if [ -f "$MANIFEST" ]; then
        recorded=$(sed -n 's/^command //p' "$MANIFEST" | head -n 1)
        if [ -n "$recorded" ]; then COMMAND=$recorded; set_markers "$(dirname -- "$COMMAND")"; fi
    fi
    if [ -f "$COMMAND" ] && grep -qxF "$MARK" "$COMMAND"; then
        found=1
        if [ "$DRY" = 1 ]; then say "would remove $COMMAND"
        else rm -f -- "$COMMAND"; log "remove $COMMAND"; say "Removed $COMMAND"; fi
    elif [ -e "$COMMAND" ]; then
        log "leave $COMMAND (not installed by this script)"
        say "Left $COMMAND: this script didn't install it"
    fi
    files=
    newlines=
    if [ -f "$MANIFEST" ]; then
        # Its tclvenv goes if the install made it, and only while it still is one.
        # (One inside the files directory goes with them, below.)
        venv=$(recorded venv)
        case $venv in
            "") ;;
            "$DATADIR"/*) ;;
            /?*)
                if [ "$(recorded venv-owned)" != 1 ]; then
                    log "leave $venv (not created by this script)"
                    say "Left the tclvenv $venv: this script didn't create it"
                elif [ ! -f "$venv/tclvenv.cfg" ]; then
                    log "leave $venv (not a tclvenv)"
                    say "Left $venv: it is not a tclvenv, or is already gone"
                elif [ "$DRY" = 1 ]; then
                    say "would remove the tclvenv $venv"
                else
                    rm -rf -- "$venv" || die "can't remove the tclvenv $venv"
                    log "remove $venv"
                    say "Removed the tclvenv $venv"
                fi ;;
            *) die "the manifest names an unsafe tclvenv path: $venv" ;;
        esac
        files=$(sed -n 's/^startup-file //p' "$MANIFEST")
        newlines=$(sed -n 's/^startup-newline //p' "$MANIFEST")
        if [ "$DRY" = 0 ] && [ -n "$EXTRA_LOG" ]; then
            find "$DATADIR" -type f > "$EXTRA_LOG.$$"
            while IFS= read -r file; do log "remove $file"; done < "$EXTRA_LOG.$$"
            rm -f -- "$EXTRA_LOG.$$"
        fi
        found=1
        if [ "$DRY" = 1 ]; then say "would remove $DATADIR"
        else rm -rf -- "$DATADIR"; log "remove $DATADIR"; say "Removed $DATADIR"; fi
    elif [ -e "$DATADIR" ]; then
        log "leave $DATADIR (no install manifest)"
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
    [ "$found" = 1 ] || die "no $PROGRAM installed by this script at $COMMAND or $DATADIR"
    if [ "$DRY" = 1 ]; then say "Dry run: nothing was changed."; exit 0; fi
    log "end uninstall"
    say "$PROGRAM is uninstalled. $UNINSTALL_NOTE"
    exit 0
fi

# --- Install -----------------------------------------------------------------

[ -f "$SOURCE/$PROGRAM.tcl" ] && [ -f "$SOURCE/$VERSION_FILE" ] ||
    die "run install.sh from a $PROGRAM checkout ($PROGRAM.tcl and lib/ beside it)"

# The files an install holds, relative to the checkout.
payload() {
    (
        cd "$SOURCE" || exit 1
        for file in "$PROGRAM.tcl" lib/*.tcl README.md docs/*.md examples/*; do
            if [ -f "$file" ]; then say "$file"; fi
        done
    )
}

# The files in the install now, apart from its records and a tclvenv inside it.
installed_files() {
    (cd "$DATADIR" && find . -type f ! -name .install-manifest ! -name .install-log) |
        P=${VENV_CHILD:+./$VENV_CHILD/} awk 'ENVIRON["P"] == "" || index($0, ENVIRON["P"]) != 1'
}

# Whether the install holds just what this checkout would put there.
up_to_date() {
    payload | while IFS= read -r file; do
        cmp -s -- "$SOURCE/$file" "$DATADIR/$file" || exit 1
    done || return 1
    [ "$(payload | wc -l)" -eq "$(installed_files | wc -l)" ]
}

# Whether plain dotted version $1 is older than $2; other forms can't be compared here.
version_older() {
    case $1$2 in ""|*[!0-9.]*) return 1 ;; esac
    [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -t. -k1,1n -k2,2n -k3,3n -k4,4n | head -n 1)" = "$1" ]
}

# A Tcl found on PATH, passing over an active environment's: the command must keep
# working when that environment is gone.
find_outside_environment() {
    (
        if [ -n "${TCLVENV:-}" ]; then
            dirs=:$PATH:
            while :; do
                case $dirs in
                    *":$TCLVENV/bin:"*) dirs=${dirs%%":$TCLVENV/bin:"*}:${dirs#*":$TCLVENV/bin:"} ;;
                    *) break ;;
                esac
            done
            dirs=${dirs#:}
            PATH=${dirs%:}
        fi
        command -v "$1" 2>/dev/null
    )
}

# The interpreter: Tcl 8.6 or newer.
tcl_version() {
    printf 'puts [info patchlevel]\n' | "$1" 2>/dev/null | tail -n 1
}

# --- tclvenv: where it goes, and whether to make it ---------------------------

# A path with its directory resolved, for comparing, when that directory exists.
resolved() {
    if [ -d "$(dirname -- "$1")" ]; then
        printf '%s/%s' "$(CDPATH= cd -P -- "$(dirname -- "$1")" && pwd)" "$(basename -- "$1")"
    else
        printf '%s' "$1"
    fi
}
# The same for a directory, itself resolved too when it exists.
resolved_directory() {
    if [ -d "$1" ]; then (CDPATH= cd -P -- "$1" && pwd); else resolved "$1"; fi
}
venv_usable() {
    [ -f "$1/tclvenv.cfg" ] && [ -x "$1/bin/tclsh" ] && [ -n "$(tcl_version "$1/bin/tclsh")" ]
}

OLD_VENV=
[ ! -f "$MANIFEST" ] || OLD_VENV=$(recorded venv)
if [ "$MAKE_VENV" = 1 ]; then
    [ -n "$VENV" ] || VENV=${OLD_VENV:-$DATADIR/venv}
    VENV=$(absolute "$VENV")
    while :; do
        case $VENV in
            /) die "--venv can't be /" ;;
            */) VENV=${VENV%/} ;;
            */.) VENV=${VENV%/.} ;;
            *) break ;;
        esac
    done
    case $VENV in *"$NL"*) die "a directory name contains a newline: choose another" ;; esac
elif [ -n "$OLD_VENV" ]; then
    VENV=$OLD_VENV
fi
if [ -n "$OLD_VENV" ] && [ "$(resolved "$VENV")" != "$(resolved "$OLD_VENV")" ]; then
    die "this install runs in the tclvenv $OLD_VENV: uninstall it first to use another"
fi

VENV_CHILD=
VENV_CREATE=0
if [ -n "$VENV" ]; then
    # Replacing the files keeps a tclvenv just inside them; anywhere deeper it would
    # be lost. Compared resolved, as the same place can be spelled through links.
    real_data=$(resolved_directory "$DATADIR")
    real_venv=$(resolved "$VENV")
    [ "$real_venv" != "$real_data" ] || die "--venv can't be $PROGRAM's files directory: $VENV"
    case $real_venv in
        "$real_data"/*/*) die "--venv inside $DATADIR must be directly inside it" ;;
        "$real_data"/*)
            VENV_CHILD=$(basename -- "$VENV")
            case $VENV_CHILD in
                bin|lib|docs|examples|"$PROGRAM.tcl"|README.md|.install-*)
                    die "--venv can't be $VENV: $PROGRAM's own files go there" ;;
            esac
            VENV=$DATADIR/$VENV_CHILD ;;
    esac
    case $DATADIR/ in "$VENV"/*) die "the files directory can't be inside the tclvenv: $VENV" ;; esac
    case $BINDIR/ in "$VENV"/*) die "the command's directory can't be inside the tclvenv: $VENV" ;; esac
    if venv_usable "$VENV"; then
        [ -z "$TCL" ] || warn "ignoring --tcl: the tclvenv $VENV keeps its own Tcl (remove it to change that)"
        TCL=$VENV/bin/tclsh
    elif [ -e "$VENV" ] || [ -L "$VENV" ]; then
        die "$VENV exists and isn't a usable tclvenv: remove it to make a new one, or choose another --venv"
    else
        VENV_CREATE=1
    fi
fi

if [ -z "$TCL" ] && [ "$UPGRADE" = 1 ] && [ -z "$OLD_VENV" ]; then
    TCL=$(recorded tcl)
    [ -x "$TCL" ] || die "this install's Tcl is gone ($TCL): give another with --tcl"
fi
if [ -n "$TCL" ]; then
    case $TCL in */*) TCL=$(absolute "$TCL") ;; *) TCL=$(command -v "$TCL" 2>/dev/null) || die "no Tcl named $TCL on PATH" ;; esac
else
    for name in tclsh tclsh9.0 tclsh8.6; do
        if found=$(find_outside_environment "$name"); then TCL=$found; break; fi
    done
    [ -n "$TCL" ] || die "no tclsh found: install Tcl 8.6 or newer (Debian/Ubuntu: sudo apt install tcl) or give --tcl"
fi
[ -x "$TCL" ] || die "not an executable: $TCL"
VERSION=$(tcl_version "$TCL") || VERSION=
case $VERSION in
    8.6*|8.7*|9.*|[1-9][0-9].*) ;;
    "") die "$TCL didn't run as a Tcl interpreter" ;;
    *) die "$TCL is Tcl $VERSION; $PROGRAM needs 8.6 or newer" ;;
esac

# The tclvenv that makes a new environment: as given, else this checkout's, else on PATH.
MANAGER=
MANAGER_SCRIPT=
find_tclvenv() {
    if [ -n "$TCLVENV_ARG" ]; then
        case $TCLVENV_ARG in
            *.tcl) [ -f "$TCLVENV_ARG" ] && MANAGER_SCRIPT=$TCLVENV_ARG ;;
            */*)
                if [ -d "$TCLVENV_ARG" ] && [ -f "$TCLVENV_ARG/tclvenv.tcl" ]; then MANAGER_SCRIPT=$TCLVENV_ARG/tclvenv.tcl
                elif [ -f "$TCLVENV_ARG" ] && [ -x "$TCLVENV_ARG" ]; then MANAGER=$TCLVENV_ARG
                elif [ -f "$TCLVENV_ARG" ]; then MANAGER_SCRIPT=$TCLVENV_ARG
                else return 1; fi ;;
            *) MANAGER=$(command -v "$TCLVENV_ARG" 2>/dev/null) || return 1 ;;
        esac
    elif [ -n "$OWN_TCLVENV" ]; then
        MANAGER_SCRIPT=$SOURCE/$OWN_TCLVENV
    else
        MANAGER=$(command -v tclvenv 2>/dev/null) || return 1
    fi
}
run_tclvenv() {
    if [ -n "$MANAGER_SCRIPT" ]; then "$BASE_TCL" "$MANAGER_SCRIPT" "$@"; else "$MANAGER" "$@"; fi
}
BASE_TCL=$TCL
if [ "$VENV_CREATE" = 1 ]; then
    find_tclvenv && run_tclvenv --version > /dev/null 2>&1 ||
        die "--venv needs a working tclvenv: install it, use --tclvenv, or set $TCLVENV_VARIABLE"
fi

if [ -e "$COMMAND" ] && ! grep -qxF "$MARK" "$COMMAND" 2>/dev/null && [ "$FORCE" = 0 ]; then
    die "$COMMAND exists and this script didn't install it (use --force to replace it)"
fi
if [ -e "$DATADIR" ] && [ ! -f "$MANIFEST" ]; then
    die "$DATADIR exists and isn't an install by this script: choose another --datadir"
fi

# Writable? Make the parents, or explain how to get the rights.
PROGRAM_VERSION=$(sed -n 's/^ *variable version \([0-9][^ ]*\)$/\1/p' "$SOURCE/$VERSION_FILE" | head -n 1)
OLD_VERSION=
if [ "$UPGRADE" = 1 ]; then
    OLD_VERSION=$(recorded version)
    if [ "$FORCE" = 0 ] && version_older "$PROGRAM_VERSION" "$OLD_VERSION"; then
        die "$PROGRAM $OLD_VERSION is installed, which is newer than this checkout's $PROGRAM_VERSION (--force goes back to it)"
    fi
    if [ "$FORCE" = 0 ] && [ -f "$COMMAND" ] && [ "$VENV_CREATE" = 0 ] && [ "$TCL" = "$(recorded tcl)" ] && up_to_date; then
        say "$PROGRAM ${PROGRAM_VERSION:-?} at $COMMAND is already up to date"
        exit 0
    fi
fi

needs_rights() {
    [ "$(id -u)" != 0 ] || return 0
    if [ "$WHERE" = system ]; then
        die "can't write $1: a system-wide install needs root (sudo sh install.sh --system)"
    elif [ "$UPGRADE" = 1 ]; then
        die "can't write $1: run the upgrade with the rights of the install's owner (with sudo, if that is root)"
    fi
}
for dir in "$BINDIR" "$(dirname -- "$DATADIR")"; do
    if [ "$DRY" = 0 ] && ! mkdir -p -- "$dir" 2>/dev/null; then
        needs_rights "$dir"
        die "can't create $dir"
    fi
    if [ "$DRY" = 0 ] && [ ! -w "$dir" ]; then
        needs_rights "$dir"
        die "can't write $dir"
    fi
done

if [ "$UPGRADE" = 1 ]; then
    say "Upgrading $PROGRAM ${OLD_VERSION:-?} to ${PROGRAM_VERSION:-?} (Tcl $VERSION: $TCL)"
else
    say "Installing $PROGRAM ${PROGRAM_VERSION:-?} (Tcl $VERSION: $TCL)"
fi
say "  command: $COMMAND"
say "  files:   $DATADIR"
[ -z "$VENV" ] || say "  tclvenv: $VENV"

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
    say "would copy $(payload | wc -l | tr -d ' ') files ($PROGRAM.tcl, lib/ and its documents) to $DATADIR"
    if [ -n "$VENV" ]; then
        if [ "$VENV_CREATE" = 1 ]; then
            say "would create a tclvenv at $VENV with $BASE_TCL"
            for package in $VENV_PACKAGES; do say "would add $package to the tclvenv, if it can be found"; done
        else
            say "would use the tclvenv at $VENV as it is"
        fi
    fi
    say "would write $COMMAND"
    say "would write $MANIFEST"
    if [ "$CHANGE_PATH" = 1 ]; then
        for name in $startup_names; do
            startup_wanted "$name" || continue
            if can_edit "$HOME/$name"; then say "would add $BINDIR to PATH in $HOME/$name"
            else say "would skip $HOME/$name (can't change it)"; fi
        done
    fi
    say "Dry run: nothing was changed."
    exit 0
fi

# Stage beside the destination, then move into place: an interrupted install
# leaves the old one (or nothing), never a mixture.
parent=$(dirname -- "$DATADIR")
stage=$(mktemp -d "$parent/.$PROGRAM-install.XXXXXX")
VENV_CREATED=0
DATADIR_MADE=0
# Until the install is complete: a tclvenv made for it goes too. A signal has to end
# the script, or the install would carry on without what was cleaned up.
cleanup() {
    rm -rf -- "$stage" "$COMMAND.$PROGRAM-tmp"
    if [ "$VENV_CREATED" = 1 ]; then rm -rf -- "$VENV"; fi
    if [ "$DATADIR_MADE" = 1 ]; then rmdir -- "$DATADIR" 2>/dev/null || :; fi
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# Into the install's log if it has one, so a failure below is on record there.
if [ -d "$DATADIR" ]; then LOG=$DATADIR/.install-log; else LOG=$stage/.install-log; fi
if [ "$UPGRADE" = 1 ]; then action=upgrade; else action=install; fi
log "begin $action $PROGRAM version=${PROGRAM_VERSION:-unknown} previous=${OLD_VERSION:--} source=$SOURCE tcl=$TCL user=$(id -un)"
payload | while IFS= read -r file; do
    mkdir -p -- "$stage/$(dirname -- "$file")"
    cp -- "$SOURCE/$file" "$stage/$file"
    if [ ! -e "$DATADIR/$file" ]; then log "add $DATADIR/$file"
    elif cmp -s -- "$SOURCE/$file" "$DATADIR/$file"; then log "unchanged $DATADIR/$file"
    else log "update $DATADIR/$file"; fi
done
# What the new version no longer holds.
if [ -d "$DATADIR" ]; then
    installed_files | sed 's|^\./||' |
    while IFS= read -r file; do
        [ -f "$SOURCE/$file" ] && payload | grep -qxF -- "$file" || log "remove $DATADIR/$file"
    done
fi
chmod -R u=rwX,go=rX -- "$stage"
if [ "$VENV_CREATE" = 1 ]; then
    say "Creating the tclvenv $VENV"
    # Made where it will stay, since an environment's scripts name their directory.
    if [ -n "$VENV_CHILD" ] && [ ! -e "$DATADIR" ]; then DATADIR_MADE=1; fi
    mkdir -p -- "$(dirname -- "$VENV")" 2>/dev/null || die "can't create the directory of the tclvenv: $VENV"
    VENV_CREATED=1
    (umask 022; run_tclvenv create "$VENV" --tcl "$BASE_TCL") || die "could not create a tclvenv at $VENV: nothing was changed"
    venv_usable "$VENV" || die "tclvenv didn't make a usable environment at $VENV: nothing was changed"
    # Every user of a system install reads this; tclvenv writes it through a private temp file.
    chmod 644 -- "$VENV/tclvenv.cfg"
    log "venv-create $VENV (tcl=$BASE_TCL)"
    for package in $VENV_PACKAGES; do
        if (umask 022; run_tclvenv add "$VENV" "$package") > /dev/null 2>&1; then
            log "venv-add $package"
            say "Added $package to the tclvenv"
        else
            log "venv-skip $package"
            warn "couldn't add $package to the tclvenv: add it later with tclvenv add $VENV $package"
        fi
    done
    TCL=$VENV/bin/tclsh
fi
# Before anything is replaced: new files that can't run stop here.
"$TCL" "$stage/$PROGRAM.tcl" --version > /dev/null 2>&1 || die "the new files don't run with $TCL: nothing was changed"
{
    say "$PROGRAM-install 1"
    say "version ${PROGRAM_VERSION:-unknown}"
    say "command $COMMAND"
    say "tcl $TCL"
    if [ -n "$VENV" ]; then
        say "venv $VENV"
        # Whether uninstall removes it: if it was made for this install, or lives in it.
        if [ "$VENV_CREATED" = 1 ] || [ -n "$VENV_CHILD" ] ||
           { [ -f "$MANIFEST" ] && [ "$(recorded venv-owned)" = 1 ]; }; then
            say "venv-owned 1"
        fi
    fi
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
    # The log goes on with the new files.
    [ ! -f "$LOG" ] || [ "$LOG" = "$stage/.install-log" ] || cp -- "$LOG" "$stage/.install-log"
    old=$(mktemp -d "$parent/.$PROGRAM-old.XXXXXX")
    rmdir -- "$old"
    mv -- "$DATADIR" "$old"
    # A tclvenv inside goes on with the new files, back at the same path just below.
    if [ -n "$VENV_CHILD" ] && ! mv -- "$old/$VENV_CHILD" "$stage/$VENV_CHILD"; then
        mv -- "$old" "$DATADIR"
        die "could not keep the tclvenv: the old files are kept"
    fi
fi
if ! mv -- "$stage" "$DATADIR"; then
    if [ -n "$old" ]; then
        [ -z "$VENV_CHILD" ] || mv -- "$stage/$VENV_CHILD" "$old/$VENV_CHILD"
        mv -- "$old" "$DATADIR"
    fi
    die "could not put the new files in place: the old ones are kept"
fi
[ -z "$old" ] || rm -rf -- "$old"
LOG=$DATADIR/.install-log

{
    say "#!/bin/sh"
    say "$MARK"
    say "# Remove with: sh install.sh --uninstall (with the same location options)."
    say "# $TCL_VARIABLE selects another Tcl 8.6+ interpreter to run it."
    say "tcl=\${$TCL_VARIABLE:-}"
    say "[ -n \"\$tcl\" ] || tcl=$(quote "$TCL")"
    if [ -n "$VENV" ]; then
        # The environment's tclsh replaces these. $PROGRAM.tcl puts them back, so the
        # command still sees the caller's: their active environment, not its own.
        say "INSTALL_SH_SAVED=1; export INSTALL_SH_SAVED"
        for name in TCLVENV TCLLIBPATH PATH; do
            say "unset INSTALL_SH_$name"
            say "if [ -n \"\${$name+x}\" ]; then INSTALL_SH_$name=\$$name; export INSTALL_SH_$name; fi"
        done
    fi
    say "exec \"\$tcl\" $(quote "$DATADIR/$PROGRAM.tcl") \"\$@\""
} > "$COMMAND.$PROGRAM-tmp"
chmod 755 -- "$COMMAND.$PROGRAM-tmp"
if [ -e "$COMMAND" ]; then commandAction=update; else commandAction=add; fi
mv -f -- "$COMMAND.$PROGRAM-tmp" "$COMMAND"
log "$commandAction $COMMAND"
VENV_CREATED=0
DATADIR_MADE=0
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
            log "path-skip $file (can't change it)"
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
        log "path-add $file ($BINDIR)"
        case "$NL$OLD_RECORDS$NL" in *"${NL}startup-file $file$NL"*) ;; *) say "startup-file $file" >> "$MANIFEST" ;; esac
        [ -z "$record" ] || say "$record" >> "$MANIFEST"
        say "Added $BINDIR to PATH in $file"
        added=1
    done
    [ "$added" = 0 ] || say "Open a new terminal (or run: . ~/.profile) to use it."
elif [ "$UPGRADE" = 0 ] && ! on_path "$BINDIR"; then
    say "Note: $BINDIR is not on your PATH. Add it, for example in ~/.profile:"
    say "  PATH=$(quote "$BINDIR"):\$PATH; export PATH"
    say "or run $PROGRAM as $COMMAND"
fi
log "end $action"
say "Log: $LOG"
if [ "$UPGRADE" = 1 ]; then
    say "Upgraded: $COMMAND. $UPGRADE_NOTE"
    exit 0
fi
say "Installed: $COMMAND --help"
[ -z "$VENV" ] || say "Runs in the tclvenv: $VENV"
[ ! -f "$DATADIR/docs/GUIDE.md" ] || say "Usage guide: $DATADIR/docs/GUIDE.md"
