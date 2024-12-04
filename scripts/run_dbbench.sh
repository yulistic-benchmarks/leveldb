#! /usr/bin/sudo /bin/bash
set -xe
print_usage() {
	echo "Usage: $0 [ -t ext4|oxbow ] [ -c ] [ -j journal|ordered ]"
	echo "	-t : System type. <ext4|oxbow> (ext4 is default)"
	echo "	-c : Measure CPU utilization."
	echo "	-j : Ext4 journal mode. <journal|ordered>"
}

drop_caches() {
	sync
	sudo sh -c "echo 3 > /proc/sys/vm/drop_caches"
}

initOxbow() {
	# Runninng Daemon as background
	$SECURE_DAEMON/run.sh -b
	sleep 10
	DAEMON_PID=$(pgrep "secure_daemon")
	echo "[OXBOW_MICROBENCH] Daemon runnning PID: $DAEMON_PID"

	sudo mount -t illufs dummy $OXBOW_PREFIX
	echo "[OXBOW_MICROBENCH] mount oxbow FS\n"
	sleep 5
}

killBgOxbow() {
	# Kill Daemon
	echo "[OXBOW_MICROBENCH] Kill secure daemon($DAEMON_PID) and umount Oxbow."
	$SECURE_DAEMON/run.sh -k
	sleep 5

	# sudo kill -9 $DAEMON_PID
	# echo "[OXBOW_MICROBENCH] Exit secure daemon $DAEMON_PID"
	# sleep 5

	# sudo umount $OXBOW_PREFIX
	# echo "[OXBOW_MICROBENCH] umount oxbow FS\n"
	# sleep 5

}

restart_ox_daemon() {
	killBgOxbow
	initOxbow
}

dumpOxbowConfig() {
	if [ -e "${LIBFS}/myconf.sh" ]; then
		echo "$LIBFS/myconf.sh:" >${OUT_FILE}.fsconf
		cat $LIBFS/libfs_conf.sh >>${OUT_FILE}.fsconf
	fi

	echo "$LIBFS/libfs_conf.sh:" >>${OUT_FILE}.fsconf
	cat $LIBFS/libfs_conf.sh >>${OUT_FILE}.fsconf

	if [ -e "${SECURE_DAEMON}/myconf.sh" ]; then
		echo "$SECURE_DAEMON/myconf.sh" >>${OUT_FILE}.fsconf
		cat $SECURE_DAEMON/myconf.sh >>${OUT_FILE}.fsconf
	fi

	echo "$SECURE_DAEMON/secure_daemon_conf.sh:" >>${OUT_FILE}.fsconf
	cat $SECURE_DAEMON/secure_daemon_conf.sh >>${OUT_FILE}.fsconf

	if [ -e "${DEVFS}/myconf.sh" ]; then
		echo "$DEVFS/myconf.sh" >>${OUT_FILE}.fsconf
		cat $DEVFS/myconf.sh >>${OUT_FILE}.fsconf
	fi

	echo "$DEVFS/devfs_conf.sh:" >>${OUT_FILE}.fsconf
	cat $DEVFS/devfs_conf.sh >>${OUT_FILE}.fsconf
}


# Send remote checkpoint signal to DevFS.
checkpoint() {
	sig_nu=$(expr $(kill -l SIGRTMIN) + 1)
	cmd="sudo pkill -${sig_nu} devfs"
	ssh ${DEVICE_IP} $cmd
}

run_leveldb() {
	# The order of workloads matters. Read workloads should be after a write workload.
	for WL in fillrandom fillsync fillseq readseq readrandom readhot; do
		for ROUND in {1..1}; do
			echo "Run LevelDB: $WL"

			if [ "$WL" == "fillsync" ]; then
				num=1000000000
			else
				num=1000000
			fi

			if [ "$WL" == "readseq" ] || [ "$WL" == "readrandom" ] || [ "$WL" == "readhot" ]; then
				reuse_db="--use_existing_db=1"
			else
				reuse_db=""
			fi

			if [ "$SYSTEM" == "oxbow" ]; then
				restart_ox_daemon
				CMD="${LIBFS}/run.sh ${BENCH_LEVELDB}/build/db_bench --db=$DIR --num=${num} --histogram=1 --value_size=1024 --benchmarks=${WL} ${reuse_db} 2>&1 | tee -a ./${OUTPUT_DIR}/${WL}_${ROUND}"
				echo Command: "$CMD" | tee ./${OUTPUT_DIR}/${WL}_${ROUND}
				eval $CMD # Execute.

				# For read workloads.
				if [ "$WL" == "fillseq" ]; then
					checkpoint
				fi

			elif [ "$SYSTEM" == "ext4" ]; then
				drop_caches
				CMD="sudo $PINNING build/db_bench --db=$DIR --num=${num} --histogram=1 --value_size=1024 --benchmarks=${WL} ${reuse_db} 2>&1 | tee -a ./${OUTPUT_DIR}/${WL}_${ROUND}"
				echo Command: "$CMD" | tee ./${OUTPUT_DIR}/${WL}_${ROUND}
				eval $CMD # Execute.

			fi

			sleep 1
		done
	done
}

