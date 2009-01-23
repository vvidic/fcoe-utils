#! /bin/bash
#
# Copyright(c) 2009 Intel Corporation. All rights reserved.
#
# This program is free software; you can redistribute it and/or modify it
# under the terms and conditions of the GNU General Public License,
# version 2, as published by the Free Software Foundation.
#
# This program is distributed in the hope it will be useful, but WITHOUT
# ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
# FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
# more details.
#
# You should have received a copy of the GNU General Public License along with
# this program; if not, write to the Free Software Foundation, Inc.,
# 51 Franklin St - Fifth Floor, Boston, MA 02110-1301 USA.
#
# Maintained at www.Open-FCoE.org

cmdname=`basename $0`

usage()
{
	echo usage: $cmdname \
		'<ethX> [--reset | --enable | --disable]' \
		'[--qos <pri>[,<pri>]...]]' >&2
	exit 1
}

#
# Tunable parameters
#
QOS_DEF=3			# default user priority
FCOE_ETHERTYPE=35078		# Ethertype (0x8906): tc filter show is base 10
FCOE_FILTER=0xfc0e		# filter handle (must be lower-case hex)
qdisc_id=1:
qos_list=
FILTER_ID=
cmd=
#
TC_CMD="/usr/sbin/tc"		# /sbin/tc or debug command
FCOEADM=/sbin/fcoeadm		# command to create/destroy FCoE instances
LOGGER="logger -s -t fcoeplumb"
CONFIG_DIR=/etc/fcoe

. $CONFIG_DIR/config
if [ "$USE_SYSLOG" != "yes" ] && [ "$USE_SYSLOG" != "YES" ]; then
	LOGGER="echo"
else
	USE_SYSLOG="yes"
fi
[ "$DEBUG" = "yes" ] || [ "$DEBUG" = "YES" ] && DEBUG="yes"

find_multiq_qdisc()
{
	ifname=$1

	found=0
	type=unknown
	if set -- `$TC_CMD qdisc show dev $ifname` none none none
	then
		type=$2
		qdisc_id=$3
	fi
	[ "$type" == "multiq" ] && found=1

	return $found
}

add_multiq_qdisc()
{
	ifname=$1
	qdisc_id=$2

	[ "$DEBUG" = "yes" ] && $LOGGER \
		"$TC_CMD qdisc add dev $ifname root handle $qdisc_id multiq"
	$TC_CMD qdisc add dev $ifname root handle $qdisc_id multiq
}

delete_qdisc()
{
	ifname=$1

	[ "$DEBUG" = "yes" ] && $LOGGER \
		"$TC_CMD qdisc del dev $ifname root"
	$TC_CMD qdisc del dev $ifname root
}

get_filter_id()
{
	ifname=$1

	retry_count=0
	while true
	do
		[ $retry_count -eq 0 ] && break
		[ -f /var/run/fcoemon.pid ] && break
		sleep 1
		retry_count=$(($retry_count-1))
	done

	FILTER_ID=`echo "$ifname 12345" | \
		awk '{ printf("0x%x%06x", substr($1,4), $2) }'`
}

find_skbedit_filter()
{
	ifname=$1

	found=`$TC_CMD filter show dev $ifname | awk '
	BEGIN {
		x1 = 0
		x2 = 0
		x3 = 0
		queue = 8
	}
	/^filter.*parent.*protocol 802_3.* handle '$FILTER_ID'/ {
		if (x1 == 0 && x2 == 0 && x3 == 0)
			x1 = 1
	}
	/cmp.*u16 at 12 layer 1 mask 0xffff eq '$FCOE_ETHERTYPE'.*\)/ {
		if (x1 == 1 && x2 == 0 && x3 == 0)
			x2 = 1
	}
	/action order [0-9][0-9]*:  skbedit queue_mapping/ {
		if (x1 == 1 && x2 == 1 && x3 == 0) {
			x3 = 1
			queue = $6
		}
	}
	END {
		print queue
	}'`

	return $found
}

delete_skbedit_filter()
{
	ifname=$1
	queue=$?

	[ "$DEBUG" = "yes" ] && $LOGGER \
		"$TC_CMD filter delete dev $ifname skbedit queue_mapping $queue"
	PARENT=`$TC_CMD filter show dev $ifname | awk \
		'/^filter.*parent.*protocol 802_3.* handle '$FILTER_ID'/ \
		{ print $3 }'`
	PRIO=`$TC_CMD filter show dev $ifname | awk \
		'/^filter.*parent.*protocol 802_3.* handle '$FILTER_ID'/ \
		{ print $7 }'`
	$TC_CMD filter delete dev $ifname parent $PARENT \
		protocol 802_3 pref $PRIO handle $FILTER_ID basic match \
		'cmp(u16' at 12 layer 1 mask 0xffff eq $FCOE_ETHERTYPE')' \
		action skbedit queue_mapping $queue
	$TC_CMD filter delete dev $ifname parent $PARENT \
		protocol 802_3 pref $PRIO basic
}

add_skbedit_filter()
{
	ifname=$1
	qdisc_id=$2
	queue=$3

	[ "$DEBUG" = "yes" ] && $LOGGER \
		"$TC_CMD filter add dev $ifname skbedit queue_mapping $queue"
	$TC_CMD filter add dev $ifname parent $qdisc_id protocol 802_3 \
		handle $FILTER_ID basic match 'cmp(u16' at 12 \
		layer 1 mask 0xffff eq $FCOE_ETHERTYPE')' \
		action skbedit queue_mapping $queue
}

