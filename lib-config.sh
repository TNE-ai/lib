#!/usr/bin/env/bash
## vi: set syntax=sh sw=4 ts=4 noet:
## configuration editing for Mac and Ubuntu
## inspired by raspiconfig
##

# Shell profile chain — strategy implemented by pre-install.sh
# References:
#   Ubuntu: https://superuser.com/questions/789448/choosing-between-bashrc-profile-bash-profile-etc/789705#789705
#   macOS:  https://apple.stackexchange.com/questions/51036/what-is-the-difference-between-bash-profile-and-bashrc
#   Login detection: https://unix.stackexchange.com/questions/26676/how-to-check-if-a-shell-is-login-interactive-batch
#
# ─── LINUX ────────────────────────────────────────────────────────────────────
# Login shell (ssh, CTRL-ALT-F3 console):
#   /etc/profile → ~/.bash_profile (or ~/.profile if no .bash_profile)
# Terminal emulator (GNOME Terminal etc.): starts a LOGIN shell on Ubuntu
#   ~/.bash_profile → ~/.profile → ~/.bashrc
# Subshell / non-login interactive:
#   ~/.bashrc only  ← PATH from .profile is NOT available here without the guard
#
# ─── MACOS ────────────────────────────────────────────────────────────────────
# IMPORTANT: macOS bash login shells read ~/.bash_profile, ~/.bash_login, or
# ~/.profile — in that order, stopping at the FIRST found. Since ~/.bash_profile
# exists, ~/.profile is NEVER read directly by the shell. It is only sourced
# because ~/.bash_profile explicitly sources it.
#
# Terminal.app / iTerm2: starts a LOGIN shell (unlike most Linux terminals)
#   ~/.bash_profile → ~/.profile → ~/.bashrc
# Subshell / non-login interactive (pipenv, Claude Code, subshells):
#   ~/.bashrc only  ← PATH from .profile is NOT available here without the guard
# ssh:
#   ~/.bash_profile → ~/.profile → ~/.bashrc
#
# ─── ZSH (macOS default since Catalina) ──────────────────────────────────────
# Canonical startup chain (per zsh.sourceforge.io/Intro/intro_3.html):
#   ALL invocations:            ~/.zshenv  (incl. scripts, cron, IDE plugins)
#   Login + interactive:        ~/.zshenv -> ~/.zprofile -> ~/.zshrc -> ~/.zlogin
#   Non-login + interactive:    ~/.zshenv -> ~/.zshrc
#   Non-interactive (scripts):  ~/.zshenv only
#
# macOS quirk: Terminal.app spawns LOGIN shells by default, so .zprofile runs
# on every new terminal window. But subshells (Vim shell, Claude Code, pipe
# to a command) are NON-LOGIN -> .zprofile does NOT run for them.
#
# .zprofile does NOT auto-source .profile. Per r-cto-dev145, the install
# bootstrap (pre-install.sh) calls config_profile_no_script_wire_login to
# add an explicit `[[ -f ~/.profile ]] && . ~/.profile` line to both
# .zprofile AND .bash_profile -- so shell-agnostic env exports in ~/.profile
# reach both shells.
#
# Don't put PATH in ~/.zshrc -- subshells inherit it from .profile via the
# login chain. Only put zsh-specific PATH manipulation in .zshrc (e.g.
# `fpath+=(...)` for zsh completion functions).
#
# ─── THE CRITICAL GAP ─────────────────────────────────────────────────────────
# Both macOS and Linux have the same problem: non-login bash shells (subshells,
# pipenv, Claude Code, any `bash -i`) only read ~/.bashrc. PATH setup in
# ~/.profile never runs, so tools installed to ~/.local/bin (e.g. pipx packages
# like argcomplete) are not found.
#
# THE FIX — _PROFILE_SOURCED guard (implemented by pre-install.sh):
#
#   ~/.profile (top):
#     export _PROFILE_SOURCED=1      ← mark that .profile has run
#     ... PATH setup ...
#     if bash: source ~/.bashrc      ← chain to .bashrc
#
#   ~/.bashrc (top):
#     if [ -z "$_PROFILE_SOURCED" ] && [ -f "$HOME/.profile" ]; then
#       . "$HOME/.profile"           ← non-login shell: pull in PATH
#     fi                             ← guard prevents infinite loop
#
#   Login shell flow:
#     .bash_profile → .profile (sets _PROFILE_SOURCED=1, PATH) → .bashrc
#     .bashrc sees _PROFILE_SOURCED set → skips re-sourcing .profile ✓
#
#   Non-login shell flow:
#     .bashrc → _PROFILE_SOURCED unset → sources .profile
#     .profile sets _PROFILE_SOURCED=1, PATH → sources .bashrc
#     .bashrc sees _PROFILE_SOURCED set → skips re-sourcing .profile ✓
#
# ─── FILE ROLES ───────────────────────────────────────────────────────────────
# .profile:      PATH and exported env vars. POSIX sh syntax only (no bash-isms).
#                Sets _PROFILE_SOURCED=1. Sources .bashrc when running under bash.
# .bash_profile: Sources .profile. Exists only to satisfy macOS login shell lookup.
#                Keep nearly empty — pipenv subshells skip it entirely.
# .bashrc:       Non-exportable bash settings: aliases, functions, completions,
#                history. Sources .profile via guard if not already sourced.
#                Guard interactives with [[ $- == *i* ]].
# .zprofile:     Sources .profile for zsh login shells.
# .zshrc:        All zsh config (both login and non-login — zsh always reads it).
#
# ─── config_profile FUNCTION MAPPING ─────────────────────────────────────────
# config_profile             → .profile (or .zprofile): non-interactive PATH/env
# config_profile_interactive → .bashrc (or .zshrc): interactive/completions
# config_profile_nonexportable → .bashrc (or .zshrc): aliases, unexported settings
# config_profile_shell       → .bashrc (not .bash_profile: pipenv skips .bash_profile)

