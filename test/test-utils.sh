# Copyright (C) 2008 Red Hat, Inc. All rights reserved.
#
# This copyrighted material is made available to anyone wishing to use,
# modify, copy, or redistribute it subject to the terms and conditions
# of the GNU General Public License v.2.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software Foundation,
# Inc., 59 Temple Place, Suite 330, Boston, MA  02111-1307  USA

aux() {
        # use just "$@" for verbose operation
	"$@" > /dev/null 2> /dev/null
	#"$@"
}

STACKTRACE() {
	trap - ERR;
	i=0;

	while FUNC=${FUNCNAME[$i]}; test "$FUNC" != "main"; do 
		echo "$i ${FUNC}() called from ${BASH_SOURCE[$i]}:${BASH_LINENO[$i]}"
		i=$(($i + 1));
	done

	# Get backtraces from coredumps
	if which gdb >& /dev/null; then
		echo bt full > gdb_commands.txt
		echo l >> gdb_commands.txt
		echo quit >> gdb_commands.txt
		for core in `ls core* 2>/dev/null`; do
			bin=$(gdb -batch -c $core 2>&1 | grep "generated by" | \
				sed -e "s,.*generated by \`\([^ ']*\).*,\1,")
			gdb -batch -c $core -x gdb_commands.txt `which $bin`
		done
	fi

	test -f debug.log && {
		sed -e "s,^,## DEBUG: ,;s,$top_srcdir/\?,," < debug.log
	}
}

init_udev_transaction() {
	if test "$DM_UDEV_SYNCHRONISATION" = 1; then
		COOKIE=$(dmsetup udevcreatecookie)
		# Cookie is not generated if udev is not running!
		if test -n "$COOKIE"; then
			export DM_UDEV_COOKIE=$COOKIE
		fi
	fi
}

finish_udev_transaction() {
	if test "$DM_UDEV_SYNCHRONISATION" = 1 -a -n "$DM_UDEV_COOKIE"; then
		dmsetup udevreleasecookie
		unset DM_UDEV_COOKIE
	fi
}

prepare_clvmd() {
	if test -z "$LVM_TEST_LOCKING" || test "$LVM_TEST_LOCKING" -ne 3 ; then
		return 0 # not needed
	fi

	if pgrep clvmd ; then
		echo "Cannot use fake cluster locking with real clvmd ($(pgrep clvmd)) running."
		exit 200
	fi

	# skip if we don't have our own clvmd...
	(which clvmd | grep $abs_builddir) || exit 200

	# skip if we singlenode is not compiled in
	(clvmd --help 2>&1 | grep "Available cluster managers" | grep singlenode) || exit 200

	trap_teardown

	clvmd -Isinglenode -d 1 &
	LOCAL_CLVMD="$!"
}

prepare_dmeventd() {
	if pgrep dmeventd ; then
		echo "Cannot test dmeventd with real dmeventd ($(pgrep dmeventd)) running."
		exit 200
	fi

	# skip if we don't have our own dmeventd...
	(which dmeventd | grep $abs_builddir) || exit 200

	trap_teardown

	dmeventd -f &
	LOCAL_DMEVENTD="$!"
}

prepare_testroot() {
	OLDPWD="`pwd`"
	PREFIX="LVMTEST$$"

	trap_teardown
	TESTDIR=$($abs_srcdir/mkdtemp ${LVM_TEST_DIR-$(pwd)} $PREFIX.XXXXXXXXXX) \
		|| { echo "failed to create temporary directory in ${LVM_TEST_DIR-$(pwd)}"; exit 1; }

	export LVM_SYSTEM_DIR=$TESTDIR/etc
	export DM_DEV_DIR=$TESTDIR/dev
	mkdir $LVM_SYSTEM_DIR $DM_DEV_DIR $DM_DEV_DIR/mapper $TESTDIR/lib

	cd $TESTDIR

	for i in `find $abs_top_builddir/daemons/dmeventd/plugins/ -name \*.so`; do
		echo Setting up symlink from $i to $TESTDIR/lib
		ln -s $i $TESTDIR/lib
	done
}

teardown_devs() {
	test -n "$PREFIX" && {
		rm -rf $TESTDIR/dev/$PREFIX*

		init_udev_transaction
		while dmsetup table | grep -q ^$PREFIX; do
			for s in `dmsetup info -c -o name --noheading | grep ^$PREFIX`; do
				dmsetup remove $s >& /dev/null || true
			done
		done
		finish_udev_transaction

	}

	# NOTE: SCSI_DEBUG_DEV test must come before the LOOP test because
	# prepare_scsi_debug_dev() also sets LOOP to short-circuit prepare_loop()
	if [ -n "$SCSI_DEBUG_DEV" ] ; then
		modprobe -r scsi_debug
	else
		test -n "$LOOP" && losetup -d $LOOP
		test -n "$LOOPFILE" && rm -f $LOOPFILE
	fi
	unset devs # devs is set in prepare_devs()
	unset LOOP
}

