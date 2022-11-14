#!/bin/sh

log() {
	echo "$(date +"%Y/%m/%d %H:%M:%S"): $@"
}

warnlog() {
	log "[WARNING] $@"
}

errlog() {
	log "[ERROR] $@"
}

readline_callback() {
	while IFS="" read -r line; do
		$2 "$line"
	done < "$1"
}

dd_patch() {
	out="$1"
	offset="$2"
	data="$3"

	tmp="$(mktemp)"
	printf "%s" "$data" > "$tmp"
	dd conv=notrunc bs=1 if="$tmp" of="$out" seek="$offset" > /dev/null 2>&1
	rm "$tmp"
}

bin_patch() {
	line="$(echo "$2" | sed 's/^ *//g')"
	offset="$(echo "$line" | cut -d " " -f 1)"
	data="$(echo "$line" | cut -d " " -f 2- | sed "s/OpenBSD/$KERNEL_NAME/g")"
	dd_patch "$1" "$offset" "$data"
}

# Check if user is running on OpenBSD
if [ "$(uname)" != "OpenBSD" ]; then
	warnlog "Not running OpenBSD"
fi

# Check if user has enough privileges
if ! [ "$(id -u)" = "0" ]; then
	errlog "Run as root"
	exit 1
fi

# Load configuration
. ./config.sh

# Check if kernel name length matches
openbsd_len="$(echo "OpenBSD" | wc -c | sed 's/ //g')"
name_len="$(echo "$KERNEL_NAME" | wc -c | sed 's/ //g')"
if ! [ -z "$KERNEL_NAME" ] && [ "$name_len" != "$openbsd_len" ]; then
	errlog "The kernel name length is '$name_len', which differs from '$openbsd_len'. Check your 'config.sh'."
	exit 1
fi

log "Base directory: $BASE_DIR"
log "Work directory: $WORK_DIR"
log "OpenBSD mirror: $OPENBSD_MIRROR"
log "OpenBSD version: $OPENBSD_VERSION"
log "OpenBSD architecture: $OPENBSD_ARCH"
if [ -d "$OUT_DIR" ]; then
	errlog "An output directory already exists: '$OUT_DIR'. Run 'clean.sh' to delete the previous build, or 'full_clean.sh' to delete the cache as well."
	exit 1
fi
mkdir -p "$WORK_DIR" "$CACHE_DIR" "$OUT_DIR"

# Fetch OpenBSD ISO
log "Fetching OpenBSD install ISO..."
openbsd_iso="$CACHE_DIR/openbsd.iso"
download_url="$OPENBSD_MIRROR/$OPENBSD_VERSION/$OPENBSD_ARCH/install$(echo "$OPENBSD_VERSION" | sed 's/\.//g').iso"

if [ -f "$openbsd_iso" ]; then
	warnlog "OpenBSD ISO already downloaded, skipping..."
else
	if ! ftp -o "$openbsd_iso" "$download_url" 2> /dev/null; then
	    errlog "Unable to fetch OpenBSD from: $download_url"
	    exit 1
	fi
	log "OpenBSD ISO fetched"
fi

# Check if ISO has already been extracted
iso_files_dir="$WORK_DIR/cd-dir"
# Mount ISO on temporary directory
iso_mount="$(mktemp -d)"
vndev="$(vnconfig -l | grep "not in use" | head -1 | cut -d ":" -f 1)"
if [ -z "$vndev" ]; then
	errlog "Uname to find available vndev for mounting the ISO"
	exit 1
fi

log "Linking ISO to vndev: $vndev"
vnconfig "$vndev" "$openbsd_iso"
mount -t cd9660 "/dev/${vndev}c" "$iso_mount"
log "Mounted the ISO on: $iso_mount"

# Copy files from ISO to work directory
log "Copying files from ISO to: $iso_files_dir"
cp -r "$iso_mount" "$iso_files_dir"
log "Files copied successfully"

# Unmount ISO from temporary directory
log "Unmounting ISO from vndev: $vndev"
umount "$iso_mount"
rm -r "$iso_mount"
vnconfig -u "$vndev"
log "Unmouned ISO successfully"

# Patch kernel name
fileset_dir="$iso_files_dir/$OPENBSD_VERSION/$OPENBSD_ARCH"
log "Patching kernel name..."
if ! [ -z "$KERNEL_NAME" ]; then
	# TODO: Improve string matches to avoid kernel issues
	cd "$fileset_dir"
	offsets_file="$(mktemp)"

	# Extract ramdisk
	mv bsd.rd bsd.rd.gz
	gunzip bsd.rd.gz

	# Patch kernel strings
	for bin in bsd bsd.mp bsd.rd cdboot; do
		if ! [ -f "$bin" ]; then
			continue
		fi

		log "Patching: $bin"
		if [ "$bin" = "bsd" ] || [ "$bin" = "bsd.mp" ]; then
			[ "$bin" = "bsd" ] && tail_count="4" || tail_count="3"
			strings -t d "$bin" | grep OpenBSD | tail -n "$tail_count" > "$offsets_file"
		elif [ "$bin" = "bsd.rd" ]; then
			_temp=$(mktemp)
			strings -t d "$bin" | grep OpenBSD > "$_temp"
			grep 'Copyright (c)' "$_temp" > "$offsets_file"
			grep 'export OBSD=' "$_temp" >> "$offsets_file"
			grep "OpenBSD $OPENBSD_VERSION" "$_temp" >> "$offsets_file"
			grep 'CONGRATULATIONS' "$_temp" >> "$offsets_file"
			grep 'dmesg' "$_temp" >> "$offsets_file"
			rm "$_temp"
			unset _temp
		elif [ "$bin" = "cdboot" ]; then
			strings -t d "$bin" | grep OpenBSD | head -n 1 > "$offsets_file"
		fi

		readline_callback "$offsets_file" "bin_patch $bin"
	done
	# Archive ramdisk
	gzip bsd.rd
	mv bsd.rd.gz bsd.rd

	# Clean up
	rm "$offsets_file"
	log "Finished patches"
else
	warnlog "Kernel name is not set, skipping patch..."
fi

# Regenerate SHA256 checksums
log "Regenerating the SHA256 checksums..."
cd "$fileset_dir"
rm SHA256
sha256 -h SHA256 *
log "Generated new SHA256 checksums"

# Create new ISO
log "Creating new ISO..."
iso_label="${KERNEL_NAME:=OpenBSD}/$OPENBSD_ARCH	$OPENBSD_VERSION Install CD"
log "ISO label: $iso_label"
cd "$iso_files_dir"
mkhybrid -a -d -D -L -l -N -R -T -v \
	-o "$OUT_DIR/install.iso" \
	-A "$iso_label" \
	-V "$iso_label" \
	-P "Copyright (c) Theo de Raadt, The OpenBSD Project, Rdbo" \
	-p "Theo de Raadt <deraadt@openbsd.org>" \
	-b "$OPENBSD_VERSION/$OPENBSD_ARCH/cdbr" \
	-c "$OPENBSD_VERSION/$OPENBSD_ARCH/boot.catalog" \
	"$iso_files_dir"
log "New ISO created"
cd "$BASE_DIR"