## config_profile: returns the name of the profile to use for non-interactive command
# this should only be for thing that do not display or require input
# this is normally .zprofile but set to .zshrc in the case where the login
# shell is not zsh. That is if you have a Mac using bash and then escept to
# zsh only sometimess
# set ZSH_VERSION to use .zshrc when zsh is not the login shell

config_profile_zsh() {
	# zsh login — PATH/env exports; also the earliest viable file for zsh op inject
	# (alias: config_profile_exportable_zsh — same file, zsh has no separate ~/.bash_profile)
	echo "$HOME/.zprofile"
}
config_profile_exportable_zsh() {
	# zsh login + op inject — same as config_profile_zsh; alias for naming symmetry with bash
	echo "$HOME/.zprofile"
}
config_profile_bash() {
	# POSIX sh login — PATH/env exports only; no [[ ]], no op inject (r-cto-dev155)
	echo "$HOME/.profile"
}
config_profile_exportable_bash() {
	# bash login — op inject and bash-specific code; uses [[ ]] so cannot go in ~/.profile
	# r-cto-dev155: earliest viable file for bash op inject
	echo "$HOME/.bash_profile"
}
config_profile() {
	if [[ $SHELL =~ zsh || -v ZSH_VERSION ]]; then
		config_profile_zsh
	else
		config_profile_bash
	fi
}

## config_profile_no_script: shell-AGNOSTIC env exports only -- NO commands, NO user input.
## Governed by r-cto-dev145-shell-config-no-script-profile.
##
## Why ~/.profile?
##   - POSIX standard; works in bash, zsh, sh.
##   - Both ~/.bash_profile and ~/.zprofile MUST source it (use
##     config_profile_no_script_wire_login below to ensure this once at install).
##   - By convention, ~/.profile must be non-interactive -- anything that prompts
##     breaks SSH/cron/script flows.
##
## What belongs:  export KEY=VALUE; export PATH=...; silent guards
## What does NOT: op inject, compinit, completions, aliases, anything prompting
config_profile_no_script() {
	echo "$HOME/.profile"
}

## Ensure ~/.bash_profile and ~/.zprofile source ~/.profile.
## Idempotent via config_mark. Call once during install bootstrap.
config_profile_no_script_wire_login() {
	# shellcheck disable=SC2016  # literal expression; expands at shell-read time, not install time
	local source_line='[[ -f "$HOME/.profile" ]] && . "$HOME/.profile"'
	for login_rc in "$HOME/.bash_profile" "$HOME/.zprofile"; do
		if ! config_mark "$login_rc" "#" "" "Source ~/.profile for shell-agnostic env (r-cto-dev145)"; then
			config_add "$login_rc" <<-EOF
				# Source ~/.profile for shell-agnostic env exports (r-cto-dev145).
				$source_line
			EOF
		fi
	done
}

## config the non-login script run with every new shell
# set ZSH_VERSION to use .zshrc
config_profile_nonexportable_zsh() {
	echo "$HOME/.zshrc"
}
config_profile_nonexportable_bash() {
	echo "$HOME/.bashrc"
}
config_profile_nonexportable() {
	if [[ $SHELL =~ zsh || -v ZSH_VERSION ]]; then
		config_profile_nonexportable_zsh
	else
		config_profile_nonexportable_bash
	fi
}

# if this is for initial boot on linux it is .profile
# this should have no output visible
# not used for the Mac
## config_profile_interactive: Use this profile where uses need to see and type
config_profile_interactive_zsh() {
	echo "$HOME/.zshrc"
}
config_profile_interactive_bash() {
	echo "$HOME/.bashrc"
}
config_profile_interactive() {
	if [[ $SHELL =~ zsh || -v ZSH_VERSION ]]; then
		config_profile_interactive_zsh
	else
		config_profile_interactive_bash
	fi
}