umountExt4() {
	sudo umount $MOUNT_PATH || true
}

###########################################################################

# Default configurations.
SYSTEM="ext4"
DIR="./tempdir"
CPU_UTIL=0
EXT4_JOURNAL_MODE="journal"


while getopts "ct:j:?h" opt; do
	case $opt in
	c)
		CPU_UTIL=1
		;;
	t)
		SYSTEM=$OPTARG
		if [ "$SYSTEM" != "ext4" ] && [ "$SYSTEM" != "oxbow" ]; then
			print_usage
			exit 2
		fi
		;;
	j)
		EXT4_JOURNAL_MODE=$OPTARG
		;;
	h | ?)
		print_usage
		exit 2
		;;
	esac
done

if [ "$SYSTEM" == "oxbow" ] && [ -z "$OXBOW_ENV_SOURCED" ]; then
	echo "Do source oxbow/set_env.sh first."
	exit
fi

OUTPUT_DIR="leveldb_results/${SYSTEM}_${EXT4_JOURNAL_MODE}"


echo "------ Configurations -------"
echo "SYSTEM     : $SYSTEM"
echo "CPU_UTIL   : $CPU_UTIL"
echo "OUTPUT_DIR : $OUTPUT_DIR"
echo "-----------------------------"

mkdir -p "$OUTPUT_DIR"

# Kill all the existing leveldb processes.
sudo pkill -9 db_bench || true

# Mount.
if [ $SYSTEM == "ext4" ]; then
	MOUNT_PATH="/mnt/ext4"
	DIR="$MOUNT_PATH/ext4_${EXT4_JOURNAL_MODE}"
	# PINNING="numactl -N1 -m1"

	# Set nvme device path.
	# DEV_PATH="/dev/nvme2n1"
	#
	# Or, get it automatically. nvme-cli is required. (sudo apt install nvme-cli)
	DEV_PATH="$(sudo nvme list | grep "SAMSUNG MZPLJ3T2HBJR-00007" | xargs | cut -d " " -f 1)"
	echo Device path: "$DEV_PATH"

	# Set total journal size.
	# TOTAL_JOURNAL_SIZE=5120 # 5 GB
	TOTAL_JOURNAL_SIZE=$((38 * 1024)) # 38 GB

	umountExt4

	sudo mke2fs -t ext4 -J size=$TOTAL_JOURNAL_SIZE -E lazy_itable_init=0,lazy_journal_init=0 -F -G 1 $DEV_PATH
	sudo mount -t ext4 -o barrier=0,data=$EXT4_JOURNAL_MODE $DEV_PATH $MOUNT_PATH
	sudo chown -R $USER:$USER $MOUNT_PATH
	mkdir -p $DIR

	# Dump config.
	sudo dumpe2fs -h $DEV_PATH > ./${OUTPUT_DIR}/fsconf

elif [ $SYSTEM == "oxbow" ]; then
	DIR="$OXBOW_PREFIX"

	# Umount if mounted.
	sudo umount $OXBOW_PREFIX || true

	# Kill all the Oxbow processes.
	$SECURE_DAEMON/run.sh -k || true
	sleep 3

	initOxbow

	sudo chown -R $USER:$USER $MOUNT_PATH
	# mkdir -p $DIRS # Use root directory.
fi

# Run leveldb bench.
run_leveldb

# Kill and unmount.
if [ $SYSTEM == "ext4" ]; then
	sudo umount $MOUNT_PATH || true

elif [ $SYSTEM == "oxbow" ]; then
	killBgOxbow
fi

# Parse results.
scripts/parse_results.sh $OUTPUT_DIR
