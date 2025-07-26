# Copyright (c) 2012-2013 Baptiste Daroussin <bapt@FreeBSD.org>
# Copyright (c) 2012-2014 Bryan Drewery <bdrewery@FreeBSD.org>
# All rights reserved.
# 
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
# 
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.

# shellcheck shell=ksh

_wait() {
	local wret ret pid

	if [ "$#" -eq 0 ]; then
		return 0
	fi

	ret=0
	for pid in "$@"; do
		while :; do
			wret=0
			wait "${pid}" || wret="$?"
			case "${wret}" in
			157) # SIGINFO [EINTR]
				continue
				;;
			0) ;;
			*) ret="${wret}" ;;
			esac
			break
		done
	done

	return "${ret}"
}

case "$(type pwait)" in
"pwait is a shell builtin")
	PWAIT_BUILTIN=1
	;;
esac
# Wrapper to fix -t 0 and assert on errors.
pwait() {
	[ "$#" -ge 1 ] || eargs pwait '[pwait flags]' pids
	local OPTIND=1 flag
	local ret oflag timeout vflag

	while getopts "ot:v" flag; do
		case "${flag}" in
		o) oflag=1 ;;
		t) timeout="${OPTARG}" ;;
		v) vflag=1 ;;
		*) err 1 "pwait: Invalid flag ${flag}" ;;
		esac
	done
	shift $((OPTIND-1))

	[ "$#" -ge 1 ] || eargs pwait '[pwait flags]' pids
	case "${timeout}" in
	0) timeout="0.00001" ;;
	esac
	ret=0
	# If pwait is NOT builtin then sh will update its jobs state
	# which means we may pwait on dead procs unexpectedly. It returns
	# status==0 but may write to stderr.
	case "${PWAIT_BUILTIN:-0}" in
	1)
		command pwait \
		    ${timeout:+-t "${timeout}"} ${vflag:+-v} ${oflag:+-o} \
		    "$@" || ret="$?"
		;;
	*)
		command pwait \
		    ${timeout:+-t "${timeout}"} ${vflag:+-v} ${oflag:+-o} \
		    "$@" 2>/dev/null || ret="$?"
		;;
	esac
	case "${ret}" in
	124|0) return "${ret}" ;;
	esac
	err "${EX_SOFTWARE}" "pwait: timeout=${timeout} pids=${pids}"
}

timed_wait_and_kill_job() {
	[ "$#" -eq 2 ] || eargs timed_wait_and_kill_job time jobid
	local timeout="$1"
	local jobid="$2"

	case "${jobid}" in
	"%"*) ;;
	*)
		err "${EX_USAGE}" "timed_wait_and_kill_job: Only %jobid is supported."
		;;
	esac

	# Wait $timeout
	# kill -TERM
	# Wait 1
	# kill -KILL
	_kill_job timed_wait_and_kill_job "${jobid}" \
	    ":${timeout}" TERM ":1" KILL
}

kill_job() {
	[ "$#" -eq 2 ] || eargs kill_job timeout jobid
	local timeout="$1"
	local jobid="$2"

	# kill -TERM
	# Wait $timeout
	# kill -KILL
	_kill_job kill_job "${jobid}" \
	    TERM ":${timeout}" KILL
}