teardown() {
	echo $LOOP
	echo $PREFIX

	test -n "$LOCAL_CLVMD" && {
		kill "$LOCAL_CLVMD"
		sleep .1
		kill -9 "$LOCAL_CLVMD" || true
	}

	test -n "$LOCAL_DMEVENTD" && kill -9 "$LOCAL_DMEVENTD"

	teardown_devs

	test -n "$TESTDIR" && {
		cd $OLDPWD
		rm -rf $TESTDIR || echo BLA
	}
}

trap_teardown() {
	trap 'set +vx; STACKTRACE; set -vx' ERR
	trap 'aux teardown' EXIT # don't forget to clean up
}

make_ioerror() {
	echo 0 10000000 error | dmsetup create ioerror
	ln -s $DM_DEV_DIR/mapper/ioerror $DM_DEV_DIR/ioerror
}

prepare_loop() {
	size=$1
	test -n "$size" || size=32

	# skip if prepare_scsi_debug_dev() was used
	if [ -n "$SCSI_DEBUG_DEV" -a -n "$LOOP" ]; then
		return 0
	fi

	test -z "$LOOP"
	test -n "$DM_DEV_DIR"

	trap_teardown

	for i in 0 1 2 3 4 5 6 7; do
		test -e $DM_DEV_DIR/loop$i || mknod $DM_DEV_DIR/loop$i b 7 $i
	done

	LOOPFILE="$PWD/test.img"
	dd if=/dev/zero of="$LOOPFILE" bs=$((1024*1024)) count=0 seek=$(($size-1))
	if LOOP=`losetup -s -f "$LOOPFILE" 2>/dev/null`; then
		return 0
	elif LOOP=`losetup -f` && losetup $LOOP "$LOOPFILE"; then
		# no -s support
		return 0
	else
		# no -f support 
		# Iterate through $DM_DEV_DIR/loop{,/}{0,1,2,3,4,5,6,7}
		for slash in '' /; do
			for i in 0 1 2 3 4 5 6 7; do
				local dev=$DM_DEV_DIR/loop$slash$i
				! losetup $dev >/dev/null 2>&1 || continue
				# got a free
				losetup "$dev" "$LOOPFILE"
				LOOP=$dev
				break
			done
			if [ -n "$LOOP" ]; then 
				break
			fi
		done
		test -n "$LOOP" # confirm or fail
		return 0
	fi
	exit 1 # should not happen
}