config_profile_shell_zsh() {
	echo "$HOME/.zprofile"
}
# ~/.bash_profile runs once per macOS login shell (every new terminal window).
# Prefer it over ~/.bashrc for secrets injection — ~/.bashrc runs on every
# subshell spawn. The old pipenv workaround is no longer relevant.
config_profile_shell_bash() {
	echo "$HOME/.bash_profile"
}
# config_profile_shell: set to .bash_profile or .zprofile if using zsh
config_profile_shell() {
	if [[ -v ZSH_VERSION ]]; then
		config_profile_shell_zsh
	else
		config_profile_shell_bash
	fi
}

## config_profile_for_bash: put bash specific profile in right files for Ubuntu and Mac
# General commands for path setting should be in .profile in /bin/sh syntax
# Bash specific entries should go to .bash_profile for Mac and .bashrc for
# Ubuntu if you are not using pipenv. But if you are using pipenv, then you
# also have to use .bashrc because you will get completions otherwise
#
#
config_profile_for_bash() {
	if in_os mac; then
		# switch to using .bashrc because pipenv only runs .bashrc and you lose
		# completions otherwise
		#config_profile_shell_bash
		config_profile_shell_bash
	else
		config_profile_interactive
	fi
}

## source_profile: $file
# Get the profiles from $dir and source it
# needed when updating paths and want to immediately use the new
# commands in the running script
source_profile() {
	#shellcheck disable=SC2043
	file="${1:-$(config_profile_shell)}"

	if [[ -e $file ]]; then
		# turn off undefined variable checking because
		# scripts like bash completion reference undefined
		# as this is a common idium
		set +u
		# shellcheck disable=SC1090
		source "$file" || true
		set -u
	fi

	# do not do this as this inserts standard paths before the custom ones
	#if [[ $OSTYPE =~ darwin ]] && [[ -e /usr/libexec/path_helper ]]; then
	#    eval "$(/usr/libexec/path_helper)"
	#fi

	# rehash in case the path changes changes the execution order
	hash -r
}

## config_add_shell [new-shell-path]
config_add_shell() {
	local DESIRED_SHELL_PATH
	DESIRED_SHELL_PATH="${1:-"$(brew --prefix)/bin/bash"}"
	if [[ ! -e $DESIRED_SHELL_PATH ]]; then
		return 1
	fi
	if ! grep "$DESIRED_SHELL_PATH" /etc/shells; then
		sudo tee -a /etc/shells <<<"$DESIRED_SHELL_PATH" >/dev/null
	fi
}

## config_default_shell [new-shell-path]
config_change_default_shell() {
	local DESIRED_SHELL_PATH
	DESIRED_SHELL_PATH="${1:-"$(brew --prefix)/bin/bash"}"
	if in_os mac; then
		CURRENT_SHELL_PATH="$(dscl . -read "$HOME" UserShell)"
	else
		CURRENT_SHELL_PATH="$(grep "$USER" /etc/passwd | cut -d ":" -f 7)"
	fi
	log_verbose "Current default shell is $CURRENT_SHELL_PATH"
	# https://stackoverflow.com/questions/16375519/how-to-get-the-default-shell
	if [[ $CURRENT_SHELL_PATH != "$DESIRED_SHELL_PATH" ]]; then
		log_verbose "Default user shell is not $DESIRED_SHELL_PATH"
		log_warning you only get one login opportunity to change the shell so type carefully.
		log_warning "If you do not want to change the chsh just press enter"
		log_warning "if you make a mistake just rerun $SCRIPTNAME"
		chsh -s "$DESIRED_SHELL_PATH"
	fi
}

#
#
# Marker and many lines
# ---------
# the first set just looks for a marker line and then adds a bunch of lines
# it does not examine the specific contents of the lines added.
# This is most useful for large scale configurations where you are really
# adding say lines ot a bash script. The marker line is used (usually Added by

# - config_mark: Looks for a marker line and adds one if not already there
# - config_add: reads from the stdin and splats to the file without # comparing
# - config_add_var: Adds a string to a particular bash variable checking first to see if it is already there
#
# The second does whole line replacement.
# -------
# This looks for entire lines with a PREFIX and replaces them. This is most
# useful for smaller edits at the line level.
# - config_add_once: Add a line in a file if it does not exist
# - config_replace: Looks for a specific line and replaces it with a new one
#
# The final type deals with replacing setting variables
# ------
# This is the most specific, it uses lua to actually replace variables. It
# assumes the format is variable=expression and can actually parse the line.
# This is most useful for config flies like /etc/default/zfs and other sysrtemn
# - get_config_var : read out a variabvle
# - set_config_var : writes one
# - change_config_var: removes an item from the value of a config var
# - clear_config_var : removes it
#
# Utility functions
# -------
# There are some useful functions
# config_sudo: based on the file ownership decide where to use sudo or not
# config_lines_to_line: handles multiple lines additions when doing whole lines
# (obsolete use config_to_sed which also does quotes)
# and make it ready for sed by backquoting special characters

