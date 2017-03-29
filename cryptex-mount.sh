#!/bin/bash

# Copyright (c) 2017 Chris Kuethe <chris.kuethe@gmail.com>
#
# Permission to use, copy, modify, and distribute this software for any
# purpose with or without fee is hereby granted, provided that the above
# copyright notice and this permission notice appear in all copies.
#
# THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL WARRANTIES
# WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED WARRANTIES OF
# MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL THE AUTHOR BE LIABLE FOR
# ANY SPECIAL, DIRECT, INDIRECT, OR CONSEQUENTIAL DAMAGES OR ANY DAMAGES
# WHATSOEVER RESULTING FROM LOSS OF USE, DATA OR PROFITS, WHETHER IN AN
# ACTION OF CONTRACT, NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF
# OR IN CONNECTION WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.

export PATH=/bin:/sbin:/usr/bin:/usr/sbin

#set -x	# debug tracing
set -e	# abort script if any command fails

if [ \( $# -lt 1 \) -o \( $# -gt 2 \) -o \( "x$1" == "x-h" \) -o \( "x$2" == "x-h" \) ] ; then
	echo "Usage: $0 [</path/to/blockdev>] </path/to/cryptex/mountpoint>"
	exit 1
fi

# Unconditionally run this through sudo so that we can grab the caller's
# userid, username, keychains, etc. These are used after the key has been
# loaded into the kernel to transfer ownership of the key, and thus access
# to the volume, to the caller of the script. Standard POSIX permissions
# still apply to the decrypted filesystem.

if [ -z "$SUDO_USER" ] ; then
	CRYPTEX_USER_KR=$(keyctl show -x | grep "keyring: _uid.$(id -u)" | cut -d ' ' -f 1)
	exec sudo CRYPTEX_USER_KR="$CRYPTEX_USER_KR" bash $0 "$@"
fi

# required for mounting filesystems and toggling ext4 feature bits
if [ $(id -u) -ne 0 ] ; then
	echo unable to get root privilege
	exit 1
fi

# Mount the device if necessary
if [ $# -eq 1 ] ; then
	MNT=$(realpath $1)
	DEV=$(egrep "$(realpath $MNT)\s*ext4" /proc/mounts | cut -f 1 -d ' ')
	if [ -z "$DEV" ] ; then
		echo "can't find device for mountpoint $DEV"
		exit 1
	fi
else
	DEV=$1
	MNT=$2
	mount -t ext4 $DEV $MNT
fi

#NL=$(egrep "EXT4_(FS_)?ENCRYPTION=y" "/boot/config-$(uname -r)" | wc -l)
#if [ "$NL" -ne "2" ] ; then
#	echo encryption not found in kernel config
#	exit 1
#fi

# EXT4 encryption requires filesystem block size to match system page size
BSIZE=$(tune2fs -l $DEV | grep "Block size" | sed -e 's/.*: *//')
PSIZE=$(getconf PAGE_SIZE)
if [ "x$BSIZE" != "x$PSIZE" ] ; then
	echo "blocksize ($BSIZE) != PAGE_SIZE ($PSIZE)"
	exit 1
fi

# Enable the EXT4 encryption feature
ENC_ON=$(tune2fs -l $DEV  | grep  "Filesystem features:.*encrypt" | wc -l)
if [ $ENC_ON -eq 0 ] ; then
	# echo enabling encryption in superblock
	tune2fs -O encrypt $DEV >/dev/null
fi

NEED_INIT=$(e4crypt get_policy "$MNT" | grep "Error getting policy for" | wc -l)
if [ $NEED_INIT -eq 1 ] ; then
	SALT="-S 0x$(head -c 16 /dev/urandom | xxd -p)"
fi
e4crypt add_key $SALT "$MNT"

# Complicated key management dance to hand over control of the key to the
# calling user

VOL_KEY=$(e4crypt get_policy "$MNT" | awk '/: [[:xdigit:]]{16}$/{print $2}')
KEY_DESCR=$(keyctl show | awk "/ext4:$VOL_KEY/"'{print $1}' | sort -u)

# link key into root's user keychain so it isn't lost when this script exits
keyctl link $KEY_DESCR @u

# give full control to owner ; view+read+search+link to possessor and group
keyctl setperm $KEY_DESCR "0x1b3f1b00"

# set uid of the key to the calling user
keyctl chgrp $KEY_DESCR $SUDO_GID

# link it into the caller's user keychain.
keyctl link $KEY_DESCR $CRYPTEX_USER_KR
sudo -u $SUDO_USER keyctl link $KEY_DESCR @u
