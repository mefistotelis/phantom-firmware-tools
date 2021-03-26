#!/bin/bash
# -*- coding: utf-8 -*-

# Copyright (C) 2016,2017 Mefistotelis <mefistotelis@gmail.com>
# Copyright (C) 2018 Original Gangsters <https://dji-rev.slack.com/>
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <http://www.gnu.org/licenses/>.

SKIP_EXTRACT=0
SKIP_REPACK=0
SKIP_CLEANUP=0
SKIP_COMPARE=0

if [ "$#" -lt "1" ]; then
    echo '### FAIL: No bin file name provided! ###'
    exit 4
fi

while [ "$#" -gt "0" ]
do
key="$1"

case $key in
  -se|--skip-extract)
    SKIP_EXTRACT=1
    ;;
  -sp|--skip-repack)
    SKIP_REPACK=1
    ;;
  -sn|--skip-cleanup)
    SKIP_CLEANUP=1
    ;;
  -sc|--skip-compare)
    SKIP_COMPARE=1
    ;;
  -on|--only-cleanup)
    SKIP_EXTRACT=1
    SKIP_REPACK=1
    SKIP_COMPARE=1
    ;;
  *)
    BINFILE="$key"
    ;;
esac
shift # past argument or value
done

if [ ! -f "${BINFILE}" ]; then
    echo '### FAIL: Input file not foumd! ###'
    echo "### INFO: Expected file \"${BINFILE}\" ###"
    exit 3
fi

TESTFILE="${BINFILE%.*}-test.sig"
HAS_0305=
HAS_0306=

if [ "${SKIP_COMPARE}" -le "0" ]; then
  echo '### TEST for dji_imah_fwsig.py and dji_mvfc_fwpak.py re-creation of binary file ###'
  # The test extracts firmware module from signed (and often encrypted)
  # DJI IMaH format, and then repacks it.
  # The test ends with success if the resulting BIN file is
  # exactly the same as input BIN file.
fi

if [ "${SKIP_EXTRACT}" -le "0" ]; then
  echo "### INFO: Input file \"${BINFILE}\" ###"
  # Remove files which will be created
  rm ${TESTFILE%.*}_*.bin ${TESTFILE%.*}_*.ini 2>/dev/null
  # Unsign/decrypt the module
  ./dji_imah_fwsig.py -vv -u -i "${BINFILE}" -m "${TESTFILE%.*}"
  # Some modules have another stage of encryption
  HAS_0305=$(grep '^modules=\([0-9]\{4\}[ ]\)*0305' "${TESTFILE%.*}_head.ini" | head -n 1)
  HAS_0306=$(grep '^modules=\([0-9]\{4\}[ ]\)*0306' "${TESTFILE%.*}_head.ini" | head -n 1)
  if [ ! -z "${HAS_0305}" ]; then
    MODULE="0305"
    echo "### INFO: Found m${MODULE} inside, doing 2nd stage decrypt ###"
    ./dji_mvfc_fwpak.py dec -i "${TESTFILE%.*}_${MODULE}.bin" | tee "${TESTFILE%.*}_${MODULE}.log"
  fi
  if [ ! -z "${HAS_0306}" ]; then
    MODULE="0306"
    echo "### INFO: Found m${MODULE} inside, doing 2nd stage decrypt ###"
    ./dji_mvfc_fwpak.py dec -i "${TESTFILE%.*}_${MODULE}.bin" | tee "${TESTFILE%.*}_${MODULE}.log"
  fi
fi

if [ "${SKIP_REPACK}" -le "0" ]; then
  # Remove file which will be created
  if [ ! -z "${HAS_0305}" ]; then
    rm "${TESTFILE%.*}_0305.bin" 2>/dev/null
  fi
  if [ ! -z "${HAS_0306}" ]; then
    rm "${TESTFILE%.*}_0306.bin" 2>/dev/null
  fi
  rm "${TESTFILE}" 2>/dev/null
  # We do not have private parts of auth keys used for signing - use OG community key instead
  # Different signature means we will get up to 256 different bytes in the resulting file
  sed -i "s/^auth_key=[0-9A-Za-z]\{4\}$/auth_key=SLAK/" "${TESTFILE%.*}_head.ini"
  # Encrypt and sign back to final format
  if [ ! -z "${HAS_0305}" ]; then
    MODULE="0305"
    MOD_FWVER=$(sed    -n "s/^Version:[ \t]*\([0-9A-Za-z. :_-]*\)$/\1/p" "${TESTFILE%.*}_${MODULE}.log" | head -n 1)
    MOD_TMSTAMP=$(sed  -n "s/^Time:[ \t]*\([0-9A-Za-z. :_-]*\)$/\1/p"     "${TESTFILE%.*}_${MODULE}.log" | head -n 1)
    ./dji_mvfc_fwpak.py enc -V "${MOD_FWVER}" -T "${MOD_TMSTAMP}" -t "${MODULE}" -i "${TESTFILE%.*}_${MODULE}.decrypted.bin"
  fi
  if [ ! -z "${HAS_0306}" ]; then
    MODULE="0306"
    MOD_FWVER=$(sed    -n "s/^Version:[ \t]*\([0-9A-Za-z. :_-]*\)$/\1/p" "${TESTFILE%.*}_${MODULE}.log" | head -n 1)
    MOD_TMSTAMP=$(sed  -n "s/^Time:[ \t]*\([0-9A-Za-z. :_-]*\)$/\1/p"     "${TESTFILE%.*}_${MODULE}.log" | head -n 1)
    ./dji_mvfc_fwpak.py enc -V "${MOD_FWVER}" -T "${MOD_TMSTAMP}" -t "${MODULE}" -i "${TESTFILE%.*}_${MODULE}.decrypted.bin"
  fi
  ./dji_imah_fwsig.py -vv -s -i "${TESTFILE}"
fi

if [ "${SKIP_COMPARE}" -le "0" ]; then
  # Compare converted with original
  TEST_RESULT=$(cmp -l "${BINFILE}" "${TESTFILE}" | wc -l)
fi

if [ "${SKIP_CLEANUP}" -le "0" ]; then
  # Cleanup
  rm "${TESTFILE}" ${TESTFILE%.*}_*.bin ${TESTFILE%.*}_*.ini
fi

if [ "${SKIP_COMPARE}" -le "0" ]; then
  if [ ${TEST_RESULT} == 0 ]; then
    echo '### SUCCESS: File identical after conversion. ###'
  elif [ ${TEST_RESULT} -le 256 ]; then
    echo '### SUCCESS: File matches, except signature. ###'
  elif [ ! -s "${TESTFILE}" ]; then
    echo '### FAIL: File empty or missing; creation faled! ###'
    exit 2
  else
    echo '### FAIL: File changed during conversion! ###'
    exit 1
  fi
fi

exit 0
