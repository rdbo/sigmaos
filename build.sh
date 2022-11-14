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
openbsd_iso="$CACHE_DIR/openbsd.iso"
openbsd_shortver="$(echo "$OPENBSD_VERSION" | sed 's/\.//g')"
download_url="$OPENBSD_MIRROR/$OPENBSD_VERSION/$OPENBSD_ARCH/install${openbsd_shortver}.iso"
log "Fetching OpenBSD install ISO from: '$download_url'..."

if [ -f "$openbsd_iso" ]; then
	warnlog "OpenBSD ISO already downloaded, skipping..."
else
	if ! ftp -o "$openbsd_iso" "$download_url" 2> /dev/null; then
	    errlog "Unable to fetch OpenBSD"
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
	log "Extracting 'bsd.rd'..."
	mv bsd.rd bsd.rd.gz
	gunzip bsd.rd.gz

	# Extract baseXX.tgz
	baseXX="base${openbsd_shortver}.tgz"
	log "Extracting '${baseXX}'..."
	baseXX_dir="$(mktemp -d)"
	mv "$fileset_dir/$baseXX" "$baseXX_dir"
	cd "$baseXX_dir"
	tar -zxf "$baseXX" > /dev/null
	rm "$baseXX"
	cd "$fileset_dir"

	# Extract kernel.tgz
	log "Extracting 'kernel.tgz'..."
	kernel_dir="$(mktemp -d)"
	kernel_path="${baseXX_dir}/usr/share/relink/kernel.tgz"
	mv "$kernel_path" "$kernel_dir"
	cd "$kernel_dir"
	tar -zxf "kernel.tgz"
	rm kernel.tgz

	# Patch kernel strings
	cd "$fileset_dir"
	baseXX_mdec="$baseXX_dir/usr/mdec"
	for bin in bsd bsd.mp bsd.rd cdboot "$baseXX_mdec/biosboot" "$baseXX_mdec/boot" "$baseXX_mdec/BOOTIA32.EFI" "$baseXX_mdec/BOOTX64.EFI" "$baseXX_mdec/cdboot" "$baseXX_mdec/fdboot" "$baseXX_mdec/pxeboot" "$kernel_dir/GENERIC/vers.o" "$kernel_dir/GENERIC.MP/vers.o"; do
		if ! [ -f "$bin" ]; then
			continue
		fi

		log "Patching '$bin'..."
		case "$bin" in
		bsd|bsd.mp)
			[ "$bin" = "bsd" ] && tail_count="4" || tail_count="3"
			strings -t d "$bin" | grep OpenBSD | tail -n "$tail_count" > "$offsets_file"
			;;
		bsd.rd)
			_temp=$(mktemp)
			strings -t d "$bin" | grep OpenBSD > "$_temp"
			grep 'Copyright (c)' "$_temp" > "$offsets_file"
			grep 'export OBSD=' "$_temp" >> "$offsets_file"
			grep "OpenBSD $OPENBSD_VERSION" "$_temp" >> "$offsets_file"
			grep 'CONGRATULATIONS' "$_temp" >> "$offsets_file"
			grep 'dmesg' "$_temp" >> "$offsets_file"
			rm "$_temp"
			unset _temp
			;;
		*/vers.o)
			strings -t d "$bin" | grep OpenBSD | head -n 3 > "$offsets_file"
			;;
		cdboot|"$baseXX_mdec"*)
			strings -t d "$bin" | grep OpenBSD | head -n 1 > "$offsets_file"
			;;
		esac

		readline_callback "$offsets_file" "bin_patch $bin"
	done
	# Archive ramdisk
	log "Archiving 'bsd.rd'..."
	gzip bsd.rd
	mv bsd.rd.gz bsd.rd

	# Archive kernel.tgz
	log "Archiving 'kernel.tgz'..."
	cd "$kernel_dir"
	tar -czf "$kernel_path" *
	cd "$baseXX_dir"
	rm -rf "$kernel_dir"

	# Archive baseXX.tgz
	log "Archiving '${baseXX}'..."
	cd "$baseXX_dir"
	tar -czf "${baseXX}" *
	mv "${baseXX}" "$fileset_dir"
	cd "$fileset_dir"
	rm -r "$baseXX_dir"

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
