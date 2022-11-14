#!/bin/sh

if [ "$(id -u)" != "0" ]; then
	echo "Run as root"
	exit 1
fi

. ./config.sh
rm -rf "$WORK_DIR" "$CACHE_DIR" "$OUT_DIR"
