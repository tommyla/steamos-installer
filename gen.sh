#!/bin/sh
#Basic variables
BUILD="./buildroot"
APTCONF="./ftparchive/apt-ftparchive.conf"
APTUDEBCONF="./ftparchive/apt-ftparchive-udeb.conf"
DISTNAME="alchemist"
CACHEDIR="./cache"
ISOPATH="."
ISONAME="rocket.iso"
ISOVNAME="Stephensons Rocket 93plus1"
UPSTREAMURL="http://repo.steampowered.com"
STEAMINSTALLFILE="SteamOSDVD.iso"
MD5SUMFILE="MD5SUMS"
KNOWNINSTALLER="7a502c258043afa9a18360988c82cc02"
REPODIR="./archive-mirror/"

#Show how to use gen.sh
usage ( )
{
	cat <<EOF
	$0 [OPTION]
	-h                Print this message
	-d		  Re-Download ${STEAMINSTALLFILE}
EOF
}

#Check some basic dependencies this script needs to run
deps ( ) {
	#Check dependencies
	deps="apt-utils xorriso syslinux rsync wget unzip p7zip-full realpath"
	for dep in ${deps}; do
		if dpkg-query -s ${dep} >/dev/null 2>&1; then
			:
		else
			echo "Missing dependency: ${dep}"
			echo "Install with: sudo apt-get install ${dep}"
			exit 1
		fi
	done
	if test "`expr length \"$ISOVNAME\"`" -gt "32"; then
		echo "Volume ID is more than 32 characters: ${ISOVNAME}"
		exit 1
	fi

	#Check xorriso version is compatible, must be 1.2.4 or higher
	xorrisover=`xorriso --version 2>&1 | egrep -e "^xorriso version" | awk '{print $4}'`
	reqxorrisover=1.2.4
	if dpkg --compare-versions ${xorrisover} ge ${reqxorrisover} >/dev/null 2>&1; then
		echo "PASS: xorriso version ${xorrisover} supports required functions."
	else
		echo "ERROR: xorriso version ${xorrisover} is too to old. Please upgrade to xorriso version ${reqxorrisover} or higher."
		exit 1
	fi
}

#Remove the ${BUILD} directory to start from scratch
rebuild ( ) {
	if [ -d "${BUILD}" ]; then
		echo "Building ${BUILD} from scratch"
		rm -fr "${BUILD}"
	fi
}

#Report on obsolete packages
obsoletereport ( ) {
	echo "Reporting on packages which are different in ${BUILD} than ${REPODIR}"
	REPODIR="`realpath ${REPODIR}`"
	cd ${BUILD}/pool/
	for i in */*/*/*.*deb
		do PKGNAME=`basename $i | cut -f1 -d'_'`
		ARCHNAME=`basename $i | cut -f3 -d'_' | cut -f1 -d'.'`
		PKGPATH=`dirname $i`;PKGVER=`basename $i | cut -f2 -d'_'`
		DEBTYPE=`basename $i | sed 's/.*\.//g'`
		if [ `ls -1 ${REPODIR}/pool/${PKGPATH}/${PKGNAME}_*_${ARCHNAME}.${DEBTYPE} 2> /dev/null | wc -l` -gt 0 ]
			then NEWPKGVER=$(basename `ls -1 ${REPODIR}/pool/${PKGPATH}/${PKGNAME}_*_${ARCHNAME}.${DEBTYPE} | sort -n | tail -1` | cut -f2 -d'_')
			if [ "x${PKGVER}" != "x${NEWPKGVER}" ]
				then echo "${PKGNAME}\t${DEBTYPE}\t${ARCHNAME}\t${PKGVER}\t${NEWPKGVER}"
			fi
		fi
	done
	cd -
}

#Extract the upstream SteamOSInstaller.zip from repo.steampowered.com
extract ( ) {
	#Download SteamOSInstaller.zip
	steaminstallerurl="${UPSTREAMURL}/download/${STEAMINSTALLFILE}"
	#Download if the zip doesn't exist or the -d flag was passed
	if [ ! -f ${STEAMINSTALLFILE} ] || [ -n "${redownload}" ]; then
		echo "Downloading ${steaminstallerurl} ..."
		if wget -O ${STEAMINSTALLFILE} ${steaminstallerurl}; then
			:
		else
			echo "Error downloading ${steaminstallerurl}!"
			exit 1
		fi
	else
		echo "Using existing ${STEAMINSTALLFILE}"
	fi

	#Unzip SteamOSInstaller.zip into BUILD
	if 7z x ${STEAMINSTALLFILE} -o${BUILD}; then
		:
	else
		echo "Error unzipping ${STEAMINSTALLFILE} into ${BUILD}!"
		exit 1
	fi
	rm -fr ${BUILD}/\[BOOT\]
}

