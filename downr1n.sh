#!/usr/bin/env bash

mkdir -p logs
mkdir -p boot
set -e

log="last".log
cd logs
touch "$log"
cd ..

{

echo "[*] Command ran:`if [ $EUID = 0 ]; then echo " sudo"; fi` ./downr1n.sh $@"

# =========
# Variables
# ========= 
ipsw="ipsw/*.ipsw" # put your ipsw 
version="1.0"
os=$(uname)
dir="$(pwd)/binaries/$os"
max_args=2
arg_count=0
extractedIpsw="ipsw/extracted/"

# =========
# Functions
# =========
remote_cmd() {
    sleep 1
    "$dir"/sshpass -p 'alpine' ssh -o StrictHostKeyChecking=no -p2222 root@localhost "$@"
    sleep 1
}

remote_cp() {
    sleep 1
    "$dir"/sshpass -p 'alpine' scp -r -o StrictHostKeyChecking=no -P2222 "$@"
    sleep 1
}

step() {
    for i in $(seq "$1" -1 0); do
        if [ "$(get_device_mode)" = "dfu" ]; then
            break
        fi
        printf '\r\e[K\e[1;36m%s (%d)' "$2" "$i"
        sleep 1
    done
    printf '\e[0m\n'
}

print_help() {
    cat << EOF
Usage: $0 [Options] [ subcommand | iOS version which are you]. put your ipsw in the directory ipsw/
iOS 15 - 14.0 downgrade tool ./downr1n --downgrade 15.7 (the ios of your device) ipsw 

Options:
    --downgrade         downgrade tethered your device to ios 14,15.
    --dfuhelper         A helper to help get A11 devices into DFU mode from recovery mode
    --boot              this boot the device.
    --fixBoot           that will boot the device using fsboot
    --debug             Debug the script

Subcommands:
    clean               Deletes the created boot files 



The iOS version argument should be the iOS version of your device.
It is required when starting from DFU mode.
EOF
}

parse_opt() {
    case "$1" in
        --)
            no_more_opts=1
            ;;
        --downgrade)
            downgrade=1
            ;;
        --boot)
            boot=1
            ;;
        --fixBoot)
            fixBoot=1
            ;;
        --dfuhelper)
            dfuhelper=1
            ;;
        --debug)
            debug=1
            ;;
        --help)
            print_help
            exit 0
            ;;
        *)
            echo "[-] Unknown option $1. Use $0 --help for help."
            exit 1;
    esac
}

parse_arg() {
    arg_count=$((arg_count + 1))
    case "$1" in
        dfuhelper)
            dfuhelper=1
            ;;
        *)
            version="$1"
            ;;
    esac
}

parse_cmdline() {
    for arg in $@; do
        if [[ "$arg" == --* ]] && [ -z "$no_more_opts" ]; then
            parse_opt "$arg";
        elif [ "$arg_count" -lt "$max_args" ]; then
            parse_arg "$arg";
        else
            echo "[-] Too many arguments. Use $0 --help for help.";
            exit 1;
        fi
    done
}

recovery_fix_auto_boot() {
    "$dir"/irecovery -c "setenv auto-boot true"
    "$dir"/irecovery -c "saveenv"
}

_info() {
    if [ "$1" = 'recovery' ]; then
        echo $("$dir"/irecovery -q | grep "$2" | sed "s/$2: //")
    elif [ "$1" = 'normal' ]; then
        echo $("$dir"/ideviceinfo | grep "$2: " | sed "s/$2: //")
    fi
}

_pwn() {
    pwnd=$(_info recovery PWND)
    if [ "$pwnd" = "" ]; then
        echo "[*] Pwning device"
        "$dir"/gaster pwn
        sleep 2
        #"$dir"/gaster reset
        #sleep 1
    fi
}

_reset() {
        echo "[*] Resetting DFU state"
        "$dir"/gaster reset
}

