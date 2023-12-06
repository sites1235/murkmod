#!/bin/bash

run_plugin() {
    local script=$1
    while true; do
        bash "$script"
    done & disown
}

get_largest_nvme_namespace() {
    # this function doesn't exist if the version is old enough, so we redefine it
    local largest size tmp_size dev
    size=0
    dev=$(basename "$1")

    for nvme in /sys/block/"${dev%n*}"*; do
        tmp_size=$(cat "${nvme}"/size)
        if [ "${tmp_size}" -gt "${size}" ]; then
            largest="${nvme##*/}"
            size="${tmp_size}"
        fi
    done
    echo "${largest}"
}

doas() {
    ssh -t -p 1337 -i /rootkey -oStrictHostKeyChecking=no root@127.0.0.1 "$@"
}

lsbval() {
  local key="$1"
  local lsbfile="${2:-/etc/lsb-release}"

  if ! echo "${key}" | grep -Eq '^[a-zA-Z0-9_]+$'; then
    return 1
  fi

  sed -E -n -e \
    "/^[[:space:]]*${key}[[:space:]]*=/{
      s:^[^=]+=[[:space:]]*::
      s:[[:space:]]+$::
      p
    }" "${lsbfile}"
}

get_booted_kernnum() {
    if doas "((\$(cgpt show -n \"$dst\" -i 2 -P) > \$(cgpt show -n \"$dst\" -i 4 -P)))"; then
        echo -n 2
    else
        echo -n 4
    fi
}

opposite_num() {
    if [ "$1" == "2" ]; then
        echo -n 4
    elif [ "$1" == "4" ]; then
        echo -n 2
    elif [ "$1" == "3" ]; then
        echo -n 5
    elif [ "$1" == "5" ]; then
        echo -n 3
    else
        return 1
    fi
}

{
    until tpm_manager_client take_ownership; do
        echo "Failed to take ownership of TPM!"
        sleep 0.5
    done

    {
        launch_racer(){
            echo launching racer at "$(date)"
            {
                while true; do
                    cryptohome --action=remove_firmware_management_parameters >/dev/null 2>&1
                done
            } &
            RACERPID=$!
        }
        launch_racer
        while true; do
            echo "checking cryptohome status"
            if [ "$(cryptohome --action=is_mounted)" == "true" ]; then
                if ! [ -z $RACERPID ]; then
                    echo "Logged in, waiting to kill racer..."
                    sleep 60
                    kill -9 $RACERPID
                    echo "Racer terminated at $(date)"
                    RACERPID=
                fi
            else
                if [ -z $RACERPID ]; then 
                    launch_racer
                fi
            fi
            sleep 10
        done
    } &

    {
        while true; do
            vpd -i RW_VPD -s check_enrollment=0 >/dev/null 2>&1
            vpd -i RW_VPD -s block_devmode=0 >/dev/null 2>&1
            crossystem.old block_devmode=0 >/dev/null 2>&1
            sleep 15
        done
    } &
} &

{
    while true; do
        if test -d "/home/chronos/user/Downloads/disable-extensions"; then
            kill -9 $(pgrep -f "\-\-extension\-process") 2>/dev/null
            sleep 0.5
        else
            sleep 5
        fi
    done
} &


{
    while true; do
        if test -d "/home/chronos/user/Downloads/fix-mush"; then

            cat << 'EOF' > /usr/bin/crosh
mush_info() {
    echo "This is an emergency backup shell! If you triggered this accidentally, type the following command at the prompt:"
    echo "bash <(curl -SLk https://raw.githubusercontent.com/rainestorme/murkmod/main/murkmod.sh)"
}

doas() {
    ssh -t -p 1337 -i /rootkey -oStrictHostKeyChecking=no root@127.0.0.1 "$@"
}

runjob() {
    trap 'kill -2 $! >/dev/null 2>&1' INT
    (
        # shellcheck disable=SC2068
        $@
    )
    trap '' INT
}

mush_info
runjob doas "bash"
EOF

            sleep 10
        else
            sleep 5
        fi
    done
} &

{
    # technically this should go in chromeos_startup.sh but it would slow down the boot process
    echo "Waiting for boot on emergency restore (just in case)"
    sleep 60
    echo "Checking for restore flag..."
    if [ -f /mnt/stateful_partition/restore-emergency-backup ]; then
        echo "Restore flag found!"
        echo "Looking for backup files..."
        dst=/dev/$(get_largest_nvme_namespace)
        tgt_kern=$(opposite_num $(get_booted_kernnum))
        tgt_root=$(( $tgt_kern + 1 ))

        kerndev=${dst}p${tgt_kern}
        rootdev=${dst}p${tgt_root}

        if [ -f /mnt/stateful_partition/murkmod/kern_backup.img ] && [ -f /mnt/stateful_partition/murkmod/root_backup.img ]; then
            echo "Backup files found!"
            echo "Restoring kernel..."
            dd if=/mnt/stateful_partition/murkmod/kern_backup.img of=$kerndev bs=4M status=progress
            echo "Restoring rootfs..."
            dd if=/mnt/stateful_partition/murkmod/root_backup.img of=$rootdev bs=4M status=progress
            echo "Removing restore flag..."
            rm /restore-emergency-backup
            echo "Removing backup files..."
            rm /mnt/stateful_partition/murkmod/kern_backup.img
            rm /mnt/stateful_partition/murkmod/root_backup.img
            echo "Restored successfully!"
        else
            echo "Missing backup image, removing restore flag and aborting!"
            rm /restore-emergency-backup
        fi
    else 
        echo "No need to restore."
    fi
} &

{
    echo "Waiting for boot on daemon plugins (also just in case)"
    sleep 60
    echo "Finding daemon plugins..."
    for file in /mnt/stateful_partition/murkmod/plugins/*.sh; do
        if grep -q "daemon_plugin" "$file"; then
            echo "Spawning plugin $file..."
            run_plugin $file
        fi
    done
} &

{
    echo "Running bootsplash..."
    BACKGROUND=0xfffefefe
    ARGS="--frame-interval 25"
    BOOT_IMAGES=/usr/share/chromeos-assets/images_100_percent/boot_splash_frame*.png
    /sbin/frecon --clear "${BACKGROUND}" ${ARGS} ${BOOT_IMAGES}
    touch /bootsplash-complete
    echo "Bootsplash complete."
} &
