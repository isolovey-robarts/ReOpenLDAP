#!/bin/bash

TOP=$(pwd)/@ci-buzz.pool
RAM=$TOP/ramfs
MAINPID=$$

function timestamp {
	date +'%F %T'
}

function cleanup {
	if [ $BASHPID = $MAINPID ]; then
		echo "Running cleanup:"
		for ((n=0; n < N; n++)); do
			for branch in $branch_list; do
				dir=$TOP/@$n.$branch
				pid=$([ -s $TOP/@$n.$branch/pid ] && cat $TOP/@$n.$branch/pid)
				if [ -n "$pid" ]; then
					echo "Terminating pid $pid ($n of $branch)..."
					pkill -P $pid && wait $pid 2>/dev/null
				fi
			done
		done
	else
		echo "Skip cleanup for non-main pid $BASHPID"
	fi

	pkill -P $BASHPID && sleep 1
	pkill -9 -P $BASHPID
}

trap cleanup TERM INT QUIT HUP

function failure {
	echo "Oops, $* failed ;(" >&2
	cleanup
	exit 1
}

flag_mode_tls=0
while grep -q '^--' <<< "$1"; do
	case "$1" in
	--check-tls)
		flag_mode_tls=1
		;;
	*)
		failure "unknown option '$1'"
		;;
	esac
	shift
done

N=$1
shift
branch_list="$@"

if [ -z "$N" ]; then N=10; fi
if [ -z "$branch_list" ]; then branch_list="devel master"; fi

build="build/ci/build.sh"
test="build/ci/test.sh"
build_args="--without-bdb --do-not-clean --insrc"
test_args="42"