# _kill_job funcname jobid :${wait-timeout} SIG :${wait-timeout} SIG
_kill_job() {
	[ "$#" -ge 3 ] || eargs _kill_job funcname jobid 'killspec'
	local funcname="$1"
	local jobid="$2"
	local timeout ret pgid status action

	shift 2
	if ! jobid "${jobid}" >/dev/null; then
		if jobid "%${jobid}" >/dev/null; then
			err "${EX_SOFTWARE}" "${funcname}: trying to kill unknown job ${jobid}: Did you mean %${jobid}?"
		fi
		err "${EX_SOFTWARE}" "${funcname}: trying to kill unknown job ${jobid}"
	fi
	ret=0
	case "${jobid}" in
	"%"*)
		pgid="$(jobs -p "${jobid}")"
		;;
	*)
		pgid="${jobid}"
		get_job_id "${pgid}" jobid ||
		    err "${EX_SOFTWARE}" "${funcname}: Failed to get jobid for pgid=${pgid}"
		jobid="%${jobid}"
		;;
	esac
	msg_dev "${funcname} job ${jobid} pgid=${pgid} spec: $*"
	for action in "$@"; do
		case "${action}" in
		":"*) timeout="${action#:}" ;;
		*) unset timeout ;;
		esac
		get_job_status "${jobid}" status ||
		    err "${EX_SOFTWARE}" "${funcname}: Could not get status for job ${jobid}"
		case "${status}" in
		"Running")
			case "${timeout:+set}" in
			set)
				msg_dev "Pwait -t ${timeout} on ${status} job=${jobid} pgid=${pgid}"
				pwait -t "${timeout}" "${pgid}" || ret="$?"
				case "${ret}" in
				124)
					# Timeout. Keep going on the
					# action list.
					continue
					;;
				*)
					# Nothing running. Drop out and wait.
					break
					;;
				esac
				;;
			*)
				msg_dev "Killing -${action} ${status} job=${jobid} pgid=${pgid}"
				if ! kill -STOP "${jobid}" ||
				    ! kill -"${action}" "${jobid}" ||
				    ! kill -CONT "${jobid}"; then
					# This should never happen
					err "${EX_SOFTWARE}" "${funcname}: Error killing ${jobid}: $?"
				fi
				;;
			esac
			;;
		*)
			# Nothing running. Drop out and wait.
			;;
		esac
	done
	msg_dev "Collecting ${status} job=${jobid} pgid=${pgid}"
	_wait "${jobid}" || ret="$?"
	case "${ret}" in
	143) ret=0 ;;
	esac
	msg_dev "Job ${jobid} pgid=${pgid} exited ${ret}"
	return "${ret}"
}

pwait_jobs() {
	[ "$#" -ge 0 ] || eargs pwait_jobs '[pwait flags]' '%job...'
	local jobno pids allpids job_status
	local OPTIND=1 flag
	local oflag timeout vflag
	local jobs_jobid
	local -

	while getopts "ot:v" flag; do
		case "${flag}" in
		o) oflag=1 ;;
		t) timeout="${OPTARG}" ;;
		v) vflag=1 ;;
		*) err 1 "pwait: Invalid flag ${flag}" ;;
		esac
	done
	shift $((OPTIND-1))

	case "$#" in
	0) return 0 ;;
	esac

	for jobno in "$@"; do
		case "${jobno}" in
		"%"*) ;;
		*) err "${EX_SOFTWARE}" "pwait_jobs: invalid job spec: ${jobno}" ;;
		esac
	done

	allpids=
	# Each $(jobs) calls (wait4(2)) so rather than fetch status from
	# $(jobs) for each pid just fetch it once and then check each
	# pid for what we care about.
	while mapfile_read_loop_redir jobs_jobid job_status; do
		for jobno in "$@"; do
			case "${jobno}" in
			"${jobs_jobid}") ;;
			*) continue ;;
			esac
			case "${job_status}" in
			"Running") ;;
			*)
				# Unless the job is *Running* there is nothing to do.
				continue
				;;
			esac
			pids="$(jobid "${jobno}")" ||
			    err "${EX_SOFTWARE}" "kill_jobs: jobid"
			allpids="${allpids:+${allpids} }${pids}"
		done
	done <<-EOF
	$(jobs_with_statuses "$(jobs)")
	EOF
	case "${allpids:+set}" in
	set) ;;
	*)
		# No pids to check. So everything is Done.
		return 0
		;;
	esac
	set -o noglob
	# shellcheck disable=SC2086
	pwait -t "${timeout}" ${vflag:+-v} ${oflag:+-o} ${allpids}
}

kill_jobs() {
	[ "$#" -ge 1 ] || eargs kill_jobs '[timeout]' '%job...'
	local timeout="${1:-5}"
	shift
	local ret jobno

	case "$#" in
	0) return 0 ;;
	esac
	ret=0
	for jobno in "$@"; do
		case "${jobno}" in
		"%"*) ;;
		*) err "${EX_SOFTWARE}" "kill_jobs: invalid job spec: ${jobno}" ;;
		esac
		kill_job "${timeout}" "${jobno}" || ret="$?"
	done
	return "${ret}"
}

