#!/bin/bash
# vim: et:ts=2:sw=2

set -e

img="$1"
mnt=/tmp/fscq
DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
code="$DIR/../.."

if [ -z "$img" ]; then
  echo "Usage: $0 <disk.img>"
  exit 1
fi

mkfs --data-bitmaps 20 --inode-bitmaps 20 --log-desc-blocks 256 $img
fscq $img "$mnt" -f &
sleep 4

cp -r ~/xv6 "$mnt/"
cd "$mnt/"
tar -xf ~/coq.tar.xz
sync "$mnt/coq"

#tar -xf ~/linux.tar.xz

for file in "$mnt"/**; do
  sync "$file"
done