# config_backup takes a set of files and backs them up
# usage: config_backup [files...]
config_backup() {
	for target in "$@"; do
		# https://unix.stackexchange.com/questions/67898/using-the-not-equal-operator-for-string-comparison
		if [[ $target =~ ^(.|..)$ ]]; then
			# ignore $file if it is the CWD or the parent
			continue
		fi
		if [[ -e $target ]]; then
			log_verbose "found $target exists copying it to $target.bak"
			n=0
			backup="$target.bak"
			while [[ -e $backup ]]; do
				# $backup exists
				backup="${backup%.bak*}.bak.$((++n))"
				# try the next file down $backup
			done
		fi
	done
}

# https://stackoverflow.com/questions/29613304/is-it-possible-to-escape-regex-metacharacters-reliably-with-sed
# magical oneliner that handles multiline sed replacement.
# Use for finding and replacing multiple lines in a config file
# does need gnu sed and not mac sed
#
# Changed from stdin to stdout because of One bug is that is always adds a new line if there is just one line
# So you can use set_config_var instead for instance if there is just one line
# usage: to_sed_regex
# stdin: input lines does not work for single lines
# returns: 0 on success
# stdout: the properly escaped string (make sure to quote may have spaces
config_to_sed() {
	# IFS= read -d '' -r < <(sed -e ':a' -e '$!{N;ba' -e '}' -e 's/[&/\]/\\&/g; s/\n/\\&/g' <<<"$1")
	# https://www.cyberciti.biz/faq/unix-howto-read-line-by-line-from-file/
	# IFS=_space_ means that you should read the stdin separated by a space
	# -d '' means the delimiate is a null
	IFS= read -d '' -r < <(sed -e ':a' -e '$!{N;ba' -e '}' -e 's/[&/\]/\\&/g; s/\n/\\&/g')
	# removes the newline that the redirect put in
	# printf %s "${REPLY%$'\n'}"
	# if a single line, remove another so we will have two extras
	printf %s "${REPLY%$'\n\n'}"
}

# https://stackoverflow.com/questions/40573839/how-to-use-printf-q-in-bash
# arguments: all arguments, so you want your text file to be in a bash variable
# stdout: the escaped string suitable for sed
config_to_sed_printf() {
	printf %q "$@"
}

#  works correct using only sed for multiple lines
config_to_sed_multiline() {
	# IFS= read -d '' -r < <(sed -e ':a' -e '$!{N;ba' -e '}' -e 's/[&/\]/\\&/g; s/\n/\\&/g' <<<"$1")
	IFS= read -d '' -r < <(sed -e ':a' -e '$!{N;ba' -e '}' -e 's/[&/\]/\\&/g; s/\n/\\&/g')
	# removes the newline that the redirect put in
	printf %s "${REPLY%$'\n'}"
}

# returns sudo if you need it you need to force evaluation with
# $(config_sudo) which cause sudo to run
# usage: config_sudo files
config_sudo() {
	# use find instead of stat since it works on Mac
	# stat -c '$U' only available with gnu stat
	# if [[ $(stat -c '%U' "$config") != $USER ]]
	# note we do not quote $@ so we can search them all
	# Note that this test does fail because the directory must also be writeable
	# and owned by you so this does not work with `mv` but does with tee
	# if there is no util sudo then make our own because we do not want to
	# depend on lib-util.sh as this system does not allow cascading library
	# dependencies
	for file in "$@"; do
		# get the canonical form or the name assumes you are using the gnu
		file="$(readlink -f "$file")"
		# work up the path of the file until we find a file that exists
		while [[ ! -e $file ]]; do
			file=$(dirname "$file")
		done
		if [[ ! -w $file ]]; then
			echo sudo
		fi
	done
}

# make sure the parent and file exist
# usage: config_touch files...
config_touch() {
	for file in "$@"; do
		if [[ ! -e $file ]]; then
			# cannot use readlink -f not the Mac so use this instead
			# local path=$(readlink -f "$file")
			#does not work if $dir not yet created so do not use
			#this canonical view
			#local dir="$(cd "$(dirname "$file")" && pwd -P)"
			dir="$(dirname "$file")"
			$(config_sudo "$dir") mkdir -p "$dir"
			$(config_sudo "$file") touch "$file"
		fi
	done
}

# converts a bash variable with multiline text
# to a single string with \n in it on stdout
# usage: config_lines_to_line
# stdin: lines that need to be converted
# stdout: single line with \n in them
config_lines_to_line() {
	# note we use quotes on lines to retain the newlines
	# tr then deletes the special character that is a new line
	# sed adds the characters '\' and 'n' not clear why
	# config_to_sed | sed 's/$/\\n/' | tr -d '\n'
	config_to_sed | tr -d '\n'
}