get_device_mode() {
    if [ "$os" = "Darwin" ]; then
        apples="$(system_profiler SPUSBDataType 2> /dev/null | grep -B1 'Vendor ID: 0x05ac' | grep 'Product ID:' | cut -dx -f2 | cut -d' ' -f1 | tail -r)"
    elif [ "$os" = "Linux" ]; then
        apples="$(lsusb | cut -d' ' -f6 | grep '05ac:' | cut -d: -f2)"
    fi
    local device_count=0
    local usbserials=""
    for apple in $apples; do
        case "$apple" in
            12a8|12aa|12ab)
            device_mode=normal
            device_count=$((device_count+1))
            ;;
            1281)
            device_mode=recovery
            device_count=$((device_count+1))
            ;;
            1227)
            device_mode=dfu
            device_count=$((device_count+1))
            ;;
            1222)
            device_mode=diag
            device_count=$((device_count+1))
            ;;
            1338)
            device_mode=checkra1n_stage2
            device_count=$((device_count+1))
            ;;
            4141)
            device_mode=pongo
            device_count=$((device_count+1))
            ;;
        esac
    done
    if [ "$device_count" = "0" ]; then
        device_mode=none
    elif [ "$device_count" -ge "2" ]; then
        echo "[-] Please attach only one device" > /dev/tty
        kill -30 0
        exit 1;
    fi
    if [ "$os" = "Linux" ]; then
        usbserials=$(cat /sys/bus/usb/devices/*/serial)
    elif [ "$os" = "Darwin" ]; then
        usbserials=$(system_profiler SPUSBDataType 2> /dev/null | grep 'Serial Number' | cut -d: -f2- | sed 's/ //')
    fi
    if grep -qE '(ramdisk tool|SSHRD_Script) (Jan|Feb|Mar|Apr|May|Jun|Jul|Aug|Sep|Oct|Nov|Dec) [0-9]{1,2} [0-9]{4} [0-9]{2}:[0-9]{2}:[0-9]{2}' <<< "$usbserials"; then
        device_mode=ramdisk
    fi
    echo "$device_mode"
}

_wait() {
    if [ "$(get_device_mode)" != "$1" ]; then
        echo "[*] Waiting for device in $1 mode"
    fi

    while [ "$(get_device_mode)" != "$1" ]; do
        sleep 1
    done

    if [ "$1" = 'recovery' ]; then
        recovery_fix_auto_boot;
    fi
}

_dfuhelper() {
    local step_one;
    deviceid=$( [ -z "$deviceid" ] && _info normal ProductType || echo $deviceid )
    if [[ "$1" = 0x801* && "$deviceid" != *"iPad"* ]]; then
        step_one="Hold volume down + side button"
    else
        step_one="Hold home + power button"
    fi
    echo "[*] To get into DFU mode, you will be guided through 2 steps:"
    echo "[*] Press any key when ready for DFU mode"
    read -n 1 -s
    step 3 "Get ready"
    step 4 "$step_one" &
    sleep 3
    "$dir"/irecovery -c "reset" &
    sleep 1
    if [[ "$1" = 0x801* && "$deviceid" != *"iPad"* ]]; then
        step 10 'Release side button, but keep holding volume down'
    else
        step 10 'Release power button, but keep holding home button'
    fi
    sleep 1

    if [ "$(get_device_mode)" = "recovery" ]; then
        _dfuhelper
    fi

    if [ "$(get_device_mode)" = "dfu" ]; then
        echo "[*] Device entered DFU!"
    else
        echo "[-] Device did not enter DFU mode, rerun the script and try again"
       exit;
    fi
}

_kill_if_running() {
    if (pgrep -u root -x "$1" &> /dev/null > /dev/null); then
        # yes, it's running as root. kill it
        sudo killall $1 &> /dev/null
    else
        if (pgrep -x "$1" &> /dev/null > /dev/null); then
            killall $1 &> /dev/null
        fi
    fi
}

_runFuturerestore() {
  cat <<EOF
===================================================================================================
#                          WARNING: Starting 'futurerestore' command !
---------------------------------------------------------------------------------------------------
If futurerestore FAILS, Run '$0 --downgrade' to try again.
---------------------------------------------------------------------------------------------------
If futurerestore SUCCEEDS, Run '$0 --boot' to boot device.
---------------------------------------------------------------------------------------------------
===================================================================================================
EOF
  read -p "Press ENTER to continue <-"
  rm -rf /tmp/futurerestore/
  "$dir"/futurerestore -t blobs/"$deviceid"-"$version".shsh2 --use-pwndfu --skip-blob \
    --rdsk work/rdsk.im4p --rkrn work/rkrn.im4p \
    --latest-sep --latest-baseband $ipsw
  exit
}

_boot() {
    _pwn
    sleep 1
    _reset
    sleep 1
    
    echo "[*] Booting device"

    "$dir"/irecovery -f "blobs/"$deviceid"-"$version".der"
    sleep 1

    "$dir"/irecovery -f "boot/${deviceid}/iBSS.img4"
    sleep 1

    "$dir"/irecovery -f "boot/${deviceid}/iBEC.img4"
    sleep 3
    
    if [[ "$cpid" == *"0x801"* ]]; then
        "$dir"/irecovery -c "go"
        sleep 2
    else
       "$dir"/irecovery -c "bootx"
        sleep 2
    
    fi


    "$dir"/irecovery -f "boot/${deviceid}/devicetree.img4"
    sleep 1 

    "$dir"/irecovery -c "devicetree"
    sleep 1
    
    "$dir"/irecovery -v -f "boot/${deviceid}/trustcache.img4"    

    "$dir"/irecovery -c "firmware"
    sleep 1

    "$dir"/irecovery -f "boot/${deviceid}/kernelcache.img4"
    sleep 1

    "$dir"/irecovery -c `if [ ! "$fixBoot" = "1" ]; then echo "bootx" else "fsboot"; fi`
    exit;
}

_exit_handler() {
    if [ "$os" = "Darwin" ]; then
        killall -CONT AMPDevicesAgent AMPDeviceDiscoveryAgent MobileDeviceUpdater || true
    fi

    [ $? -eq 0 ] && exit
    echo "[-] An error occurred"

    if [ -d "logs" ]; then
        cd logs
        mv "$log" FAIL_${log}
        cd ..
    fi

    echo "[*] A failure log has been made. If you're going ask for help, please attach the latest log."
}
trap _exit_handler EXIT


# ============
# Dependencies
# ============


if [ "$os" = 'Linux' ]; then
    linux_cmds='lsusb'
fi

for cmd in clang unzip python3 git ssh scp killall sudo grep pgrep ${linux_cmds}; do
    if ! command -v "${cmd}" > /dev/null; then
        echo "[-] Command '${cmd}' not installed, please install it!";
        cmd_not_found=1
    fi
done
if [ "$cmd_not_found" = "1" ]; then
    exit 1
fi


# Download gaster
if [ -e "$dir"/gaster ]; then
    "$dir"/gaster &> /dev/null > /dev/null | grep -q 'usb_timeout: 5' && rm "$dir"/gaster
fi

if [ ! -e "$dir"/gaster ]; then
    curl -sLO https://static.palera.in/deps/gaster-"$os".zip
    unzip gaster-"$os".zip
    mv gaster "$dir"/
    rm -rf gaster gaster-"$os".zip
fi

# Check for pyimg4
if ! python3 -c 'import pkgutil; exit(not pkgutil.find_loader("pyimg4"))'; then
    echo '[-] pyimg4 not installed. Press any key to install it, or press ctrl + c to cancel'
    read -n 1 -s
    python3 -m pip install pyimg4
fi

# Update submodules
git submodule update --init --recursive 
git submodule foreach git pull origin main

# Re-create work dir if it exists, else, make it
if [ -e work ]; then
    rm -rf work
    mkdir work
else
    mkdir work
fi

chmod +x "$dir"/*

# ============
# Start
# ============

echo "downr1n | Version 1.0"
echo "Created by edwin, thanks sunst0rm, and all people creator of path file boot"
echo ""

parse_cmdline "$@"

if [ "$debug" = "1" ]; then
    set -o xtrace
fi

if [ "$clean" = "1" ]; then
    rm -rf  work blobs/ boot/"$deviceid"/  ipsw/*
    echo "[*] Removed the created boot files"
    exit
fi


# Get device's iOS version from ideviceinfo if in normal mode
echo "[*] Waiting for devices"
while [ "$(get_device_mode)" = "none" ]; do
    sleep 1;
done
echo $(echo "[*] Detected $(get_device_mode) mode device" | sed 's/dfu/DFU/')

if grep -E 'pongo|checkra1n_stage2|diag' <<< "$(get_device_mode)"; then
    echo "[-] Detected device in unsupported mode '$(get_device_mode)'"
    exit 1;
fi

if [ "$(get_device_mode)" != "normal" ] && [ -z "$version" ] && [ "$dfuhelper" != "1" ]; then
    echo "[-] You must pass the version your device is on when not starting from normal mode"
    exit
fi

if [ "$(get_device_mode)" = "ramdisk" ]; then
    # If a device is in ramdisk mode, perhaps iproxy is still running?
    _kill_if_running iproxy
    echo "[*] Rebooting device in SSH Ramdisk"
    if [ "$os" = 'Linux' ]; then
        sudo "$dir"/iproxy 2222 22 &
    else
        "$dir"/iproxy 2222 22 &
    fi
    sleep 1
    remote_cmd "/sbin/reboot"
    _kill_if_running iproxy
    _wait recovery
fi

if [ "$(get_device_mode)" = "normal" ]; then
    version=${version:-$(_info normal ProductVersion)}
    arch=$(_info normal CPUArchitecture)
    if [ "$arch" = "arm64e" ]; then
        echo "[-] downgrade doesn't, and never will, work on non-checkm8 devices"
        exit
    fi
    echo "Hello, $(_info normal ProductType) on $version!"

    echo "[*] Switching device into recovery mode..."
    "$dir"/ideviceenterrecovery $(_info normal UniqueDeviceID)
    _wait recovery
fi

# Grab more info
echo "[*] Getting device info..."
cpid=$(_info recovery CPID)
model=$(_info recovery MODEL)
deviceid=$(_info recovery PRODUCT)

echo "$cpid"
echo "$model"
echo "$deviceid"

if [ "$dfuhelper" = "1" ]; then
    echo "[*] Running DFU helper"
    _dfuhelper "$cpid"
    exit
fi

ipswurl=$(curl -sL "https://api.ipsw.me/v4/device/$deviceid?type=ipsw" | "$dir"/jq '.firmwares | .[] | select(.version=="'$version'")' | "$dir"/jq -s '.[0] | .url' --raw-output)


# Have the user put the device into DFU
if [ "$(get_device_mode)" != "dfu" ]; then
    recovery_fix_auto_boot;
    _dfuhelper "$cpid" || {
        echo "[-] failed to enter DFU mode, run downr1n.sh again"
        exit -1
    }
fi
sleep 2


if [ "$boot" = "1" ]; then # call boot in order to boot it 
    _boot
fi


    # =========
    # extract ipsw 
    # =========
cd ipsw/
ipsw_files=(*.ipsw)
if [[ ${#ipsw_files[@]} -gt 1 ]]; then
    echo "in ipsw/ directory there is more than one ipsw so delete one and try again please"
    cd ..
    exit;
fi
cd ..

if [ -a "$ipsw" ] || [ "${ipsw: -5}" == ".ipsw" ]; then
  echo "Continuing..."
else
  _eexit "$ipsw is not a valid ipsw file."
fi

if [ "$downgrade" = "1" ]; then
    # extracting ipsw
    echo "extracting ipsw, hang on please ..." # this will extract the ipsw into ipsw/extracted
    unzip -n $ipsw -d "ipsw/extracted"
    cp -v "$extractedIpsw/BuildManifest.plist" work/
    echo "now the IPSW is extracted"
fi


# ============
# Ramdisk
# ============

# Dump blobs, and install pogo if needed 
if [ "$downgrade" = "1" ]; then
    mkdir -p blobs

    cd ramdisk
    chmod +x sshrd.sh
    echo "[*] Creating ramdisk"
    ./sshrd.sh 15.6 

    echo "[*] Booting ramdisk"
    ./sshrd.sh boot
    cd ..
    # remove special lines from known_hosts
    if [ -f ~/.ssh/known_hosts ]; then
        if [ "$os" = "Darwin" ]; then
            sed -i.bak '/localhost/d' ~/.ssh/known_hosts
            sed -i.bak '/127\.0\.0\.1/d' ~/.ssh/known_hosts
        elif [ "$os" = "Linux" ]; then
            sed -i '/localhost/d' ~/.ssh/known_hosts
            sed -i '/127\.0\.0\.1/d' ~/.ssh/known_hosts
        fi
    fi

    # Execute the commands once the rd is booted
    if [ "$os" = 'Linux' ]; then
        sudo "$dir"/iproxy 2222 22 &
    else
        "$dir"/iproxy 2222 22 &
    fi

    if ! ("$dir"/sshpass -p 'alpine' ssh -o StrictHostKeyChecking=no -p2222 root@localhost "echo connected" &> /dev/null); then
        echo "[*] Waiting for the ramdisk to finish booting"
    fi

    while ! ("$dir"/sshpass -p 'alpine' ssh -o StrictHostKeyChecking=no -p2222 root@localhost "echo connected" &> /dev/null); do
        sleep 1
    done

    remote_cmd "/usr/bin/mount_filesystems"

    has_active=$(remote_cmd "ls /mnt6/active" 2> /dev/null)
    if [ ! "$has_active" = "/mnt6/active" ]; then
        echo "[!] Active file does not exist! Please use SSH to create it"
        echo "    /mnt6/active should contain the name of the UUID in /mnt6"
        echo "    When done, type reboot in the SSH session, then rerun the script"
        echo "    ssh root@localhost -p 2222"
        exit
    fi
    active=$(remote_cmd "cat /mnt6/active" 2> /dev/null)
    mkdir -p "boot/${deviceid}"

    if [ ! -e blobs/"$deviceid"-"$version".shsh2 ]; then
        remote_cmd "cat /dev/rdisk1" | dd of=dump.raw bs=256 count=$((0x4000)) 
        "$dir"/img4tool --convert -s blobs/"$deviceid"-"$version".shsh2 dump.raw
        echo "[*] Converting blob"
        sleep 3
        rm dump.raw

    fi

    "$dir"/img4tool -e -s $(pwd)/blobs/"$deviceid"-"$version".shsh2 -m work/IM4M
    echo "Dumpped SHSH"

    sleep 1
    
    if [ -e boot/"$deviceid" ]; then
        rm -rf boot/"$deviceid"
        mkdir boot/"$deviceid"
    else
        mkdir boot/"$deviceid"
    fi

    remote_cmd "/usr/sbin/nvram auto-boot=false"
    remote_cmd "/sbin/reboot"
    _wait recovery
    sleep 4
    _dfuhelper "$cpid"
    sleep 3

    echo "Patchimg some boot files..."

    if [ "$fixBoot" = "1" ]; then # i put it because my friend tested on his ipad and that does not boot so when we download all file from the internet so not extracting ipsw that boot fine idk why 
        cd work
        #that will download the files needed
        sleep 1
        "$dir"/pzb -g "$(awk "/""${model}""/{x=1}x&&/iBSS[.]/{print;exit}" BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "$ipswurl"
        "$dir"/pzb -g "$(awk "/""${model}""/{x=1}x&&/iBoot[.]/{print;exit}" BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "$ipswurl"
        "$dir"/pzb -g "$(awk "/""${model}""/{x=1}x&&/DeviceTree[.]/{print;exit}" BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "$ipswurl"
        "$dir"/pzb -g "$(awk "/""${model}""/{x=1}x&&/kernelcache.release/{print;exit}" BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "$ipswurl"
        
        if [ "$os" = 'Darwin' ]; then
            "$dir"/pzb -g Firmware/"$(/usr/bin/plutil -extract "BuildIdentities".0."Manifest"."OS"."Info"."Path" xml1 -o - BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | head -1)".trustcache "$ipswurl"
        else
            "$dir"/pzb -g Firmware/"$(../binaries/Linux/PlistBuddy BuildManifest.plist -c "Print BuildIdentities:0:Manifest:OS:Info:Path" | sed 's/"//g')".trustcache "$ipswurl"
        fi
        cd ..
    else
        #that will extract the files needed
        cp  "$extractedIpsw$(awk "/""${model}""/{x=1}x&&/iBSS[.]/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "work/"
        cp  "$extractedIpsw$(awk "/""${model}""/{x=1}x&&/iBEC[.]/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "work/"
        cp  "$extractedIpsw$(awk "/""${model}""/{x=1}x&&/DeviceTree[.]/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "work/"
        cp  "$extractedIpsw$(awk "/""${model}""/{x=1}x&&/kernelcache.release/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" "work/"
        
        if [ "$os" = 'Darwin' ]; then
            "$dir"/img4 -i "$extractedIpsw"/Firmware/"$(/usr/bin/plutil -extract "BuildIdentities".0."Manifest"."OS"."Info"."Path" xml1 -o - work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | head -1)".trustcache -o work/trustcache.img4 -M work/IM4M
        else
            "$dir"/img4 -i "$extractedIpsw"/Firmware/"$(binaries/Linux/PlistBuddy work/BuildManifest.plist -c "Print BuildIdentities:0:Manifest:OS:Info:Path" | sed 's/"//g')".trustcache -o work/trustcache.img4 -M work/IM4M
        fi
    fi

    "$dir"/gaster decrypt work/"$(awk "/""${model}""/{x=1}x&&/iBSS[.]/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | sed 's/Firmware[/]dfu[/]//')" work/iBSS.dec
    "$dir"/iBoot64Patcher work/iBSS.dec work/iBSS.patched
    "$dir"/img4 -i work/iBSS.patched -o work/iBSS.img4 -M work/IM4M -A -T ibss

    if [ "$fixBoot" = "1" ]; then # fixboot will download the boot files, sometimes that fix most of boot also boot with anoter patcher
        "$dir"/gaster decrypt work/"$(awk "/""${model}""/{x=1}x&&/iBoot[.]/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | sed 's/Firmware[/]all_flash[/]//')" work/iBEC.dec
    else
        "$dir"/gaster decrypt work/"$(awk "/""${model}""/{x=1}x&&/iBEC[.]/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | sed 's/Firmware[/]dfu[/]//')" work/iBEC.dec
    fi
    
    "$dir"/iBoot64Patcher work/iBEC.dec work/iBEC.patched -b " -v wdt=-1 keepsyms=1 debug=0x2014e `if [ "$cpid" = '0x8960' ] || [ "$cpid" = '0x7000' ] || [ "$cpid" = '0x7001' ]; then echo "-restore"; fi`" -n `if [ "$fixBoot" = "1" ]; then echo "-f"; fi`
    "$dir"/img4 -i work/iBEC.patched -o work/iBEC.img4 -M work/IM4M -A -T ibec

    if [[ "$deviceid" == "iPhone8"* ]] || [[ "$deviceid" == "iPad6"* ]] || [[ "$deviceid" == *'iPad5'* ]]; then
        python3 -m pyimg4 im4p extract -i work/"$(awk "/""${model}""/{x=1}x&&/kernelcache.release/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" -o work/kcache.raw --extra work/kpp.bin
    else
        python3 -m pyimg4 im4p extract -i work/"$(awk "/""${model}""/{x=1}x&&/kernelcache.release/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1)" -o work/kcache.raw
    fi

    "$dir"/Kernel64Patcher work/kcache.raw work/kcache.patched -a -b -e `if [ "$fixBoot" = "1" ]; then echo "-s"; fi`
    
    if [[ "$deviceid" == *'iPhone8'* ]] || [[ "$deviceid" == *'iPad6'* ]] || [[ "$deviceid" == *'iPad5'* ]]; then
        python3 -m pyimg4 im4p create -i work/kcache.patched -o work/kcache.im4p -f rkrn --extra work/kpp.bin --lzss
    else
        python3 -m pyimg4 im4p create -i work/kcache.patched -o work/kcache.im4p -f rkrn --lzss
    fi
    python3 -m pyimg4 img4 create -p work/kcache.im4p -o work/kernelcache.img4 -m work/IM4M

    if [ "$os" = 'Darwin' ]; then
        "$dir"/img4 -i work/"$(/usr/bin/plutil -extract "BuildIdentities".0."Manifest"."RestoreKernelCache"."Info"."Path" xml1 -o - work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | head -1)" -o work/kcache.dec
    else
        "$dir"/img4 -i work/"$(binaries/Linux/PlistBuddy work/BuildManifest.plist -c "Print BuildIdentities:0:Manifest:RestoreKernelCache:Info:Path" | sed 's/"//g')" -o work/kcache.dec
    fi
    "$dir"/Kernel64Patcher work/kcache.dec work/kcache.patched -a -b -e 
    python3 -m pyimg4 im4p create -i work/kcache.patched -o work/rkrn.im4p -f rkrn --lzss


    "$dir"/img4 -i work/"$(awk "/""${model}""/{x=1}x&&/DeviceTree[.]/{print;exit}" work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | sed 's/Firmware[/]all_flash[/]//')" work/devicetree.img4 -M work/IM4M -T rdtr
    
    if [ "$os" = 'Darwin' ]; then
        cp "$extractedIpsw$(/usr/bin/plutil -extract "BuildIdentities".0."Manifest"."RestoreRamDisk"."Info"."Path" xml1 -o - work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | head -1)" "work/"
    else
        cp "$extractedIpsw$(binaries/Linux/PlistBuddy work/BuildManifest.plist -c "Print BuildIdentities:0:Manifest:RestoreRamDisk:Info:Path" | sed 's/"//g')" "work/"
    fi

    if [ "$os" = 'Darwin' ]; then
        "$dir"/img4 -i work/"$(/usr/bin/plutil -extract "BuildIdentities".0."Manifest"."RestoreRamDisk"."Info"."Path" xml1 -o - work/BuildManifest.plist | grep '<string>' |cut -d\> -f2 |cut -d\< -f1 | head -1)" -o work/ramdisk.dmg
    else
        "$dir"/img4 -i work/"$(binaries/Linux/PlistBuddy work/BuildManifest.plist -c "Print BuildIdentities:0:Manifest:RestoreRamDisk:Info:Path" | sed 's/"//g')" -o work/ramdisk.dmg
    fi
    
    if [ "$os" = 'Darwin' ]; then
        hdiutil attach work/ramdisk.dmg -mountpoint /tmp/SSHRD
        mounted="/tmp/SSHRD"

        "$dir"/asr64_patcher $mounted/usr/sbin/asr work/patched_asr
        "$dir"/ldid -e $mounted/usr/sbin/asr > work/asr.plist
        "$dir"/ldid -Swork/asr.plist work/patched_asr
        chmod 755 work/patched_asr

        cp $mounted/usr/local/bin/restored_external work/restored_external
        "$dir"/restored_external64_patcher work/restored_external work/patched_restored_external
        "$dir"/ldid -e work/restored_external > work/restored_external.plist
        "$dir"/ldid -Swork/restored_external.plist work/patched_restored_external
        chmod 755 work/patched_restored_external

        rm $mounted/usr/sbin/asr
        rm $mounted/usr/local/bin/restored_external
        
        mv work/patched_asr $mounted/usr/sbin/asr
        mv work/patched_restored_external $mounted/usr/local/bin/restored_external

        hdiutil detach -force /tmp/SSHRD
        hdiutil resize -sectors min work/ramdisk.dmg
    else
        "$dir"/hfsplus work/ramdisk.dmg grow 210000000 > /dev/null
        "$dir"/hfsplus work/ramdisk.dmg extract /usr/sbin/asr work/asr
        "$dir"/asr64_patcher work/asr work/patched_asr
        "$dir"/ldid -e work/asr > work/asr.plist
        "$dir"/ldid -Swork/asr.plist work/patched_asr
        chmod 755 work/patched_asr

        "$dir"/hfsplus work/ramdisk.dmg extract /usr/local/bin/restored_external work/restored_external
        "$dir"/restored_external64_patcher work/restored_external work/patched_restored_external
        "$dir"/ldid -e work/restored_external > work/restored_external.plist
        "$dir"/ldid -Swork/restored_external.plist work/patched_restored_external
        chmod 755 work/patched_restored_external

        "$dir"/hfsplus work/ramdisk.dmg rm /usr/sbin/asr
        "$dir"/hfsplus work/ramdisk.dmg rm /usr/local/bin/restored_external
        
        "$dir"/hfsplus work/ramdisk.dmg add work/patched_asr /usr/sbin/asr
        "$dir"/hfsplus work/ramdisk.dmg add work/patched_restored_external /usr/local/bin/restored_external
    fi

    python3 -m pyimg4 im4p create -i work/ramdisk.dmg -o work/rdsk.im4p -f rdsk

    cp -rv work/*.img4 "boot/${deviceid}" # copying all file img4 to boot

    echo "boot files created now we will downgrade"
    _runFuturerestore
    sleep 1
    echo "finished to downgrade now you can boot using  --boot"
fi


} 2>&1 | tee logs/${log}