# A drop-in replacement for prepare_loop() that uses scsi_debug to create
# a ramdisk-based SCSI device upon which all LVM devices will be created
# - scripts must take care not to use a DEV_SIZE that will enduce OOM-killer
prepare_scsi_debug_dev()
{
    local DEV_SIZE="$1"
    shift
    local SCSI_DEBUG_PARAMS="$@"

    test -n "$SCSI_DEBUG_DEV" && return 0
    test -z "$LOOP"
    test -n "$DM_DEV_DIR"

    trap_teardown

    # Skip test if awk isn't available (required for get_sd_devs_)
    which awk || exit 200

    # Skip test if scsi_debug module is unavailable or is already in use
    modprobe --dry-run scsi_debug || exit 200
    lsmod | grep -q scsi_debug && exit 200

    # Create the scsi_debug device and determine the new scsi device's name
    # NOTE: it will _never_ make sense to pass num_tgts param;
    # last param wins.. so num_tgts=1 is imposed
    modprobe scsi_debug dev_size_mb=$DEV_SIZE $SCSI_DEBUG_PARAMS num_tgts=1 || exit 200
    sleep 2 # allow for async Linux SCSI device registration

    local DEBUG_DEV=/dev/$(grep scsi_debug /sys/block/*/device/model | cut -f4 -d /)
    [ -b $DEBUG_DEV ] || exit 1 # should not happen

    # Create symlink to scsi_debug device in $DM_DEV_DIR
    SCSI_DEBUG_DEV=$DM_DEV_DIR/$(basename $DEBUG_DEV)
    # Setting $LOOP provides means for prepare_devs() override
    LOOP=$SCSI_DEBUG_DEV
    ln -snf $DEBUG_DEV $SCSI_DEBUG_DEV
    return 0
}

cleanup_scsi_debug_dev()
{
    aux teardown_devs
    unset SCSI_DEBUG_DEV
    unset LOOP
}

prepare_devs() {
	local n="$1"
	test -z "$n" && n=3
	local devsize="$2"
	test -z "$devsize" && devsize=34
	local pvname="$3"
	test -z "$pvname" && pvname="pv"

	prepare_loop $(($n*$devsize))

	if ! loopsz=`blockdev --getsz $LOOP 2>/dev/null`; then
  		loopsz=`blockdev --getsize $LOOP 2>/dev/null`
	fi

	local size=$(($loopsz/$n))

	init_udev_transaction
	for i in `seq 1 $n`; do
		local name="${PREFIX}$pvname$i"
		local dev="$DM_DEV_DIR/mapper/$name"
		eval "dev$i=$dev"
		devs="$devs $dev"
		echo 0 $size linear $LOOP $((($i-1)*$size)) > $name.table
		dmsetup create $name $name.table
	done
	finish_udev_transaction

	for i in `seq 1 $n`; do
		local name="${PREFIX}$pvname$i"
		dmsetup info -c $name
	done
	for i in `seq 1 $n`; do
		local name="${PREFIX}$pvname$i"
		dmsetup table $name
	done
}

disable_dev() {

	init_udev_transaction
	for dev in "$@"; do
        # first we make the device inaccessible
		echo 0 10000000 error | dmsetup load $dev
		dmsetup resume $dev
        # now let's try to get rid of it if it's unused
        #dmsetup remove $dev
	done
	finish_udev_transaction

}

enable_dev() {

	init_udev_transaction
	for dev in "$@"; do
		local name=`echo "$dev" | sed -e 's,.*/,,'`
		dmsetup create $name $name.table || dmsetup load $name $name.table
		dmsetup resume $dev
	done
	finish_udev_transaction
}

backup_dev() {
	for dev in "$@"; do
		dd if=$dev of=$dev.backup bs=1024
	done
}

restore_dev() {
	for dev in "$@"; do
		test -e $dev.backup || {
			echo "Internal error: $dev not backed up, can't restore!"
			exit 1
		}
		dd of=$dev if=$dev.backup bs=1024
	done
}

prepare_pvs() {
	prepare_devs "$@"
	pvcreate -ff $devs
}

prepare_vg() {
	vgremove -ff $vg || true
	teardown_devs

	prepare_pvs "$@"
	vgcreate -c n $vg $devs
	pvs -v
}

prepare_lvmconf() {
	local filter="$1"
	test -z "$filter" && \
		filter='[ "a/dev\/mirror/", "a/dev\/mapper\/.*pv[0-9_]*$/", "r/.*/" ]'
        locktype=
	if test -n "$LVM_TEST_LOCKING"; then locktype="locking_type = $LVM_TEST_LOCKING"; fi
	cat > $TESTDIR/etc/lvm.conf.new <<-EOF
  $LVM_TEST_CONFIG
  devices {
    dir = "$DM_DEV_DIR"
    scan = "$DM_DEV_DIR"
    filter = $filter
    cache_dir = "$TESTDIR/etc"
    sysfs_scan = 0
    default_data_alignment = 1
    $LVM_TEST_CONFIG_DEVICES
  }
  log {
    syslog = 0
    indent = 1
    level = 9
    file = "$TESTDIR/debug.log"
    overwrite = 1
    activation = 1
  }
  backup {
    backup = 0
    archive = 0
  }
  global {
    abort_on_internal_errors = 1
    library_dir = "$TESTDIR/lib"
    locking_dir = "$TESTDIR/var/lock/lvm"
    $locktype
    si_unit_consistency = 1
  }
  activation {
    udev_sync = 1
    udev_rules = 1
    polling_interval = 0
    snapshot_autoextend_percent = 50
    snapshot_autoextend_threshold = 50
  }
EOF
	# FIXME remove this workaround after mmap & truncating file problems solved
	mv -f $TESTDIR/etc/lvm.conf.new $TESTDIR/etc/lvm.conf
	cat $TESTDIR/etc/lvm.conf
}

prepare() {
	ulimit -c unlimited
	# FIXME any way to set this just for our children?
	# echo 1 > /proc/sys/kernel/core_uses_pid
	prepare_testroot
	prepare_lvmconf
	prepare_clvmd

	# set up some default names
	vg=${PREFIX}vg
	vg1=${PREFIX}vg1
	vg2=${PREFIX}vg2
	lv=LV
	lv1=LV1
	lv2=LV2
	lv3=LV3
	lv4=LV4
}

LANG=C
LC_ALL=C
TZ=UTC
unset CDPATH

. ./init.sh || { echo >&2 you must run make first; exit 1; }
. ./lvm-utils.sh

set -vexE -o pipefail
aux prepare
