#!/bin/sh

BASE_DIR="$(pwd)"
WORK_DIR="$BASE_DIR/work"
CACHE_DIR="$BASE_DIR/cache"
OUT_DIR="$BASE_DIR/out"
OPENBSD_MIRROR="https://cdn.openbsd.org/pub/OpenBSD"
OPENBSD_VERSION="$(uname -r)"
OPENBSD_ARCH="$(uname -m)"
KERNEL_NAME="SigmaOS" # MUST be the same length as OpenBSD
