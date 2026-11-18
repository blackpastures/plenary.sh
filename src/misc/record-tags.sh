#!/bin/env -S bash

PROGRAM="record-tags"

ARTWORK=""
META_OPTS=()
CURRENT_TMP=""
NORMALIZED=""
INDEX=""
TITLE=""

function usage {
	cat <<-EOF
		Usage: $PROGRAM [OPTIONS] [TRACKLIST_DIR]

		Map the metadata values for a list of mp3 files. Track number and title
		are read from the filename when it starts with a number ("NA" prefixes
		are ignored).

		When TRACKLIST_DIR is omitted the list is retrieved from the current
		working directory, if it is - then stdin is read. Names must be one per
		record: newline separated, or NUL separated with --null.

		Files are rewritten in place atomically; existing tags are preserved
		unless overwritten, and existing embedded artwork is kept unless
		--artwork is given.

		OPTIONS
		  -a, --artist      set the metadata values for artist, composer, performer
		                    and album artist
		  -r, --album       set the metadata value for the album title
		  -g, --genre       set the metadata value for the genre
		  -y, --year        set the metadata value for the release year
		  -p, --artwork     set the artwork for this album
		  -n, --dry-run     print the ffmpeg commands without writing anything
		  -0, --null        read a NUL separated file list from stdin, use with -
		  -R, --recursive   search TRACKLIST_DIR recursively
		  -h, --help        print this help message
	EOF
}

function cleanup {
	if [[ -n "$CURRENT_TMP" ]]; then
		rm -f -- "$CURRENT_TMP"
	fi
}

function die_with_usage {
	echo "$*" >&2
	usage >&2

	exit 1
}

function die {
	echo "$*" >&2

	exit 1
}

# ffmpeg never reads stdin: the file list may be piped in and ffmpeg would
# otherwise consume it, silently skipping tracks.
function ff {
	ffmpeg -nostdin -hide_banner -nostats -loglevel error -y "$@"
}

function print_command {
	local arg

	printf 'ffmpeg -nostdin -hide_banner -nostats -loglevel error -y'
	for arg in "$@"; do
		printf ' %q' "$arg"
	done
	printf '\n'
}