# replaces the original marker work and uses the config_add
# this marks a configuration file as being edited
# It searches the "marker" line and does not add more if it finds it
# and returns the state of the file.
# if the file dopes not exist we create all the parent directories and then the
# file
# usage: config__mark -f [file [ comment-prefix [ comment-postfix [ marker ]]]]
# -f means force a new marker
# returns: 0 if marker was found
#          1 no marker found so we added and this is a fresh file
config_mark() {
	# if (( $# < 1)); then return 1; fi
	local file=${1:-"$(config_profile)"}
	local comment_prefix="${2:-"#"}"
	local comment_postfix="${3:-""}"
	local marker="${4:-"Added by $SCRIPTNAME"}"

	config_touch "$file"
	# JSON/JSONC files cannot have comments — use a _managed_by array key as the marker instead
	if [[ $file == *.json || $file == *.jsonc ]]; then
		if [[ ! -s $file ]]; then echo '{}' >"$file"; fi
		if ! jq -e --arg m "$marker" '._managed_by | index($m)' "$file" >/dev/null 2>&1; then
			local jtmp
			jtmp="$(mktemp "${file}.XXXX")"
			if jq --arg m "$marker" 'if ._managed_by then ._managed_by += [$m] else ._managed_by = [$m] end' "$file" >"$jtmp"; then
				mv "$jtmp" "$file"
			else
				rm -f "$jtmp"
				return 1
			fi
			return 1
		fi
		return 0
	fi
	# need the -- incase the comment_prefix has a leading -
	if ! grep -q -- "$comment_prefix $marker" "$file"; then
		# do not quote config_sudo because it can return null
		# https://stackoverflow.com/questions/3005963/how-can-i-have-a-newline-in-a-string-in-sh
		$(config_sudo "$file") tee -a "$file" <<<$'\n'"$comment_prefix $marker on $(date) $comment_postfix" >/dev/null
		return 1
	fi
}

