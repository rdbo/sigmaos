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

get_vndev() {
	vndev="$(vnconfig -l | grep "not in use" | head -1 | cut -d ":" -f 1)"
	echo "$vndev"
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

push_package() {
	package="$(echo $1 | sed 's/#.*//g' | sed 's/ *//g')"
	if ! [ -z "$package" ]; then
		packages="$packages $package"
	fi
}

install_packages() {
	dest_dir="$1"
	if ! [ -z "$packages" ]; then
		PKG_DBDIR="$dest_dir/var/db/pkg" pkg_add -I -B "$dest_dir" $packages
	fi
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
if [ -d "$WORK_DIR" ]; then
	errlog "A work directory already exists: '$WORK_DIR'. Run 'clean.sh' to delete the previous build, or 'full_clean.sh' to delete the cache as well."
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
iso_mount="$WORK_DIR/mntiso"
mkdir -p "$iso_mount"
vndev="$(get_vndev)"
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
fileset_dir="$iso_files_dir/$OPENBSD_VERSION/$OPENBSD_ARCH"

# Unmount ISO from temporary directory
log "Unmounting ISO from vndev: $vndev"
umount "$iso_mount"
rm -r "$iso_mount"
vnconfig -u "$vndev"
log "Unmouned ISO successfully"

# Extract baseXX.tgz
baseXX="base${openbsd_shortver}.tgz"
log "Extracting '${baseXX}'..."
baseXX_dir="$CACHE_DIR/base"
if ! [ -d "$baseXX_dir" ]; then
	mkdir -p "$baseXX_dir"
	mv "$fileset_dir/$baseXX" "$baseXX_dir"
	cd "$baseXX_dir"
	tar -zxf "$baseXX" > /dev/null
	rm "$baseXX"
else
	warnlog "The directory '$baseXX_dir' already exists, skipping..."
fi


# Extract kernel.tgz
log "Extracting 'kernel.tgz'..."
kernel_dir="$CACHE_DIR/kernel"
kernel_path="${baseXX_dir}/usr/share/relink/kernel.tgz"
if ! [ -d "$kernel_dir" ]; then
	mkdir -p "$kernel_dir"
	mv "$kernel_path" "$kernel_dir"
	cd "$kernel_dir"
	tar -zxf kernel.tgz
	rm kernel.tgz
else
	warnlog "The directory '$kernel_dir' already exists, skipping..."
fi

# Copy base to work directory
new_baseXX_dir="$WORK_DIR/base"
log "Copying '$baseXX_dir' to '$new_baseXX_dir'..."
cp -r "$baseXX_dir" "$new_baseXX_dir"
baseXX_dir="$new_baseXX_dir"
cd "$fileset_dir"

# Copy kernel to work directory
new_kernel_dir="$WORK_DIR/kernel"
new_kernel_path="${baseXX_dir}/usr/share/relink/kernel.tgz"
log "Copying '$kernel_dir' to '$new_kernel_dir'..."
cp -r "$kernel_dir" "$new_kernel_dir"
kernel_dir="$new_kernel_dir"
kernel_path="$new_kernel_path"
cd "$fileset_dir"

# Patch kernel name
log "Patching kernel..."
if ! [ -z "$KERNEL_NAME" ]; then
	# TODO: Improve string matches to avoid kernel issues
	cd "$fileset_dir"
	offsets_file="$(mktemp)"

	# Extract ramdisk
	log "Extracting 'bsd.rd'..."
	mv bsd.rd bsd.rd.gz
	gunzip bsd.rd.gz

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

	# Clean up
	rm "$offsets_file"
	log "Finished patches"
else
	warnlog "Kernel name is not set, skipping patch..."
fi

# Add 'siteXX.tgz' set to default sets of 'bsd.rd'
# TODO: Merge this step with kernel patching to avoid
# extracting and archiving 'bsd.rd' twice
log "Adding 'site${openbsd_shortver}.tgz' to default sets..."
diskfs_dir="$WORK_DIR/diskfs"
mkdir -p "$diskfs_dir"
cd "$fileset_dir"

vndev="$(get_vndev)"
if [ -z "$vndev" ]; then
	errlog "Unable to find available vndev"
	exit 1
fi

mv bsd.rd bsd.rd.gz
gunzip bsd.rd.gz

rdsetroot -x bsd.rd disk.fs
vnconfig "$vndev" disk.fs
mount "/dev/${vndev}a" "$diskfs_dir"

cd "$diskfs_dir"
sed -i -E 's/^(SETS=.*)(}.*)/\1,site\2/g' install.sub

cd "$fileset_dir"
umount "/dev/${vndev}a"
rdsetroot bsd.rd disk.fs
gzip bsd.rd
mv bsd.rd.gz bsd.rd
vnconfig -u "$vndev"
rm -r "$diskfs_dir" disk.fs

# Install packages
log "Installing packages to '$baseXX_dir'..."
cd "$BASE_DIR"
mkdir -p "$baseXX_dir/var/db/pkg"
readline_callback "$BASE_DIR/packages" "push_package"
log "Packages: $packages"
install_packages "$baseXX_dir"
log "Packages installed"

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

# Create siteXX.tgz
site_file="site${openbsd_shortver}.tgz"
log "Creating '$site_file'..."
site_dir="$BASE_DIR/site"
cd "$site_dir"
tar -zchf "$fileset_dir/$site_file" *

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
