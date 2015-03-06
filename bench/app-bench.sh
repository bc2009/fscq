#!/bin/sh
echo "=== app-bench $1 ==="
cd $1

echo "=== git clone ==="
time git clone git@g.csail.mit.edu:fscq

echo "=== compile xv6 ==="
cd fscq/xv6
time make

echo "=== compile lfs bench ==="
cd ../bench/LFStest
time make

echo "=== run lfs large ==="
./largefile -f 1 -i 1 $1

echo "=== cleanup ==="

cd $1
time rm -rf *