replace_skbedit_filter()
{
	ifname=$1
	queue=$2

	[ "$DEBUG" = "yes" ] && $LOGGER \
		"$TC_CMD filter replace dev $ifname skbedit queue_mapping $queue"
	PARENT=`$TC_CMD filter show dev $ifname | awk \
		'/^filter.*parent.*protocol 802_3.* handle '$FILTER_ID'/ \
		{ print $3 }'`
	PRIO=`$TC_CMD filter show dev $ifname | \
		awk '/^filter.*parent.*protocol 802_3.* handle '$FILTER_ID'/ \
		{ print $7 }'`
	$TC_CMD filter replace dev $ifname parent $PARENT protocol \
		802_3 pref $PRIO handle $FILTER_ID basic match \
		'cmp(u16' at 12 layer 1 mask 0xffff eq $FCOE_ETHERTYPE')' \
		action skbedit queue_mapping $queue
}

remove_fcoe_interface()
{
	ifname=$1

	STATUS=`$FCOEADM -i $ifname 2>&1 | \
		awk '/Interface Name:/{print $3}'`
	if [ "$STATUS" = "$ifname" ]; then
		[ "$DEBUG" = "yes" ] && $LOGGER "$FCOEADM -d $ifname"
		$FCOEADM -d $ifname
	else
		[ "$DEBUG" = "yes" ] && $LOGGER \
			"FCoE interface $ifname doesn't exist"
	fi
}

create_fcoe_interface()
{
	ifname=$1

	STATUS=`$FCOEADM -i $ifname 2>&1 | \
		awk '/Interface Name:/{print $3}'`
	if [ -z "$STATUS" ]; then
		[ "$DEBUG" = "yes" ] && $LOGGER "$FCOEADM -c $ifname"
		$FCOEADM -c $ifname
	else
		[ "$DEBUG" = "yes" ] && $LOGGER \
			"FCoE interface $ifname already created"
	fi
}

[ "$#" -lt 1 ] && usage

[ "$DEBUG" = "yes" ] && $LOGGER "fcoeplumb arguments: ($*)"

ifname=$1
shift

while [ "$#" -ge 1 ]
do
	case "$1" in
	--reset | -r)
		cmd=reset
		;;
	--enable | -e)
		cmd=enable
		;;
	--disable | -d)
		cmd=disable
		;;
	--debug)
		LOGGER="logger -t fcoeplumb -s"
		;;
	--qos | -q)
		[ "$#" -lt 2 ] && usage
		qos_list=$2
		shift
		;;
	*)
		echo "$cmdname: unknown parameter '$1'" >&2
		usage
		;;
	esac
	shift
done

# This must be the first to do after parsing the command arguments!
# Notice that the FILTER_ID is used in find_skbedit_filter(),
# add_skbedit_filter(), replace_skbedit_filter().
get_filter_id $ifname

if [ "$cmd" == "disable" ]; then
	remove_fcoe_interface $ifname
	find_skbedit_filter $ifname
	found_filter=$?
	[ $found_filter -le 7 ] && delete_skbedit_filter $ifname $found_filter
else
	#
	# Choose the best QOS to use for FCoE out of the listed choices.
	#

	# Parse QOS List
	QOS_BEST=
	if [ -n "$qos_list" ]; then
		OLD_IFS="$IFS"
		IFS=,"$IFS"
		set -- $qos_list
		IFS="$OLD_IFS"

		while [ "$#" -ge 1 ]
		do
			case "$1" in
			[0-7])
				;;
			*)
				echo "$cmdname: bad QOS value '$1'" >&2
				usage
				;;
			esac
			if [ -z "$QOS_BEST" ]; then
				QOS_BEST=$1
			elif [ "$1" -eq "$QOS_DEF" ]; then
				QOS_BEST=$1
			fi
			shift
		done
	fi

	[ "$DEBUG" = "yes" ] && $LOGGER "$ifname - Choosing QOS '$QOS_BEST'"

	# If the best QOS is not found, do nothing.
	[ -z "$QOS_BEST" ] && exit 0

	#
	# Setup the traffic classifier for FCoE
	# First see if it is already set up.
	#
	qos_queue=`expr $QOS_BEST`

	find_multiq_qdisc $ifname
	found_qdisc=$?

	if [ $found_qdisc -eq 1 ]; then
		[ "$DEBUG" = "yes" ] && $LOGGER "$ifname: Qdisc is found"
		find_skbedit_filter $ifname
		found_filter=$?
		if [ $found_filter -gt 7 ]; then
			[ "$DEBUG" = "yes" ] && $LOGGER \
				"$ifname: Filter is not found"
			add_skbedit_filter $ifname $qdisc_id $qos_queue
		elif [ $found_filter -ne $qos_queue ]; then
			[ "$DEBUG" = "yes" ] && $LOGGER \
				"$ifname: Filter is found and QOS is different"
			replace_skbedit_filter $ifname $qos_queue
		else
			[ "$DEBUG" = "yes" ] && $LOGGER \
				"$ifname: Filter is found and is identical"
		fi
	else
		[ "$DEBUG" = "yes" ] && $LOGGER "$ifname: Qdisc is not found"
		add_multiq_qdisc $ifname $qdisc_id
		add_skbedit_filter $ifname $qdisc_id $qos_queue
		delete_qdisc $ifname
		add_multiq_qdisc $ifname $qdisc_id
		add_skbedit_filter $ifname $qdisc_id $qos_queue
	fi

	if [ "$cmd" = "enable" ]; then
		create_fcoe_interface $ifname
	fi
fi

[ "$DEBUG" = "yes" ] && $LOGGER "$ifname: Leaving"
exit 0