mkdir -p $TOP || failure "mkdir -p $TOP"
rm -rf $TOP/@* || failure  "rm -rf $TOP/@*"
[ ! -d $RAM ] || rm -rf $RAM/* || failure "$RAM/*"

function waitloop {
	while sleep 15; do
		clear
		/usr/bin/printf "=== $1: %s, running %.2f hours, %d job(s) left\n" \
			 "$(timestamp)" "$((($(date +%s)-started)/36)).0E-02" $(jobs -r | wc -l)
		for branch in $branch_list; do
			for ((n=0; n < N; n++)); do
				dir="$TOP/@$n.$branch"
				echo "$branch/$n: $(tail -n 1 $dir/status) | $(tail -n 1 $dir/err.log)"
			done
		done

		echo "==="
		df -h $TOP $TOP/ramfs
		echo "==="
		vmstat -w; vmstat -w -a
		echo "==="
		uptime

		if [ -z "$(jobs -r)" ]; then
			return 0
		fi
	done
	exit 1
}

function doit_build {
	local branch=$1
	local nice=$2
	shift 2
	local build_opt=$@
	local here=$(pwd)
	export CIBUZZ_STATUS=$here/status CIBUZZ_PID4=$here/pid
	rm -f $here/build.ok $here/build.failed
	echo $BASHPID > $CIBUZZ_PID4
	echo "branch $branch | $build_opt"
	echo "==============================================================================="
	echo "$(timestamp) Preparing..." >$CIBUZZ_STATUS
	echo $BASHPID > $CIBUZZ_PID4
	local root=$(git rev-parse --show-toplevel)
	([ -d src/.git ] || (rm -rf src && git clone --local --share -b $branch $root src)) \
		&& cd src || failure git-clone
	echo "==============================================================================="
	echo "$(timestamp) Building..." > $CIBUZZ_STATUS
	if nice -n $nice $build $build_args $build_opt; then
		touch $here/build.ok
		echo "build done" >> $here/err.log
		exit 0
	else
		touch $here/build.failed
		failure "$here/$build $build_args $build_opt"
	fi
}

function make_build_opt {
	if [ $flag_mode_tls -ne 0 ]; then
		build_opt="--lto --asan --no-dynamic"
		if [ $n -lt 4 ]; then
			build_opt+=" --speed"
		else
			build_opt+=" --size --check"
		fi
		case $((n % 4)) in
			0)
				build_opt+=" --with-tls=no"
				;;
			1)
				build_opt+=" --with-tls=moznss"
				;;
			2)
				build_opt+=" --with-tls=gnutls"
				;;
			3)
				build_opt+=" --with-tls=openssl"
				;;
			*)
				failure "Oops"
				;;
		esac
	else
		case $((n % 4)) in
			0)
				build_opt="--no-lto --asan --slapi --contrib --exper"
				;;
			1)
				build_opt="--no-lto --debug --slapi --contrib --exper"
				;;
			2)
				build_opt="--size --no-check --lto"
				;;
			3)
				build_opt="--speed --check --lto"
				;;
			*)
				failure "Oops"
				;;
		esac
		if [ $n -lt 4 ]; then
			build_opt+=" --dynamic"
		else
			# LY: avoid timeout-failures due libtool runtime linking under higload
			build_opt+=" --no-dynamic"
		fi
	fi
}

function doit_test {
	local branch=$1
	local nice=$2
	local here=$(pwd)
	rm -f $here/test.ok $here/test.failed
	if [ -e $here/build.ok ]; then
		export CIBUZZ_STATUS=$here/status CIBUZZ_PID4=$here/pid
		echo $BASHPID > $CIBUZZ_PID4
		echo "==============================================================================="
		echo "$(timestamp) Testing..." > $CIBUZZ_STATUS
		(cd src && NO_COLLECT_SUCCESS=yes TEST_TEMP_DIR=$(readlink -f ${here}/tmp) \
			setsid -w nice -n $nice $test $test_args) \
		&& touch $here/test.ok || touch $here/test.failed
	fi
	exit 0
}

(mount | grep ${RAM} \
	|| (mkdir -p ${RAM} && sudo mount -t tmpfs RAM ${RAM})) \
	|| failure "mount ${RAM}"

started=$(date +%s)
order=0
for ((n=0; n < N; n++)); do
	for branch in $branch_list; do
		delay=$((order * 113))
		make_build_opt
		echo "launching $n of $branch with $build_opt"
		dir=$TOP/@$n.$branch
		tmp=$(readlink -f ${RAM}/$n.$branch)
		mkdir -p $dir || failure "mkdir -p $dir"

		echo "delay $delay seconds, nice $nice... $build_opt" >$dir/status
		rm -rf $tmp $dir/tmp && mkdir -p $tmp && ln -s $tmp $dir/tmp || failure "mkdir -p $tmp"
		( \
			( sleep $delay && cd $dir \
				&& doit_build $branch 15 $build_opt \
			) >$dir/out.log 2>$dir/err.log </dev/null; \
			wait; echo "$(timestamp) *** fihished" >$dir/status \
		) &
		((order++))
	done
done

waitloop "building"

started=$(date +%s)
order=0
for ((n=0; n < N; n++)); do
	for branch in $branch_list; do
		dir=$TOP/@$n.$branch
		[ -e $dir/build.ok ] || continue

		delay=$((order * 17))
		nice=$((n % 4 + 1))
		make_build_opt

		echo "launching $n of $branch, with nice $nice and with $build_opt"
		tmp=$(readlink -f ${RAM}/$n.$branch)
		mkdir -p $dir || failure "mkdir -p $dir"

		echo "delay $delay seconds, nice $nice and with $build_opt..." >$dir/status
		rm -rf $tmp $dir/tmp && mkdir -p $tmp && ln -s $tmp $dir/tmp || failure "mkdir -p $tmp"
		( \
			( sleep $delay && cd $dir \
				&& doit_test $branch $nice \
			) >$dir/out.log 2>$dir/err.log </dev/null; \
			wait; echo "$(timestamp) *** exited" >$dir/status \
		) &
		((order++))
	done
done

waitloop "testing"
exit 0