kill_all_jobs() {
	[ "$#" -eq 0 ] || [ "$#" -eq 1 ] || eargs kill_all_jobs '[timeout]'
	local timeout="${1:-5}"
	local jobid ret rest alljobs
	local -

	msg_dev "Jobs: $(jobs -l)"
	ret=0
	alljobs=
	while mapfile_read_loop_redir jobid rest; do
		case "${jobid:+set}" in
		set) ;;
		*) continue ;;
		esac
		case "${jobid}" in
		"["*"]")
			# [1] + 52255 Running
			;;
		*)
			# If a job has a pipe it may list out multiple pids.
			# The jobid gets read on the first line.
			# [1] + 52255 Running
			#       52256
			continue
			;;
		esac
		jobid="${jobid#"["}"
		jobid="${jobid%%"]"*}"
		alljobs="${alljobs:+${alljobs} }%${jobid}"
	done <<-EOF
	$(jobs -l)
	EOF
	set -o noglob
	# shellcheck disable=SC2086
	kill_jobs "${timeout}" ${alljobs} || ret="$?"
	set +o noglob
	case "${ret}" in
	143) ret=0 ;;
	esac
	return "${ret}"
}

_parallel_exec() {
	local ret=0
	local - # Make `set +e` local
	local errexit=0

	# Disable -e so that the actual execution failing does not
	# return early and prevent notifying the FIFO that the
	# exec is done
	case $- in *e*) errexit=1;; esac
	set +e
	(
		# Do still cause the actual command to return
		# non-zero if it has any failures, if caller
		# was set -e as well. Using 'if cmd' or 'cmd || '
		# here would disable set -e in the cmd execution
		if [ "${errexit}" -eq 1 ]; then
			set -e
		fi
		"$@"
	)
	ret=$?
	echo . >&9 || :
	exit ${ret}
	# set -e will be restored by 'local -'
}

parallel_start() {
	local fifo

	case "${NBPARALLEL:+set}" in
	set)
		echo "parallel_start: Already started" >&2
		return 1
		;;
	esac
	fifo="$(mktemp -ut parallel.pipe)"
	mkfifo "${fifo}"
	exec 9<> "${fifo}"
	unlink "${fifo}" || :
	NBPARALLEL=0
	PARALLEL_JOBNOS=""
	: "${PARALLEL_JOBS:="$(sysctl -n hw.ncpu)"}"
	_SHOULD_REAP=0
	delay_pipe_fatal_error
}

# For all running children, look for dead ones, collect their status, error out
# if any have non-zero return, and then remove them from the PARALLEL_JOBNOS
# list.
_reap_children() {
	local jobno jobs_jobid jobs_status ret

	ret=0
	while mapfile_read_loop_redir jobs_jobid jobs_status; do
		for jobno in ${PARALLEL_JOBNOS-}; do
			case "${jobno}" in
			"${jobs_jobid}") ;;
			*) continue ;;
			esac
			case "${jobs_status}" in
			"Running") continue ;;
			esac
			_wait "${jobno}" || ret="$?"
			list_remove PARALLEL_JOBNOS "${jobno}" ||
			    err 1 "_reap_children did not find ${jobno} in PARALLEL_JOBNOS"
		done
	done <<-EOF
	$(jobs_with_statuses "$(jobs)")
	EOF

	return "${ret}"
}

# Wait on all remaining running processes and clean them up. Error out if
# any have non-zero return status.
parallel_stop() {
	[ "$#" -eq 0 ] || [ "$#" -eq 1 ] || eargs parallel_stop '[do_wait]'
	local do_wait="${1:-1}"
	local ret
	local jobno -

	ret=0
	if [ "${do_wait}" -eq 1 ]; then
		set -o noglob
		# shellcheck disable=SC2086
		_wait ${PARALLEL_JOBNOS} || ret="$?"
		set +o noglob
	fi

	exec 9>&-
	unset PARALLEL_JOBNOS
	unset NBPARALLEL

	case "${ret}" in
	0)
		if check_pipe_fatal_error; then
			ret=1
		fi
		;;
	esac

	return "${ret}"
}

parallel_shutdown() {
	local ret -
	local parallel_jobnos jobno

	set -o noglob
	ret=0
	# PARALLEL_JOBNOS may be stale if we received SIGINT while
	# inside of parallel_stop() or _reap_children(). Clean it up
	# before kill_job() is called which asserts that all jobs are
	# known.
	unset parallel_jobnos
	for jobno in ${PARALLEL_JOBNOS-}; do
		if ! jobid "${jobno}" >/dev/null 2>&1; then
			continue
		fi
		parallel_jobnos="${parallel_jobnos:+${parallel_jobnos} }${jobno}"
	done
	# shellcheck disable=SC2086
	kill_jobs 30 ${parallel_jobnos-} || ret="$?"
	parallel_stop 0 || ret="$?"
	return "${ret}"
}