verify ( ) {
	#Does this installer look familiar?
	upstreaminstallermd5sum=` wget --quiet -O- ${UPSTREAMURL}/download/${MD5SUMFILE} | grep SteamOSDVD.iso$ | cut -f1 -d' '`
	localinstallermd5sum=`md5sum ${STEAMINSTALLFILE} | cut -f1 -d' '`
	if test "${localinstallermd5sum}" = "${KNOWNINSTALLER}"; then
		echo "Downloaded installer matches this version of gen.sh"
	elif test "${upstreaminstallermd5sum}" = "${KNOWNINSTALLER}"; then
		echo "Local installer is missing or obsolete"
		echo "Upstream version matches expectations, forcing update"
		redownload="1"
	else
		echo "ERROR! Local installer and remote installer both unknown" >&2
		echo "ERROR! Please update gen.sh to support unknown ${STEAMINSTALLFILE}" >&2
		exit 1
	fi
}

#Configure Rocket installer by:
#	Removing uneeded debs
#	Copy over modified/updated debs
#	Copy over Rocket files
#	Re-generate pressed files
#	Re-build the cdrom installer package repositories
#	Generate md5sums
#	Build ISO
create ( ) {

	#Delete 32-bit udebs and d-i, as SteamOS is 64-bit only
	echo "Deleting 32-bit garbage from ${BUILD}..."
	find ${BUILD} -name "*_i386.udeb" -type f -exec rm -rf {} \;
	find ${BUILD} -name "*_i386.deb" | egrep -v "(\/eglibc\/|\/elfutils\/|\/expat\/|\/fglrx-driver\/|\/gcc-4.7\/|\/libdrm\/|\/libffi\/|\/libpciaccess\/|\/libvdpau\/|\/libx11\/|\/libxau\/|\/libxcb\/|\/libxdamage\/|\/libxdmcp\/|\/libxext\/|\/libxfixes\/|\/libxxf86vm\/|\/llvm-toolchain-3.3\/|\/mesa\/|\/nvidia-graphics-drivers\/|\/s2tc\/|\/zlib\/)" | xargs rm -f
	rm -fr "${BUILD}/install.386"
	rm -fr "${BUILD}/dists/*/main/debian-installer/binary-i386/"

	#Copy over updated and added debs
	#First remove uneeded debs
	debstoremove="pool/non-free/f/firmware-nonfree/firmware-linux-nonfree_0.40+bsos1_all.deb pool/non-free/f/firmware-nonfree/firmware-realtek_0.40+bsos1_all.deb pool/main/d/debootstrap/debootstrap-udeb_1.0.54.steamos+bsos6_all.udeb pool/main/a/apache2/apache2.2-bin_2.2.22-13+bsos7_amd64.deb pool/main/b/base-files/base-files_7.1wheezy1+steamos5+bsos1_amd64.deb pool/main/b/base-files/base-files_7.1wheezy1+steamos5+bsos1_i386.deb pool/main/c/curl/curl_7.26.0-1+wheezy7+bsos1_amd64.deb pool/main/c/curl/curl_7.26.0-1+wheezy7+bsos1_i386.deb pool/main/c/curl/libcurl3_7.26.0-1+wheezy7+bsos1_amd64.deb pool/main/c/curl/libcurl3_7.26.0-1+wheezy7+bsos1_i386.deb pool/main/c/curl/libcurl3-gnutls_7.26.0-1+wheezy7+bsos1_amd64.deb pool/main/e/e2fsprogs/e2fslibs_1.42.8-1+bsos1_amd64.deb pool/main/e/e2fsprogs/e2fslibs_1.42.8-1+bsos1_i386.deb pool/main/e/e2fsprogs/e2fsprogs_1.42.8-1+bsos1_amd64.deb pool/main/e/e2fsprogs/e2fsprogs_1.42.8-1+bsos1_i386.deb pool/main/e/e2fsprogs/e2fsprogs-udeb_1.42.8-1+bsos1_amd64.udeb pool/main/e/e2fsprogs/e2fsprogs-udeb_1.42.8-1+bsos1_i386.udeb pool/main/e/e2fsprogs/libcomerr2_1.42.8-1+bsos1_amd64.deb pool/main/e/e2fsprogs/libcomerr2_1.42.8-1+bsos1_i386.deb pool/main/e/e2fsprogs/libss2_1.42.8-1+bsos1_amd64.deb pool/main/e/e2fsprogs/libss2_1.42.8-1+bsos1_i386.deb pool/main/e/eglibc/libc6_2.17-7+steamos1+bsos1_amd64.deb pool/main/e/eglibc/libc6_2.17-7+steamos1+bsos1_i386.deb pool/main/e/eglibc/libc6-udeb_2.17-7+steamos1+bsos1_amd64.udeb pool/main/e/eglibc/libc6-udeb_2.17-7+steamos1+bsos1_i386.udeb pool/main/e/eglibc/libc-bin_2.17-7+steamos1+bsos1_amd64.deb pool/main/e/eglibc/libc-bin_2.17-7+steamos1+bsos1_i386.deb pool/main/e/eglibc/libnss-dns-udeb_2.17-7+steamos1+bsos1_amd64.udeb pool/main/e/eglibc/libnss-dns-udeb_2.17-7+steamos1+bsos1_i386.udeb pool/main/e/eglibc/libnss-files-udeb_2.17-7+steamos1+bsos1_amd64.udeb pool/main/e/eglibc/libnss-files-udeb_2.17-7+steamos1+bsos1_i386.udeb pool/main/e/eglibc/locales_2.17-7+steamos1+bsos1_all.deb pool/main/e/eglibc/multiarch-support_2.17-7+steamos1+bsos1_amd64.deb pool/main/e/eglibc/multiarch-support_2.17-7+steamos1+bsos1_i386.deb pool/main/i/iceweasel/iceweasel_17.0.10esr-1~deb7u1+bsos1_amd64.deb pool/main/i/iceweasel/libmozjs17d_17.0.10esr-1~deb7u1+bsos1_amd64.deb pool/main/i/iceweasel/xulrunner-17.0_17.0.10esr-1~deb7u1+bsos1_amd64.deb pool/main/i/initramfs-tools/initramfs-tools_0.113~bpo70+1+bsos5_all.deb pool/main/libd/libdrm/libdrm2_2.4.49-2+bsos1_amd64.deb pool/main/libd/libdrm/libdrm2_2.4.49-2+bsos1_i386.deb pool/main/libd/libdrm/libdrm-intel1_2.4.49-2+bsos1_amd64.deb pool/main/libd/libdrm/libdrm-intel1_2.4.49-2+bsos1_i386.deb pool/main/libd/libdrm/libdrm-nouveau2_2.4.49-2+bsos1_amd64.deb pool/main/libd/libdrm/libdrm-nouveau2_2.4.49-2+bsos1_i386.deb pool/main/libd/libdrm/libdrm-radeon1_2.4.49-2+bsos1_amd64.deb pool/main/libd/libdrm/libdrm-radeon1_2.4.49-2+bsos1_i386.deb pool/main/o/openssl/libcrypto1.0.0-udeb_1.0.1e-2+deb7u3+bsos1_amd64.udeb pool/main/o/openssl/libcrypto1.0.0-udeb_1.0.1e-2+deb7u3+bsos1_i386.udeb pool/main/o/openssl/libssl1.0.0_1.0.1e-2+deb7u3+bsos1_amd64.deb pool/main/o/openssl/libssl1.0.0_1.0.1e-2+deb7u3+bsos1_i386.deb pool/main/s/steamos-base-files/steamos-base-files_2.20+bsos1_all.deb pool/main/t/tzdata/tzdata_2013h-0wheezy1+bsos1_all.deb pool/main/u/usbmount/usbmount_0.0.22+steamos1+bsos1_all.deb pool/main/v/valve-bugreporter/valve-bugreporter_2.11+bsos1_all.deb pool/main/x/xorg-server/xserver-common_1.12.4-6+steamos2+bsos1_all.deb pool/main/x/xorg-server/xserver-xorg-core_1.12.4-6+steamos2+bsos1_amd64.deb pool/main/x/xorg-server/xserver-xorg-core_1.12.4-6+steamos2+bsos1_i386.deb pool/non-free/s/steam/steam_1.0.0.45_i386.deb pool/non-free/s/steam/steam-launcher_1.0.0.45_all.deb pool/main/p/partman-target/partman-target_82+bsos1_all.udeb pool/main/l/lvm2/dmsetup_1.02.74-8+bsos7_amd64.deb pool/main/l/lvm2/libdevmapper1.02.1-udeb_1.02.74-8+bsos7_amd64.udeb pool/main/l/lvm2/lvm2_2.02.95-8_amd64.deb pool/main/l/lvm2/dmsetup-udeb_1.02.74-8+bsos7_amd64.udeb pool/main/l/lvm2/libdevmapper-event1.02.1_1.02.74-8+bsos7_amd64.deb pool/main/l/lvm2/lvm2-udeb_2.02.95-8+bsos7_amd64.udeb pool/main/l/lvm2/libdevmapper1.02.1_1.02.74-8+bsos7_amd64.deb pool/main/l/lvm2/liblvm2app2.2_2.02.95-8+bsos7_amd64.deb pool/main/g/grub-installer/grub-installer_1.85+bsos1_amd64.udeb pool/non-free/f/fglrx-driver/fglrx-driver_13.11~betav9.9-1+steamos1+bsos1_amd64.deb pool/non-free/f/fglrx-driver/fglrx-driver_13.11~betav9.9-1+steamos1+bsos1_i386.deb pool/non-free/f/fglrx-driver/fglrx-modules-dkms_13.11~betav9.9-1+steamos1+bsos1_amd64.deb pool/non-free/f/fglrx-driver/fglrx-modules-dkms_13.11~betav9.9-1+steamos1+bsos1_i386.deb pool/non-free/f/fglrx-driver/libfglrx_13.11~betav9.9-1+steamos1+bsos1_amd64.deb pool/non-free/f/fglrx-driver/libfglrx_13.11~betav9.9-1+steamos1+bsos1_i386.deb pool/non-free/f/fglrx-driver/libgl1-fglrx-glx_13.11~betav9.9-1+steamos1+bsos1_amd64.deb pool/non-free/f/fglrx-driver/libgl1-fglrx-glx_13.11~betav9.9-1+steamos1+bsos1_i386.deb pool/main/s/steamos-compositor/steamos-compositor_1.15.2+bsos1_amd64.deb pool/main/x/xserver-xorg-video-intel/xserver-xorg-video-intel_2.21.15-1+bsos1_amd64.deb pool/main/f/file/file_5.11-2+bsos6_amd64.deb pool/main/f/file/libmagic1_5.11-2+bsos6_amd64.deb pool/main/l/linux/btrfs-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/crc-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/crypto-dm-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/crypto-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/efi-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/event-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/ext2-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/ext3-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/ext4-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/firewire-core-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/fuse-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/hyperv-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/i2c-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/jfs-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/linux-headers-3.10-3-amd64_3.10.11-1+steamos10+bsos1_amd64.deb pool/main/l/linux/linux-headers-3.10-3-common_3.10.11-1+steamos10+bsos1_amd64.deb pool/main/l/linux/linux-image-3.10-3-amd64_3.10.11-1+steamos10+bsos1_amd64.deb pool/main/l/linux/loop-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/md-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/mmc-core-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/multipath-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/nbd-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/nic-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/nic-pcmcia-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/nic-shared-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/nic-usb-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/nic-wireless-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/ntfs-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/pata-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/pcmcia-storage-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/ppp-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/scsi-extra-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/sound-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/squashfs-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/udf-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/virtio-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/xfs-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/l/linux/zlib-modules-3.10-3-amd64-di_3.10.11-1+steamos10+bsos1_amd64.udeb pool/main/a/apt/apt_0.9.7.9+deb7u1+bsos1_amd64.deb pool/main/a/apt/apt-utils_0.9.7.9+deb7u1+bsos1_amd64.deb pool/main/a/apt/libapt-inst1.5_0.9.7.9+deb7u1+bsos1_amd64.deb pool/main/a/apt/libapt-pkg4.12_0.9.7.9+deb7u1+bsos1_amd64.deb pool/main/g/gnutls26/libgnutls26_2.12.20-7+steamos1+bsos1_amd64.deb pool/main/l/lightdm/liblightdm-gobject-1-0_1.2.2-4+steamos2+bsos1_amd64.deb pool/main/l/lightdm/lightdm_1.2.2-4+steamos2+bsos1_amd64.deb"
	for debremove in ${debstoremove}; do
		if [ -f ${BUILD}/${debremove} ]; then
			echo "Removing ${BUILD}/${debremove}..."
			rm -fr "${BUILD}/${debremove}"
		fi
	done

	#Delete all firmware from /firmware/
	echo "Removing bundled firmware"
        rm -f ${BUILD}/firmware/*

	#Rsync over our local pool dir
	pooldir="./pool"
	echo "Copying ${pooldir} into ${BUILD}..."
	if rsync -av ${pooldir} ${BUILD}; then
		:
	else
		echo "Error copying ${pooldir} to ${BUILD}"
		exit 1
	fi

	#Fix miscellaneous Valve fuckups
	#rm -f ${BUILD}/pool/non-free/f/fglrx-driver/*9.4*

	#Symlink all firmware
        for firmware in `cat firmware.txt`; do
                echo "Symlinking ${firmware} into /firmware/ folder"
                ln -s ../${firmware} ${BUILD}/firmware/`basename ${firmware}`
        done

	#Copy over the rest of our modified files
	rocketfiles="default.preseed post_install.sh boot isolinux"
	for file in ${rocketfiles}; do
		echo "Copying ${file} into ${BUILD}"
		cp -pfr ${file} ${BUILD}
	done

	#Make sure ${CACHEDIR} exists
	if [ ! -d ${CACHEDIR} ]; then
		mkdir -p ${CACHEDIR}
	fi

	#Generate our new repos
	echo "Generating Packages.."
	apt-ftparchive generate ${APTCONF}
	apt-ftparchive generate ${APTUDEBCONF}
	echo "Generating Release for ${DISTNAME}"
	apt-ftparchive -c ${APTCONF} release ${BUILD}/dists/${DISTNAME} > ${BUILD}/dists/${DISTNAME}/Release

	#gpg --default-key "0E1FAD0C" --output $BUILD/dists/$DISTNAME/Release.gpg -ba $BUILD/dists/$DISTNAME/Release
	cd ${BUILD}
	find . -type f -print0 | xargs -0 md5sum > md5sum.txt
	cd -

	#Remove old ISO
	if [ -f ${ISOPATH}/${ISONAME} ]; then
		echo "Removing old ISO ${ISOPATH}/${ISONAME}"
		rm -f "${ISOPATH}/${ISONAME}"
	fi

	#Build the ISO
	echo "Building ${ISOPATH}/${ISONAME} ..."
	xorriso -as mkisofs -r -checksum_algorithm_iso md5,sha1,sha256,sha512 \
		-V "${ISOVNAME}" -o ${ISOPATH}/${ISONAME} \
		-J -isohybrid-mbr /usr/lib/syslinux/isohdpfx.bin \
		-joliet-long -b isolinux/isolinux.bin \
		-c isolinux/boot.cat -no-emul-boot -boot-load-size 4 \
		-boot-info-table -eltorito-alt-boot -e boot/grub/efi.img \
		-no-emul-boot -isohybrid-gpt-basdat -isohybrid-apm-hfsplus ${BUILD}
}

#Setup command line arguments
while getopts "hd" OPTION; do
        case ${OPTION} in
        h)
                usage
                exit 1
        ;;
        d)
                redownload="1"
        ;;
        *)
                echo "${OPTION} - Unrecongnized option"
                usage
                exit 1
        ;;
        esac
done

#Check dependencies
deps

#Rebuild ${BUILD}
rebuild

#Make sure ${BUILD} exists
if [ ! -d ${BUILD} ]; then
	mkdir -p ${BUILD}
fi

#Verify we have an expected installer
verify

#Download and extract the SteamOSInstaller.zip
extract

#Build everything for Rocket installer
create

#Report on packages where newer is in the archive
obsoletereport