# Prefix relative paths so names starting with `-` are never parsed as options.
# Sets NORMALIZED instead of printing, so filenames keep leading/trailing
# newlines that a command substitution would strip.
function normalize_path {
	if [[ "$1" == /* ]]; then
		NORMALIZED="$1"
	else
		NORMALIZED="./${1#./}"
	fi
}

function list_files {
	if [[ "$1" == '-' ]]; then
		if [[ -n "$OPT_NULL" ]]; then
			cat
		else
			# Terminate the last line too, otherwise read -d '' drops it at EOF.
			{ tr '\n' '\0'; printf '\0'; }
		fi

		return
	fi

	if [[ -n "$OPT_RECURSIVE" ]]; then
		find "$1" -type f -iname '*.mp3' -not -name '.*' -print0
	else
		find "$1" -maxdepth 1 -type f -iname '*.mp3' -not -name '.*' -print0
	fi | sort -z
}

function parse_name {
	local name="$1"

	if [[ "$name" =~ ^NA[[:space:]._-]+(.*)$ ]]; then
		name="${BASH_REMATCH[1]}"
	fi

	if [[ "$name" =~ ^[-._[:space:]]*([0-9]+)[[:space:]._-]*(.*)$ ]]; then
		INDEX="${BASH_REMATCH[1]}"
		TITLE="${BASH_REMATCH[2]}"
	else
		INDEX=""
		TITLE="$name"
	fi
}

# Rewrites one file in place: ffmpeg writes a sibling temp file which replaces
# the original only after it succeeded, keeping mode and timestamps.
function process_file {
	local file="$1"
	local dir base stem index title tmp
	local -a ffopts

	if [[ ! -f "$file" ]]; then
		echo "$PROGRAM: not a regular file: '$file'" >&2
		return 1
	fi
	if [[ ! -r "$file" ]]; then
		echo "$PROGRAM: file is not readable: '$file'" >&2
		return 1
	fi

	dir="$(dirname -- "$file")"
	base="$(basename -- "$file")"
	stem="${base%.*}"

	if [[ ! -d "$dir" || ! -w "$dir" ]]; then
		echo "$PROGRAM: directory is not writable: '$dir'" >&2
		return 1
	fi

	parse_name "$stem"
	index="$INDEX"
	title="$TITLE"

	ffopts=(-i "$file")
	if [[ -n "$ARTWORK" ]]; then
		ffopts+=(-i "$ARTWORK")
		# Drop the original picture stream, take the new one from input 1.
		ffopts+=(
			-map 0:a -map 1
			-c copy -id3v2_version 3
			-disposition:v attached_pic
			-metadata:s:v "title=Album cover"
			-metadata:s:v "comment=Cover (front)"
		)
	else
		# Keep every stream, including an already embedded cover.
		ffopts+=(-map 0 -c copy -id3v2_version 3)
	fi
	ffopts+=("${META_OPTS[@]}")

	if [[ -n "$title" ]]; then
		ffopts+=(-metadata "title=$title")
	fi
	if [[ -n "$index" ]]; then
		ffopts+=(-metadata "track=$index")
	fi

	if [[ -n "$OPT_DRY_RUN" ]]; then
		print_command "${ffopts[@]}" "$dir/.$stem.XXXXXX.mp3"
		return 0
	fi

	if ! tmp="$(mktemp --tmpdir="$dir" ".$stem.XXXXXX.mp3")"; then
		echo "$PROGRAM: cannot create a temporary file in '$dir'" >&2
		return 1
	fi
	CURRENT_TMP="$tmp"

	if ! ff "${ffopts[@]}" "$tmp"; then
		echo "$PROGRAM: failed to write tags for '$file'" >&2
		rm -f -- "$tmp"
		CURRENT_TMP=""
		return 1
	fi

	# mktemp creates 0600 files; carry over the original mode and timestamps.
	chmod --reference="$file" -- "$tmp" 2>/dev/null || true
	touch -r "$file" -- "$tmp" 2>/dev/null || true

	if ! mv -f -- "$tmp" "$file"; then
		echo "$PROGRAM: failed to replace '$file'" >&2
		rm -f -- "$tmp"
		CURRENT_TMP=""
		return 1
	fi
	CURRENT_TMP=""

	return 0
}

function main {
	local options artist="" album="" genre="" year="" artwork="" track_list
	local status=0 file

	if ! options=$(getopt -o "a:r:g:y:p:h0Rn" \
		-l "artist:,album:,genre:,year:,artwork:,help,null,recursive,dry-run" -- "$@"); then
		die_with_usage
	fi

	eval set -- "$options"

	while [ $# -gt 0 ]; do
		case "$1" in
		-a | --artist)
			artist="$2"
			shift 2
			;;

		-r | --album)
			album="$2"
			shift 2
			;;

		-g | --genre)
			genre="$2"
			shift 2
			;;

		-y | --year)
			year="$2"
			shift 2
			;;

		-p | --artwork)
			artwork="$2"
			shift 2
			;;

		-n | --dry-run)
			OPT_DRY_RUN=y
			shift
			;;

		-0 | --null)
			OPT_NULL=y
			shift
			;;

		-R | --recursive)
			OPT_RECURSIVE=y
			shift
			;;

		-h | --help)
			usage
			exit 0
			;;

		--)
			shift
			break
			;;

		-*)
			die_with_usage "$PROGRAM: error - unrecognized option $1"
			;;
		esac
	done

	if ! command -v ffmpeg >/dev/null 2>&1; then
		die "$PROGRAM: ffmpeg not found in PATH"
	fi

	if [[ -n "$artwork" ]]; then
		if [[ ! -f "$artwork" ]]; then
			die "$PROGRAM: artwork not found: '$artwork'"
		fi
		if [[ ! -r "$artwork" ]]; then
			die "$PROGRAM: artwork is not readable: '$artwork'"
		fi

		normalize_path "$artwork"
		ARTWORK="$NORMALIZED"
	fi

	if [[ -n "$artist" ]]; then
		META_OPTS+=(
			-metadata "album_artist=$artist"
			-metadata "performer=$artist"
			-metadata "composer=$artist"
			-metadata "artist=$artist"
		)
	fi

	if [[ -n "$album" ]]; then
		META_OPTS+=(-metadata "album=$album")
	fi

	if [[ -n "$genre" ]]; then
		META_OPTS+=(-metadata "genre=$genre")
	fi

	if [[ -n "$year" ]]; then
		META_OPTS+=(-metadata "date=$year")
	fi

	if [[ $# -gt 1 ]]; then
		die_with_usage "$PROGRAM: expected at most one path, got $#"
	fi

	track_list="${1:-.}"

	if [[ "$track_list" != '-' ]]; then
		if [[ ! -e "$track_list" ]]; then
			die "$PROGRAM: path not found: '$track_list'"
		fi
		if [[ ! -r "$track_list" ]]; then
			die "$PROGRAM: path is not readable: '$track_list'"
		fi
	fi

	# Process substitution keeps the loop in this shell: no subshell status
	# loss, and fd 0 stays available to the caller's terminal.
	while IFS= read -r -d '' file; do
		file="${file%$'\r'}"

		if [[ -z "$file" ]]; then
			continue
		fi

		normalize_path "$file"
		file="$NORMALIZED"

		if ! process_file "$file"; then
			status=1
		fi
	done < <(list_files "$track_list")

	return "$status"
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

main "$@"