parallel_run() {
	local ret spawn_jobid

	ret=0

	# Occasionally reap dead children. Don't do this too often or it
	# becomes a bottleneck. Do it too infrequently and there is a risk
	# of PID reuse/collision
	_SHOULD_REAP="$((_SHOULD_REAP + 1))"
	case "${_SHOULD_REAP}" in
	16)
		_SHOULD_REAP=0
		_reap_children || ret="$?"
		;;
	esac

	# Only read once all slots are taken up; burst jobs until maxed out.
	# NBPARALLEL is never decreased and only increased until maxed.
	case "${NBPARALLEL}" in
	"${PARALLEL_JOBS}")
		local a

		if read_blocking a <&9; then
			case "${a}" in
			".") ;;
			*) err 1 "parallel_run: Invalid token: ${a}" ;;
			esac
		fi
		;;
	esac

	if [ "${NBPARALLEL}" -lt "${PARALLEL_JOBS}" ]; then
		NBPARALLEL="$((NBPARALLEL + 1))"
	fi
	PARALLEL_CHILD=1 spawn_job _parallel_exec "$@"
	list_add PARALLEL_JOBNOS "%${spawn_jobid}"

	return "${ret}"
}

nohang() {
	[ "$#" -gt 5 ] || eargs nohang cmd_timeout log_timeout logfile pidfile cmd
	local cmd_timeout
	local log_timeout
	local logfile
	local pidfile
	local childpid
	local now starttime
	local fifo
	local n
	local read_timeout
	local ret=0

	cmd_timeout="$1"
	log_timeout="$2"
	logfile="$3"
	pidfile="$4"
	shift 4

	read_timeout="$((log_timeout / 10))"

	fifo="$(mktemp -ut nohang.pipe)"
	mkfifo "${fifo}"
	# If the fifo is over NFS, newly created fifos have the server's
	# mtime not the client's mtime until the client writes to it
	touch "${fifo}"
	exec 8<> "${fifo}"
	unlink "${fifo}" || :

	starttime="$(clock -epoch)"

	# Run the actual command in a child subshell
	(
		trap - INT
		local ret=0
		if [ "${OUTPUT_REDIRECTED:-0}" -eq 1 ]; then
			exec 3>&- 4>&-
			unset OUTPUT_REDIRECTED OUTPUT_REDIRECTED_STDERR \
			    OUTPUT_REDIRECTED_STDOUT
		fi
		_spawn_wrapper "$@" || ret=1
		# Notify the pipe the command is done
		echo "done" >&8 2>/dev/null || :
		exit "${ret}"
	) &
	childpid=$!
	echo "${childpid}" > "${pidfile}"

	# Now wait on the cmd with a timeout on the log's mtime
	while :; do
		if ! kill -0 "${childpid}" 2>/dev/null; then
			_wait "${childpid}" || ret=1
			break
		fi

		# Wait until it is done, but check on it every so often
		# This is done instead of a 'sleep' as it should recognize
		# the command has completed right away instead of waiting
		# on the 'sleep' to finish
		n=
		read_blocking -t "${read_timeout}" n <&8 || :
		case "${n}" in
		done)
			_wait "${childpid}" || ret=1
			break
			;;
		esac

		# Not done, was a timeout, check the log time
		lastupdated="$(stat -f "%m" "${logfile}")"
		now="$(clock -epoch)"

		# No need to actually kill anything as stop_build()
		# will be called and kill -9 -1 the jail later
		if [ "$((now - lastupdated))" -gt "${log_timeout}" ]; then
			ret=2
			break
		elif [ "$((now - starttime))" -gt "${cmd_timeout}" ]; then
			ret=3
			break
		fi
	done

	exec 8>&-

	unlink "${pidfile}" || :

	return "${ret}"
}

if [ -f /usr/bin/protect ] && [ "$(/usr/bin/id -u)" -eq 0 ]; then
	PROTECT=/usr/bin/protect
fi
madvise_protect() {
	[ "$#" -eq 1 ] || eargs madvise_protect pid
	local pid="$1"

	case "${PROTECT:+set}" in
	set) ;;
	*)
		return 0
		;;
	esac
	case "${pid}" in
	-*)
		msg_debug "Protecting PGID ${pid}"
		${PROTECT} -g "${pid#-}" 2>/dev/null || :
		;;
	*)
		msg_debug "Protecting process ${pid}"
		${PROTECT} -p "${pid}" 2>/dev/null || :
		;;
	esac
}