#
#
# It adds to the stdin use with the redirection <<-EOF typically and then EOF
# usage: config_add [file_to-change] <<-EOF
#        some lines to add
#        EOF
#
# Use config_add_once if you want to replace just a sigle ilne
# this is normally used with config_mark
#
config_add() {
	# if (( $# < 1 )); then return 1; fi
	local file="${1:-"$(config_profile)"}"
	# by default the prefix is the entire line
	# so in the default case it just adds a line
	config_touch "$file"
	local need_sudo
	need_sudo="$(config_sudo "$file")"
	# if output is null then do not put a parameter
	# need_sudo should also  be empty
	$need_sudo tee -a "$file" >/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# JSON config helpers  (config_add_json / config_edit_json / config_upsert_json)
#
# WHY THREE FUNCTIONS?
#
#   Shell scripts often need to add settings to JSON config files idempotently
#   (safe to re-run without creating duplicates or losing user edits).
#   Plain heredocs overwrite the whole file. These helpers use jq to surgically
#   edit only what they touch, preserving everything else.
#
# PATTERN — choose by what you're adding:
#
#   A plain string into an array     →  config_add_json
#   A JSON object into an array      →  config_upsert_json
#   Anything else (scalar, merge…)   →  config_edit_json  (raw jq)
#
# HOW THEY ALL WORK UNDER THE HOOD (ELI5):
#
#   1. Create a temp file next to the target (mktemp).
#   2. Run jq, reading the original file and writing the result to the temp file.
#      jq never touches the original while it's running.
#   3. If jq succeeded, atomically replace the original with mv.
#      If jq failed, delete the temp and return 1 — original is untouched.
#
#   This "write to tmp, then mv" pattern is called an atomic replace.
#   It means a crash or power cut mid-write can never leave a half-written file.
#
# JQ CHEAT SHEET for readers unfamiliar with jq:
#
#   .foo            — read field "foo" from the current object
#   .foo //= []     — if .foo is null or missing, set it to []; otherwise leave it
#   .foo += [$x]    — append $x to the array at .foo
#   map(.name)      — transform every element, keeping only the .name field
#   index($v)       — position of $v in an array, or null if not found
#   --arg  k v      — bind shell string v to jq variable $k (always a string)
#   --argjson k v   — parse shell string v as JSON and bind to $k (preserves type)
# ─────────────────────────────────────────────────────────────────────────────

# Idempotently append a plain string value to a JSON array.
# Mirrors the config_mark / config_add pattern for .json files.
# Creates the file with {} if it does not exist.
# If the jq path does not yet exist it is initialised to [].
#
# ELI5: "Open the JSON file, find the list at json_path, add value to the end
#        of that list — but only if it isn't already there."
#
# usage:   config_add_json file json_path value
# example: config_add_json "$HOME/.config/nvim/lazyvim.json" .extras \
#              "lazyvim.plugins.extras.ai.copilot"
# returns: 0 on success, 1 on bad args or jq error
config_add_json() {
	if (($# < 3)); then return 1; fi
	local file="$1"
	local path="$2"
	local value="$3"
	config_touch "$file"
	if [[ ! -s $file ]]; then echo '{}' >"$file"; fi
	local jtmp
	jtmp="$(mktemp "${file}.XXXX")"
	# jq filter breakdown:
	#   ($path //= [])          — ensure the array exists
	#   if ($path | index($v))  — is $value already in the array?
	#   then .                  — yes: return unchanged
	#   else $path += [$v] end  — no: append it
	if jq --arg v "$value" "($path //= []) | if ($path | index(\$v)) then . else $path += [\$v] end" "$file" >"$jtmp"; then
		mv "$jtmp" "$file"
	else
		rm -f "$jtmp"
		return 1
	fi
}

# Atomically apply any jq filter to a JSON file in-place.
# Creates the file with {} if it does not exist.
# All arguments after the file are forwarded verbatim to jq.
#
# ELI5: "Run whatever jq command you give me against the file, and save the
#        result back — safely, so a crash can't corrupt the file."
#
# usage:   config_edit_json file [jq_flags...] jq_filter
# example: config_edit_json "$HOME/.config/app.json" '.LOG //= true'
# example: config_edit_json "$HOME/.config/app.json" \
#              --argjson defaults '{"timeout":30}' \
#              '.settings = ($defaults + (.settings // {}))'
# returns: 0 on success, 1 on jq error
config_edit_json() {
	if (($# < 2)); then return 1; fi
	local file="$1"
	shift
	config_touch "$file"
	if [[ ! -s $file ]]; then echo '{}' >"$file"; fi
	local jtmp
	jtmp="$(mktemp "${file}.XXXX")"
	if jq "$@" "$file" >"$jtmp"; then
		mv "$jtmp" "$file"
	else
		rm -f "$jtmp"
		return 1
	fi
}

# Upsert a JSON object into a JSON array, matched by a key field.
# Appends the object if no entry with the same key value exists; no-op if present.
# Creates the file with {} if it does not exist.
#
# ELI5: "Open the JSON file, find the list at array_path, look through every
#        item's key_field — if none of them match our new object's key_field,
#        add the new object to the end of the list."
#
# usage:   config_upsert_json file array_path key_field json_object
# example: config_upsert_json "$HOME/.config/app.json" .providers name \
#              '{"name":"openai","url":"https://api.openai.com"}'
# returns: 0 on success, 1 on error
config_upsert_json() {
	if (($# < 4)); then return 1; fi
	local file="$1"
	local array_path="$2"
	local key_field="$3"
	local obj="$4"
	# jq filter breakdown:
	#   ($array_path //= [])                      — ensure the array exists
	#   $array_path | map(.[$k])                  — collect all existing key values
	#   | index($obj[$k])                         — is our key already in that list?
	#   if ... != null then .                     — yes: return unchanged
	#   else $array_path += [$obj] end            — no: append the new object
	config_edit_json "$file" --arg k "$key_field" --argjson obj "$obj" \
		"($array_path //= []) |
		 if ($array_path | map(.[\$k]) | index(\$obj[\$k])) != null
		 then .
		 else $array_path += [\$obj]
		 end"
}

# YAML config helpers (config_edit_yaml / config_upsert_yaml / config_set_yaml)
#
# Require yq v4 (https://github.com/mikefarah/yq) — `brew install yq`.
# Mirror the JSON helpers above but operate on YAML files.
# All three use the same atomic tmp→mv pattern for crash-safety.
#
# PATTERN — choose by what you're doing:
#
#   Set/overwrite a scalar or object   →  config_set_yaml
#   Upsert an object in a YAML array   →  config_upsert_yaml
#   Any raw yq expression              →  config_edit_yaml
#
# YQ CHEAT SHEET (v4):
#   .foo                  — read field foo
#   .foo = "bar"          — set scalar
#   .foo.bar |= . + [x]   — append to array
#   .[] | select(.name == "x")  — filter array by key
#   with_entries(...)     — transform map entries
#   env(VAR)              — read shell env var inside yq expression

# Atomically apply a yq v4 expression to a YAML file in-place.
# Creates the file with {} if it does not exist.
# NOTE: yq v4 does NOT support --arg/--argjson (those are jq flags).
#       Pass variables via shell env and read with env(VAR) in the expression.
# usage:   config_edit_yaml file expression
# example: config_edit_yaml ~/.config/app.yaml '.server.port = 4000'
# returns: 0 on success, 1 on yq error
config_edit_yaml() {
	if (($# < 2)); then return 1; fi
	local file="$1"
	local expr="$2"
	[[ -f "$file" ]] || echo '{}' >"$file"
	local ytmp
	ytmp="$(mktemp "${file}.XXXX")"
	if yq -P "$expr" "$file" >"$ytmp"; then
		mv "$ytmp" "$file"
	else
		rm -f "$ytmp"
		return 1
	fi
}

# Idempotently set a scalar or object at a yq path.
# usage:   config_set_yaml file yq_path value
# example: config_set_yaml litellm_config.yaml '.litellm_settings.mlflow_tracking_uri' '"http://localhost:5001"'
# returns: 0 on success, 1 on error
config_set_yaml() {
	if (($# < 3)); then return 1; fi
	local file="$1"
	local ypath="$2"
	local value="$3"
	config_edit_yaml "$file" "${ypath} = ${value}"
}

# Idempotently upsert an object (given as JSON) into a YAML array, keyed by a field.
# Replaces any existing entry with the same key value; appends if absent.
# Uses shell env vars + yq env() — no --arg needed (yq v4 doesn't support --arg).
# usage:   config_upsert_yaml file array_path key_field json_object
# example: config_upsert_yaml litellm_config.yaml .model_list model_name \
#              '{"model_name":"kimi","litellm_params":{"model":"openai/moonshot-v1-8k"}}'
# returns: 0 on success, 1 on error
config_upsert_yaml() {
	if (($# < 4)); then return 1; fi
	local file="$1"
	local array_path="$2"
	local key_field="$3"
	local obj="$4"
	local key_value
	key_value=$(printf '%s' "$obj" | jq -r ".${key_field}" 2>/dev/null) ||
		{
			echo "config_upsert_yaml: invalid JSON object" >&2
			return 1
		}
	# Export as env vars so yq can read them via env()
	# _CUY_KF = key field name, _CUY_KV = key value, _CUY_OBJ = JSON object string
	# strenv() (not env()) because the value is a multi-char string; from_yaml parses JSON too
	_CUY_KF="$key_field" \
		_CUY_KV="$key_value" \
		_CUY_OBJ="$obj" \
		config_edit_yaml "$file" \
		"${array_path} = ((${array_path} // []) | map(select(.[env(_CUY_KF)] != env(_CUY_KV)))) + [strenv(_CUY_OBJ) | from_yaml]"
}

#
# config_add_var [file|""] variable strings...
# adds a string to a bash variable at the beginning assuming the variable doesn'
# to use the default file, pass a null
# config_add_var "" var strings..
config_add_var() {
	if (($# < 2)); then return 1; fi
	local file="${1:-"$(config_profile)"}"
	local variable="${2:-"PATH"}"
	shift 2
	for string in "$@"; do
		config_add "$file" <<<-"[[ \$$variable =~ $string ]] || export $variable=\"$string\:\$$variable ]]"
	done
}

# Adds a line if it is not already there
# It looks for a prefix and then slams a new line in if it findds it
# forces a replacement if it already exists
# the replacement can be multiple lines
# flags: -x this flag means if you find an instance don't replace
#        the default is you replace a single line
# usage: config_replace [-n] [file| ""] prefix-of-of-the-line-to-be-replaced lines-to-add
config_replace() {
	if (($# < 3)); then return 1; fi
	local MULTILINE=false
	if [[ $1 == -x ]]; then
		local MULTILINE=true
		shift
	fi
	local file="${1:-"$(config_profile)"}"
	local target="${2:-""}"
	local lines="${3:-""}"

	# shold not need to touch assume file existrs
	config_touch "$file"
	need_sudo="$(config_sudo "$file")"
	# not sure but $ means an exact match
	# so if we want to majhc then need to do
	# usage: config_add_lines [-f] [file [ lines ]]
	echo grep -q "^$target" "$file"
	if ! grep -q "^$target" "$file"; then
		# did not find the target so just add the entire line
		log_verbose "did not find ^$target in $file adding $lines"
		# do not quote need_sudo as it can be null if not needed
		$need_sudo tee -a "$file" <<<"$lines" >/dev/null
	elif ! $MULTILINE; then
		# note this requires gnu sed running on a Mac
		# fails with the installed sed
		# to make change work we need to convert
		# $new with real new lines into something with \n in
		# a single string
		# local new_sed="$(config_to_line <<<"$lines")"
		local new_sed
		new_sed="$(config_to_sed <<<"$lines")"
		echo "new=$new_sed"
		local target
		target_sed="$(config_to_sed <<<"$target")"
		echo "target=$target_sed"
		# do not quote need_sudo in case it is null
		# echo $need_sudo sed -i "/^$target_sed/c\\$new_sed" "$file"
		if [[ $(command -v sed) =~ /usr/bin/sed ]]; then
			# this means we do not have gsed and -i will not work
			brew install gnu-sed
			PATH="/usr/local/opt/gnu-sed/libexec/gnubin:$PATH"
		fi
		$need_sudo sed -i "/^$target_sed/c\\$new_sed" "$file"
		return
	fi

}

# used config_replace but adds a line only if not present
# usage: config_add_once [file| ""] line-to-add
# null first parameter means take the default
# config_replace_once: idempotently add or upgrade a line in a config file.
#
# usage:  config_replace_once file pattern line
#   file    — target config file (default: config_profile)
#   pattern — regex to match the existing (possibly stale) line
#   line    — the canonical line that must end up in the file
#
# Behaviour:
#   - LINE already present verbatim → no-op
#   - PATTERN found (old/stale form) → replace first match with LINE in-place
#   - Neither found → append LINE
#
# Use when the canonical form of a line changes over time (e.g. adding a flag)
# so re-running upgrades old installs rather than leaving stale duplicates.
#
# example:
#   config_replace_once ~/.zshrc "compinit" \
#       "fpath+=~/.zfunc; autoload -Uz compinit; compinit -d ~/.zcompdump"
config_replace_once() {
	if (($# < 3)); then return 1; fi
	local file="${1:-"$(config_profile)"}"
	local pattern="$2"
	local line="$3"
	config_touch "$file"
	if grep -qF "$line" "$file"; then
		return 0
	fi
	if grep -q "$pattern" "$file"; then
		echo "replacing '$pattern' with canonical line in $file"
		local tmp
		tmp="$(mktemp "${file}.XXXX")"
		if awk -v pat="$pattern" -v rep="$line" -v done=0 \
			'!done && $0 ~ pat { print rep; done=1; next } { print }' \
			"$file" >"$tmp"; then
			$(config_sudo "$file") mv "$tmp" "$file"
		else
			rm -f "$tmp"
		fi
	else
		echo "adding line to $file"
		$(config_sudo "$file") tee -a "$file" <<<"$line" >/dev/null
	fi
}

# config_add_once: idempotently append a line if not already present.
# Thin wrapper around config_replace_once for backward compatibility.
# Prefer config_replace_once when the line may evolve over time.
config_add_once() {
	if (($# < 2)); then return 1; fi
	local file="${1:-"$(config_profile)"}"
	shift
	local line="$*"
	config_replace_once "$file" "$line" "$line"
}

# for bash_profile, sources .profile and .bashrc. For zsh source .profile as
# .zshrc is always sourced afterwads
# you should guard this with a config_mark_setup
# typically config_profile_shell is .bash_profile
# This assumes that pre-install does the basic scaffolding and connection
# of .bash_profile -> .profile -> .bashrc

## config_setup_end: run this at the end so .rc files run after all the paths are set
# to do we should create a function that checks and makes sure this is always
# last in the .profile ONly needed for bash as zsh does this automatically
# I'm not quire sure why this is needed as this causes an infinite loop
config_setup_end() {
	if [[ $SHELL =~ zsh || -v ZSH_VERSION ]]; then
		return
	fi
	if ! config_mark "$(config_profile_nonexportable_bash)"; then
		config_add "$(config_profile_nonexportable_bash)" <<-EOF
			if echo "$BASH" | grep -q bash && [-f "$(config_profile_bash)" ]; then
				source "$(config_profile_bash)"; fi
		EOF
	fi
}

# params file variable value
# usage: set_config_var [-f] key value file [marker]
set_config_var() {
	if (($# < 3)); then return 1; fi
	local force=false
	if [[ $1 == -f ]]; then
		force=true
		shift
	fi
	local key="$1"
	local value="$2"
	local file="$3"
	local marker="${4:-"Added by $SCRIPTNAME"}"
	if ! $force && grep "$marker" "$file"; then
		return
	fi
	local temp
	temp="$(mktemp)"
	lua - "$key" "$value" "$file" <<EOF >"$temp"
local key=assert(arg[1])
local value=assert(arg[2])
local fn=assert(arg[3])
local file=assert(io.open(fn))
local made_change=false
for line in file:lines() do
  if line:match("^#?%s*"..key.."=.*$") then
	line=key.."="..value
	made_change=true
  end
  print(line)
end
if not made_change then
  print(key.."="..value)
end
EOF

	# note you should not move the file but tee into it
	$(config_sudo "$file") tee "$file" <"$temp" >/dev/null
}

# change part of a  configuration variable
# most useful when there is a long string and you just want to delete one item
# GRUB_CMGLINE is an example where you just want to remove the variable QUIET in
# the string
# usage: modify_config_var key old_value new_value file [marker]
modify_config_var() {
	if (($# < 4)); then return 1; fi
	local key="$1"
	local current_value="$2"
	local new_value="$3"
	local file="$4"
	local marker="${$:-"Added by $SCRIPTNAME"}"
	local current_line
	current_line=$(get_config_var "$key" "$file")
	# do not need eval because you can use variables in bash substitutions
	local new_line=${current_line/$current_value/$new_value}
	set_config_var "$key" "$new_line" "$file"
}

# clears teh config variable
# usage: clear_config_var [-f] key file [marker]
clear_config_var() {
	if (($# < 2)); then return 1; fi
	local force=false
	if [[ $1 == -f ]]; then
		force=true
		shift
	fi
	local key="$1"
	local file="$2"
	local marker="${3:-"Added by $SCRIPTNAME"}"
	if ! $force && grep "$marker" "$file"; then
		return
	fi
	local temp
	temp="$(mktemp)"
	lua - "$key" "$file" <<EOF >"$temp"
local key=assert(arg[1])
local fn=assert(arg[2])
local file=assert(io.open(fn))
for line in file:lines() do
  if line:match("^%s*"..key.."=.*$") then
	line="#"..line
  end
  print(line)
end
EOF
	$(config_sudo "$file") mv "$temp" "$file"
	rm "$temp"
}

# get the state of the config variable after the equal sign
# usage: get_config_var key file
get_config_var() {
	if (($# < 2)); then return 1; fi
	local key="$1"
	local file="$2"
	lua - "$key" "$file" <<EOF
local key=assert(arg[1])
local fn=assert(arg[2])
local file=assert(io.open(fn))
local found=false
for line in file:lines() do
  local val = line:match("^%s*"..key.."=(.*)$")
  if (val ~= nil) then
	print(val)
	found=true
	break
  end
end
if not found then
   print(0)
end
EOF
}
