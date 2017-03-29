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

if [ $# -ne 1 -o "x$1" == "x-h" ] ; then
	echo "Usage: $0 </path/to/cryptex/mountpoint>"
	exit 1
fi

if [ -z "$SUDO_USER" ] ; then
	exec sudo bash $0 "$@"
fi

if [ $(id -u) -ne 0 ] ; then
	echo unable to get root privilege
	exit 1
fi

MNT=$(realpath $1)
DEV=$(egrep "$MNT\s*ext4" /proc/mounts | cut -f 1 -d ' ')
test -z "$DEV" && exit 1

KEYID=$(e4crypt get_policy "$MNT" | grep -v "Error getting policy for" | sed -e 's/.*: //')
test -z "$KEYID" && exit 1

KEY_DESCR=$(keyctl show | awk "/ext4:$KEYID/"'{print $1}' | sort -u)
test -z "$KEY_DESCR" && exit 1

# remount volume read-only.
# acts as a barrier to prevent data loss if there are open files
sync $MNT
mount -o remount,ro $DEV $MNT

# and unmount
umount -l $MNT

# flush FS cache so that names aren't leaked
echo 2 > /proc/sys/vm/drop_caches

# revoke the filesystem key which renders it unusable until the keychain
# is flushed/reloaded
keyctl revoke $KEY_DESCR

# key revoked above, so reap it from the user's keychain as well as root's
keyctl reap
sudo -u $SUDO_USER keyctl reap