# Output $(jobs) in a simpler format
jobs_with_statuses() {
	[ "$#" -eq 1 ] || eargs jobs_with_statuses "\$(jobs)"
	local jobs_output="$1"
	local jobs_jobid jobs_rest
	local jws_jobid jws_status
	local - jws_arg

	while mapfile_read_loop_redir jobs_jobid jobs_rest; do
		case "${jobs_jobid}" in
		"["*"]")
			jws_jobid="${jobs_jobid#"["}"
			jws_jobid="${jws_jobid%%"]"*}"
			;;
		*) continue ;;
		esac
		set -o noglob
		# shellcheck disable=SC2086
		set -- ${jobs_rest}
		set +o noglob
		for jws_arg in "$@"; do
			case "${jws_arg}" in
			"+"|"-") continue ;;
			[0-9][0-9]|\
			[0-9][0-9][0-9]|\
			[0-9][0-9][0-9][0-9]|\
			[0-9][0-9][0-9][0-9][0-9]|\
			[0-9][0-9][0-9][0-9][0-9][0-9]|\
			[0-9][0-9][0-9][0-9][0-9][0-9][0-9]|\
			[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) continue ;;
			*)
				jws_status="${jws_arg}"
				break
				;;
			esac
		done
		echo "%${jws_jobid} ${jws_status}"
	done <<-EOF
	${jobs_output}"
	EOF
}

get_job_status() {
	[ "$#" -eq 2 ] || eargs get_job_status pid var_return
	local gjs_pid="$1"
	local gjs_var_return="$2"
	local gjs_output ret
	local - gjs_arg

	# Trigger checkzombies(). pwait_racy() in jobs.sh test can make it
	# appear that this is useless since it execs ps and forces a check.
	# But without an external fork+exec, or jobs(1) call, the job status
	# does not update.
	jobs >/dev/null || :
	gjs_output="$(jobs -l "${gjs_pid}")" || ret="$?"
	case "${gjs_pid}" in
	"%"*)
		case "${gjs_output}" in
		"[${gjs_pid#%}] "?" "*)
			;;
		"")
			setvar "${gjs_var_return}" "" || return
			return "${ret}"
			;;
		*)
			err "${EX_SOFTWARE}" "get_job_status: Failed to parse jobs -l output for job ${gjs_pid}: $(echo "${gjs_output}" | cat -vet)"
			;;
		esac
		;;
	*)
		case "${gjs_output}" in
		# First cases cover piped jobs.
		"["*"] "?" "[0-9]*$'\n'*" "[0-9]*$'\n'*" ${gjs_pid} "*|\
		"["*"] "?" "[0-9]*$'\n'*" ${gjs_pid} "*|\
		"["*"] "?" ${gjs_pid} "*)
			;;
		"")
			setvar "${gjs_var_return}" "" || return
			return "${ret}"
			;;
		*)
			err "${EX_SOFTWARE}" "get_job_status: Failed to parse jobs -l output for pid ${gjs_pid}: $(echo "${gjs_output}" | cat -vet)"
			;;
		esac
		;;
	esac
	set -o noglob
	# shellcheck disable=SC2086
	set -- ${gjs_output}
	set +o noglob
	for gjs_arg in "$@"; do
		case "${gjs_arg}" in
		"["*"]") continue ;;
		"+"|"-") continue ;;
		[0-9][0-9]|\
		[0-9][0-9][0-9]|\
		[0-9][0-9][0-9][0-9]|\
		[0-9][0-9][0-9][0-9][0-9]|\
		[0-9][0-9][0-9][0-9][0-9][0-9]|\
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9]|\
		[0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) continue ;;
		*)
			setvar "${gjs_var_return}" "${gjs_arg}" || return
			return 0
		esac
	done

	setvar "${gjs_var_return}" "" || return
	return 1
}

get_job_id() {
	[ "$#" -eq 2 ] || eargs get_job_id pid var_return
	local gji_pid="$1"
	local gji_var_return="$2"
	local gji_jobid gji_output ret

	gji_output="$(jobs -l "${gji_pid}")" || ret="$?"
	case "${gji_output}" in
	# First cases cover piped jobs.
	"["*"] "?" "[0-9]*$'\n'*" "[0-9]*$'\n'*" ${gji_pid} "*|\
	"["*"] "?" "[0-9]*$'\n'*" ${gji_pid} "*|\
	"["*"] "?" ${gji_pid} "*)
		;;
	"")
		setvar "${gji_var_return}" "" || return
		return "${ret}"
		;;
	*)
		err "${EX_SOFTWARE}" "get_job_id: Failed to parse jobs -l output for pid ${gji_pid}: $(echo "${gji_output}" | cat -vet)"
		;;
	esac
	gji_jobid="${gji_output#"["}"
	gji_jobid="${gji_jobid%%"]"*}"
	setvar "${gji_var_return}" "${gji_jobid}"
}

