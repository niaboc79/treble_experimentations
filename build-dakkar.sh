#!/bin/bash
set -e

if [ -z "$USER" ];then
    export USER="$(id -un)"
fi
export LC_ALL=C

## set defaults

rom_fp="$(date +%y%m%d)"

myname="$(basename "$0")"
if [[ $(uname -s) = "Darwin" ]];then
    jobs=$(sysctl -n hw.ncpu)
elif [[ $(uname -s) = "Linux" ]];then
    jobs=$(nproc)
fi

## handle command line arguments
if [[ -v build_dakkar_choice ]]
then
echo "Using exported choice"
else
read -p "Do you want to sync? (y/N) " build_dakkar_choice
fi
function help() {
    cat <<EOF
Syntax:

  $myname [-j 2] <rom type> <variant>...

Options:

  -j   number of parallel make workers (defaults to $jobs)

Variants are dash-joined combinations of (in order):
* processor type
  * "arm" for ARM 32 bit
  * "arm64" for ARM 64 bit
  * "a64" for ARM 32 bit system with 64 bit binder
* A or A/B partition layout ("aonly" or "ab")

for example:

* arm-aonly
* arm64-ab
* a64-aonly
EOF
}

function get_rom_type() {
    mainrepo="https://github.com/Havoc-OS-GSI/android_manifest.git"
    mainbranch="ten"
    localManifestBranch="android-10.0"
    extra_make_options="WITHOUT_CHECK_API=true"
    jack_enabled="false"                 
}

function parse_options() {
  while [[ $# -gt 0 ]]; do
      case "$1" in
          -j)
              jobs="$2";
              shift;
              ;;
      esac
      shift
  done
}

declare -A partition_layout_map
partition_layout_map[aonly]=a
partition_layout_map[ab]=b


function parse_variant() {
    local -a pieces
    IFS=- pieces=( $1 )

    local processor_type=${pieces[0]}
    local partition_layout=${partition_layout_map[${pieces[1]}]}

    if [[ -z "$processor_type" || -z "$partition_layout" ]]; then
        >&2 echo "Invalid variant '$1'"
        >&2 help
        exit 2
    fi

    echo "treble_${processor_type}_${partition_layout}vN"
}

declare -a variant_codes
declare -a variant_names
function get_variants() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            *-*)
                variant_codes[${#variant_codes[*]}]="$(parse_variant $1)-userdebug"
                variant_names[${#variant_names[*]}]="$1"
                ;;
        esac
        shift
    done
}

## function that actually do things

function init_release() {
    mkdir -p release/"$rom_fp"
}

function init_main_repo() {
    repo init -u "$mainrepo" -b "$mainbranch"
}

function init_local_manifest() {
    clone_or_checkout .repo/local_manifests treble_manifest
    rm -f .repo/local_manifests/replace.xml
    if grep -rqF exfat .repo/manifests || grep -qF exfat .repo/manifest.xml;then
        sed -i -E '/external\/exfat/d' .repo/local_manifests/manifest.xml
    fi
}

function clone_or_checkout() {
    local dir="$1"
    local repo="$2"
    if [[ -d "$dir" ]];then
        (
            cd "$dir"
            git fetch
            git reset --hard
            git checkout origin/"$localManifestBranch"
        )
    else
        git clone https://github.com/phhusson/"$repo" "$dir" -b "$localManifestBranch"
    fi
}

function sync_repo() {
    if [[ -v build_dakkar_fullclean ]]
    then
    echo "Using exported fullclean choice"
    else
    read -p "Do you want to fullclean? (y/N) " build_dakkar_fullclean
    fi
    if [[ $build_dakkar_fullclean == *"y"* ]];then
        repo forall -vc "git reset --hard"
    fi
    repo sync -c -j "$jobs" -f --force-sync --no-tag --no-clone-bundle --optimized-fetch --prune
}

function fix_missings() {
    rm -rf vendor/*/packages/overlays/NoCutout*
    # fix kernel source missing (on Q)
    sed 's;.*KERNEL_;//&;' -i vendor/*/build/soong/Android.bp 2>/dev/null || true
    mkdir -p device/sample/etc
    cd device/sample/etc
    wget -O apns-full-conf.xml https://github.com/LineageOS/android_vendor_lineage/raw/lineage-17.1/prebuilt/common/etc/apns-conf.xml 2>/dev/null
    cd ../../..
    mkdir -p device/generic/common/nfc
    cd device/generic/common/nfc
    wget -O libnfc-nci.conf https://github.com/ExpressLuke/treble_experimentations/raw/master/files/libnfc-nci.conf
    cd ../../../..
    sed -i '/Copies the APN/,/include $(BUILD_PREBUILT)/{/include $(BUILD_PREBUILT)/ s/.*/ /; t; d}' vendor/*/prebuilt/common/Android.mk 2>/dev/null || true
}


function patch_things() {
    rm -f device/*/sepolicy/common/private/genfs_contexts
    (
        cd device/phh/treble
        if [[ $build_dakkar_choice == *"y"* ]];then
            git clean -fdx
        fi
        bash generate.sh "havoc"
    )
    sed -i  "/.ntfs/d" device/phh/treble/sepolicy/file_contexts
}

function build_variant() {
    lunch "$1"
    make $extra_make_options BUILD_NUMBER="$rom_fp" installclean
    make $extra_make_options BUILD_NUMBER="$rom_fp" -j "$jobs" systemimage
    make $extra_make_options BUILD_NUMBER="$rom_fp" vndk-test-sepolicy
    newname=$(ls -t $OUT | grep Changelog.txt | head -1)
    newname=${newname##*/}
    newname=${newname/-Changelog.txt/}
    newname=${newname/--/-}
    cp "$OUT"/system.img release/"$rom_fp"/"$newname"-"$2".img
}

function jack_env() {
    RAM=$(free | awk '/^Mem:/{ printf("%0.f", $2/(1024^2))}') #calculating how much RAM (wow, such ram)
    if [[ "$RAM" -lt 16 ]];then #if we're poor guys with less than 16gb
    export JACK_SERVER_VM_ARGUMENTS="-Dfile.encoding=UTF-8 -XX:+TieredCompilation -Xmx"$((RAM -1))"G"
    fi
}

function clean_build() {
    make installclean
    rm -rf "$OUT"
}

parse_options "$@"
get_rom_type "$@"
get_variants "$@"

if [[ -z "$mainrepo" || ${#variant_codes[*]} -eq 0 ]]; then
    >&2 help
    exit 1
fi

# Use a python2 virtualenv if system python is python3
python=$(python -V | awk '{print $2}' | head -c2)
if [[ $python == "3." ]]; then
    if [ ! -d .venv ]; then
        virtualenv2 .venv
    fi
    . .venv/bin/activate
fi

init_release
if [[ $build_dakkar_choice == *"y"* ]];then
    init_main_repo
    init_local_manifest
    sync_repo
    fix_missings
    patch_things
fi

if [[ $jack_enabled == "true" ]]; then
    jack_env
fi

if [[ -v build_dakkar_clean ]]
then
echo "Using exported clean choice"
else
read -p "Do you want to clean? (y/N) " build_dakkar_clean
fi

if [[ $build_dakkar_clean == *"y"* ]];then
    clean_build
fi

. build/envsetup.sh

for (( idx=0; idx < ${#variant_codes[*]}; idx++ )); do
    build_variant "${variant_codes[$idx]}" "${variant_names[$idx]}"
done
