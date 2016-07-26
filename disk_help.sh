#!/usr/bin/bash
#
# CDDL HEADER START
#
# The contents of this file are subject to the terms of the
# Common Development and Distribution License, Version 1.0 only
# (the "License").  You may not use this file except in compliance
# with the License.
#
# You can obtain a copy of the license at usr/src/OPENSOLARIS.LICENSE
# or http://www.opensolaris.org/os/licensing.
# See the License for the specific language governing permissions
# and limitations under the License.
#
# When distributing Covered Code, include this CDDL HEADER in each
# file and include the License file at usr/src/OPENSOLARIS.LICENSE.
# If applicable, add the following below this CDDL HEADER, with the
# fields enclosed by brackets "[]" replaced with your own identifying
# information: Portions Copyright [yyyy] [name of copyright owner]
#
# CDDL HEADER END
#
#
# Copyright 2012 OmniTI Computer Consulting, Inc.  All rights reserved.
# Use is subject to license terms.
#
ListDisks() {
  declare -A disksize
  declare -A diskname
  for rdsk in $(prtconf -v | grep dev_link | awk -F= '/\/dev\/rdsk\/c.*p0/{print $2;}')
  do
    disk=`echo $rdsk | sed -e 's/.*\///g; s/p0//;'`
    size=`prtvtoc $rdsk 2>/dev/null | awk '/bytes\/sector/{bps=$2} /sectors\/cylinder/{bpc=bps*$2} /accessible sectors/{print ($2*bps)/1048576;} /accessible cylinders/{print int(($2*bpc)/1048576);}'`
    disksize+=([$disk]=$size)
  done

  disk=""
  while builtin read diskline
  do
    if [[ -n "$disk" ]]; then
      desc=`echo $diskline | sed -e 's/^[^\<]*//; s/[\<\>]//g;'`
      diskname+=([$disk]=$desc)
      disk=""
    else
      disk=$diskline
    fi
  done < <(format < /dev/null | awk '/^ *[0-9]*\. /{print $2; print;}')

  for want in $*
  do
    for disk in "${!disksize[@]}" ; do
      case "$want" in
        \>*)
            if [[ -n ${disksize[$disk]} && "${disksize[$disk]}" -ge "${want:1}" ]]; then
              echo $disk
            fi
          ;;
        \<*)
            if [[ -n ${disksize[$disk]} && "${disksize[$disk]}" -le "${want:1}" ]]; then
              echo $disk
            fi
          ;;
        *)
          if [[ "$disk" == "$want" ]]; then
            echo $disk
          fi
          ;;
      esac
    done

    for disk in "${!diskname[@]}" ; do
      case "$want" in
        ~*)
          PAT=${want:1}
          if [[ -n $(echo ${diskname[$disk]} | egrep -e "$PAT") ]]; then
            echo $disk
          fi
          ;;
      esac
    done
  done
}
ListDisksAnd() {
  EXPECT=$(( $(echo "$1" | sed -e 's/[^,]//g;' | wc -c) + 0))
  for part in $(echo "$1" | sed -e 's/,/ /g;'); do
    ListDisks $part
  done | sort | uniq -c | awk '{if($1=='$EXPECT'){print $2;}}'
}
ListDisksUnique(){
  for term in $*; do
    ListDisksAnd $term
  done | sort | uniq | xargs
}
SMIboot() {
  DISK=$1
  RDSK=/dev/rdsk/${DISK}p0
  S2=/dev/rdsk/${DISK}s2
  fdisk -B ${RDSK}
  disks -C
  prtvtoc -h ${RDSK} | awk '/./{p=0;} {if($1=="2"){size=$5;p=1;} if($1=="8"){start=$5;p=1;} if(p==1){print $1" "$2" "$3" "$4" "$5;}} END{size=size-start; print "0 2 00 "start" "size;}' | sort -n | fmthard -s /dev/stdin $S2
  disks -C
}

BuildRpool() {
  if [[ "$1" !=  "use_existing"  ]]; then
    ztype=""
    ztgt=""
    disks=`ListDisksUnique $*`
    log "Disks being used for rpool: $disks"
    if [[ -z "$disks" ]]; then
      bomb "No matching disks found to build rpool"
    fi
    for i in $disks
    do
      SMIboot $i
      if [[ -n "$ztgt" ]]; then
        ztype="mirror"
      fi
      ztgt="$ztgt ${i}s0"
      INSTALL_GRUB_TGT="$INSTALL_GRUB_TGT /dev/rsdk/${i}s2"
    done
    log "zpool destroy rpool (just in case we've been run twice)"
    zpool destroy rpool 2> /dev/null
    log "Creating rpool with: zpool create -f rpool $ztype $ztgt"
    zpool create -f rpool $ztype $ztgt || bomb "Failed to create rpool"
  else
    log "Importing existing rpool"
    zpool import -f rpool
  fi

  BuildBE
}
GetTargetVolSize() {
    # Aim for 25% of physical memory (minimum 1G)
    # prtconf always reports in megabytes
    local mem=`/usr/sbin/prtconf | /bin/awk '/^Memory size/ { print $3 }'`
    if [[ $mem -lt 4096 ]]; then
        local vsize=1
    else
        local quart=`echo "scale=1;$mem/4096" | /bin/bc`
        local vsize=`printf %0.f $quart`
    fi
    echo $vsize
}
GetRpoolFree() {
    local zfsavail=`/sbin/zfs list -H -o avail rpool`
    if [[ ${zfsavail:(-1)} = "G" ]]; then
        local avail=`printf %0.f ${zfsavail::-1}`
    elif [[ ${zfsavail:(-1)} = "T" ]]; then
        local gigs=`echo "scale=1;${zfsavail::-1}*1024" | /bin/bc`
        avail=`printf %0.f $gigs`
    else
        # If we get here, there's too little space left to be usable
        avail=0
    fi
    echo $avail
}
MakeSwapDump() {
    local size=`GetTargetVolSize`
    local totalvols=""
    local usable=""
    local finalsize=""
    local savecore=""

    # We're creating both swap and dump volumes of the same size
    let totalvols=${size}*2

    # We want at least 10GB left free after swap/dump
    # If we can't make swap/dump at least 1G each, don't bother
    let usable=`GetRpoolFree`-10
    if [[ $usable -lt 2 ]]; then
        log "Not enough free space for reasonably-sized swap and dump; not creating either."
        return 0
    fi

    # If the total of swap and dump is greater than the usable free space,
    # make swap and dump each take half but don't enable savecore
    if [[ $totalvols -ge $usable ]]; then
        let finalsize=${usable}/2
        savecore="-n"
    else
        finalsize=$size
        savecore="-y"
    fi

    for volname in swap dump; do
        /sbin/zfs create -V ${finalsize}G rpool/$volname || \
            bomb "Failed to create rpool/$volname"
    done
    printf "/dev/zvol/dsk/rpool/swap\t-\t-\tswap\t-\tno\t-\n" >> $ALTROOT/etc/vfstab
    Postboot /usr/sbin/dumpadm $savecore -d /dev/zvol/dsk/rpool/dump
    return 0
}