spawn_job() {
	local -

	set -m
	spawn_jobid=
	spawn "$@" || return
	get_job_id "$!" spawn_jobid
}

spawn_job_protected() {
	spawn_job "$@" || return
	madvise_protect "-$!" || return
}

_spawn_wrapper() {
	case $- in
	*m*)	# Job control
		# Don't stop processes if they try using TTY.
		trap '' SIGTTIN
		trap '' SIGTTOU
		;;
	*)	# No job control
		# Reset SIGINT to the default to undo POSIX's SIG_IGN in
		# 2.11 "Signals and Error Handling". This will ensure no
		# foreground process is left around on SIGINT.
		case "${SUPPRESS_INT:-0}" in
		0)
			trap - INT
			;;
		esac
		;;
	esac

	"$@"
}

# Note that 'spawn foo < $fifo' will block but 'foo < $fifo &' will not.
spawn() {
	_spawn_wrapper "$@" &
}

spawn_protected() {
	spawn "$@"
	madvise_protect $! || :
}

_coprocess_wrapper() {
	setproctitle "$1"
	"$@"
}

# Start a background process from function 'name'.
coprocess_start() {
	[ "$#" -eq 1 ] || eargs coprocess_start name
	local name="$1"
	local main pid jobid

	main="${name}_main"
	spawn_job_protected _coprocess_wrapper "${main}"
	pid=$!
	jobid="${spawn_jobid}"

	hash_set coprocess_pid "${name}" "${pid}"
	hash_set coprocess_jobid "${name}" "${jobid}"

	return 0
}

coprocess_stop() {
	[ "$#" -eq 1 ] || eargs coprocess_stop name
	local name="$1"
	local ret pid jobid

	hash_remove coprocess_pid "${name}" pid || return 0
	hash_remove coprocess_jobid "${name}" jobid || return 0

	ret=0
	kill_job 60 "%${jobid}" || ret="$?"
	case "${ret}" in
	143) ret=0 ;;
	esac
	return "${ret}"
}

raise() {
	local sig="$1"

	kill -"${sig}" "$(getpid)"
}

sig_handler() {
	# Avoid set -x output until we ensure proper stderr.
	{
		unset IFS
		set +e +u
		trap '' PIPE INT INFO HUP TERM
		case "${SHFLAGS-$-}${SETX_EXIT:-0}" in
		*x*1) ;;
		*) local -; set +x ;;
		esac
		redirect_to_real_tty exec
	} 2>/dev/null

	local sig="$1"
	local exit_handler="$2"

	trap - EXIT
	case "${USE_DEBUG:-no}.$$" in
	yes.*|"no.$(getpid)")
		msg "[$(getpid)${PROC_TITLE:+:${PROC_TITLE}}] Signal ${sig} caught" >&2
		;;
	esac
	# return ignored since we will exit on signal
	"${exit_handler}" || :
	trap - "${sig}"
	raise "${sig}"
}

# Take "return" value from real exit handler and exit with it.
exit_return() {
	# Avoid set -x output until we ensure proper stderr.
	{
		local ret="$?"
		unset IFS
		set +e +u
		trap '' PIPE INT INFO HUP TERM
		case "${SHFLAGS-$-}${SETX_EXIT:-0}" in
		*x*1) ;;
		*) local -; set +x ;;
		esac
		redirect_to_real_tty exec
	} 2>/dev/null

	# Ensure the real handler sees the real status
	(exit "${ret}")
	"$@" || ret="$?"
	exit "${ret}"
}

setup_traps() {
	[ "$#" -eq 1 ] || eargs setup_traps exit_handler
	local exit_handler="$1"
	local sig

	for sig in INT HUP PIPE TERM; do
		# shellcheck disable=SC2064
		trap "sig_handler ${sig} ${exit_handler}" "${sig}"
	done
	# shellcheck disable=SC2064
	trap "exit_return ${exit_handler}" EXIT
}
