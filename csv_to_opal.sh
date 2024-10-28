#!/bin/bash

# Mini mouse helper script to format CSV into valid Opal so that an export of a certain dataset can easily
# be imported by another person in an unrelated environment - often for reproducing UI/graphing issues
#                                                                               ran 2024-10-21
# Made all command line inputs optional and added a sanity check
#                                                                               ran 2024-10-28

#
# output the stdin (assumed to be a CSV) with the named column numbers having their '"' stripped and a few other changes...
# e.g.
# cat <CSV file> | /bin/bash csv_to_opal.sh -x 5 -d 1,2,4 -l 1:vf,2:vt,4:last -t 1:from_nanoseconds,from_nanoseconds,string,int64,int64
# this will:
# - drop input column 5 (starting from 1)
# - output the same CSV field with numbered columns (counting from 1) stripped of double-quotes (")
# - replaces output column labels 1 with "vf", 2 with "vt", 4 with "last" and the others remain as in CSV header row
# - adds type conversion functions to columns either in input order or with colon ':' column number prefix
# So with <CSV file>:
# "_c_valid_from","_c_valid_to","url","A_http_status_category_int_last","_c_bucket"
# "1729531200000000000","1729531500000000000","https://staging.site-dr.com/","0","5765104"
# "1729531200000000000","1729531500000000000","https://staging.site-dr.com/preapproval/nxt-purchase","0","5765104"
#
# outputs:
# filter false | statsby count(), group_by()
# make_col foo:parse_json(concat_strings('['
# ,',{"vf":1729531200000000000,"vt":1729531500000000000,"url":"https://staging.site-dr.com/","last":0}'
# ,',{"vf":1729531200000000000,"vt":1729531500000000000,"url":"https://staging.site-dr.com/preapproval/nxt-purchase","last":0}'
# , ']'))
# flatten_single foo
# pick_col vf:from_nanoseconds(_c_foo_value.vf),vt:from_nanoseconds(_c_foo_value.vt),url:string(_c_foo_value.url),last:int64(_c_foo_value.last)

#
# Improved performance via compiling to AWK script instead of using a shell loop over the 5000-10000 input rows
#

PROGNAME=${0##*/}
STEMNAME=${PROGNAME%%.*}
declare -A DROPCOLS
declare -a DEQUOTES
declare -A LABELS
declare -A TYPES
USAGESTR="Usage:
$PROGNAME
        [-x <input columns numbers to drop>]                    # comma separated
        [-d <input column numbers to dequote>]                  # comma separated
        [-l <column labels to use instead of header row>]       # comma separated or colon indexed e.g. 1:vf,4:last
        [-t <Opal type conversion functions per input col>]     # comma separated or colon indexed 3:int64 - default: string()"

#  err "some message" [optional return code]
function err {
   local exitcode=${2:-1}                               # default to exit 1
   local c=($(caller 0))                                        # who called me?
   local r="${c[2]} (f=${c[1]},l=${c[0]})"                       # where in code?

   echo "ERROR: $r failed: $1" 1>&2

   exit $exitcode
}
function warn {
   echo "WARN: $1" 1>&2
}
function info {
   echo "INFO: $1" 1>&2
}

function get_format {
   # Given an input column number (starting from 1) return 's' or 'd' depending on whether an AWK 
   # format needs to format as %s or %d.
   # Currently simply return 'd' if: TYPES[i] in ('int64','from_seconds','from_nanoseconds','from_milliseconds')
   # else return 's'
   #
   # ASSUMES: 1) that it's impossible to be given a column that is to be skipped in the output
   (( $# == 1 )) || err "Usage: ${FUNCNAME[0]} <input column number starting from 1>"
   local -i colno=$1 
   local in_t="${TYPES[$colno]}"
   if [[ "$in_t" == "int64" || "$in_t" == "from_seconds" || "$in_t" == "from_nanoseconds" || "$in_t" == "from_milliseconds" ]] ; then
        echo -n 'd'
   else
        echo -n 's'
   fi
}

while getopts ":x:d:l:t:D" OPT ; do
	case $OPT in
		x  )	unset DROPCOLS; declare -A DROPCOLS
                        unset _tarr; declare -a _tarr
                        IFS=, read -a _tarr <<< "$OPTARG"
                        # create associative array with a key value per input column to be dropped
                        for i in ${_tarr[*]} ; do 
                                DROPCOLS[$i]=1
                        done
                        [[ -n "$DEBUG" ]] && warn "Cmd line DROPCOLS = $(declare -p DROPCOLS)"
			;;
		d  ) 	unset DEQUOTES; declare -a DEQUOTES
                        unset _tarr; declare -a _tarr
                        IFS=, read -a _tarr <<< "$OPTARG"
                        # create associative array with a key value per input column to be unquoted
                        for i in ${_tarr[*]} ; do
                                DEQUOTES[$i]=1
                        done
                        [[ -n "$DEBUG" ]] && warn "Cmd line DEQUOTES = $(declare -p DEQUOTES)"
			;;
		l  )	unset LABELS; declare -A LABELS
                        unset _tarr; declare -a _tarr
                        unset _idx; declare -i _idx=1
                        IFS=, read -a _tarr <<< "$OPTARG"
                        for i in ${_tarr[*]} ; do
                                if [[ "${i%:*}" == "$i" ]] ; then       # no ':' index found
                                        LABELS[${_idx}]=$i
                                else
                                        LABELS[${i%:*}]=${i#*:}
                                fi
                                _idx+=1
                        done
                        [[ -n "$DEBUG" ]] && warn "Cmd line LABELS = $(declare -p LABELS)"
			;;
		t  )    unset TYPES; declare -A TYPES
                        unset _tarr; declare -a _tarr
                        unset _idx; declare -i _idx=1
                        IFS=, read -a _tarr <<< "$OPTARG"
                        for i in ${_tarr[*]} ; do
                                if [[ "${i%:*}" == "$i" ]] ; then       # no ':' index found
                                        TYPES[${_idx}]=$i
                                else
                                        TYPES[${i%:*}]=${i#*:}
                                fi
                                _idx+=1
                        done
                        [[ -n "$DEBUG" ]] && warn "Cmd line TYPES = $(declare -p TYPES)"
			;;
                D  )    DEBUG=true
                        set -vx
                        ;;
		:  )	err "option '$OPTARG' requires a value"$'\n'"$USAGESTR"
			;;
		\? )	err "invalid option '$OPTARG'"$'\n'"$USAGESTR"
			;;
	esac
done
shift $(( $OPTIND - 1 ))

#
# fill in any missing LABELS values with default column names from CSV header row
#
unset _tarr; declare -a _tarr
unset _idx; declare -i _idx=1
IFS=, read -a _tarr 
for i in ${_tarr[*]} ; do
        [[ -n "${LABELS[$_idx]}" ]] || LABELS[$_idx]=${i//\"}           # keep existing value or assign with embedded quotes removed
        _idx+=1 
done

[[ -n "$DEBUG" ]] && warn "LABELS = $(declare -p LABELS)"

NUM_INPUT_COLS=$(( _idx - 1 ))
#
# fill in any missing TYPES type cast Opal function names - index is 1 based and same as original input column numbers (prior to any dropping of columns)
#
for (( i=1; i<=$NUM_INPUT_COLS; i+=1 )) ; do
        [[ -n "${TYPES[$i]}" ]] || TYPES[$i]='string'
done

[[ -n "$DEBUG" ]] && warn "TYPES = $(declare -p TYPES)"

#
# catch some error conditions
#
(( ${#DROPCOLS[@]} < $NUM_INPUT_COLS )) || err "too many columns have been dropped. No work to do!"

#
# Compile args into a GAWK control string
#
unset dequote_awk; declare -a dequote_awk
unset format_awk; declare -a format_awk
unset args_awk; declare -a args_awk
for i in $(IFS=$'\n'; sort -n <<< "${!LABELS[*]}"); do
        [[ -n "${DROPCOLS[$i]}" ]] && continue                          # skip columns marked for dropping
        [[ -n "${DEQUOTES[$i]}" ]] && dequote_awk+=("c${i}=gensub(/\"/,\"\",\"g\",\$${i})")
        format_awk+=("\\\"${LABELS[$i]}\\\":%$(get_format $i)")
        if [[ -n "${DEQUOTES[$i]}" ]] ; then
                args_awk+=("c$i")
        else
                args_awk+=("\$$i")
        fi
done

#
# Emit initial Opal
#
echo "filter false | statsby count(), group_by()"$'\n'"make_col foo:parse_json(concat_strings('['"

GCMD="{$(IFS=\;; echo "${dequote_awk[*]}"); printf(\"\t,"\'",{$(IFS=,; echo "${format_awk[*]}")}"\'"\\n\",$(IFS=,; echo "${args_awk[*]}"))}"
gawk -F, "$GCMD"

# 
# Add trailing text to STDOUT
#
echo -n $'\t'", ']'))"$'\n'"flatten_single foo"$'\n'"pick_col "
unset _tarr; declare -a _tarr
for i in $(IFS=$'\n'; sort -n <<< "${!LABELS[*]}"); do                  # output Opal cols in LABELS order
        [[ -n "${DROPCOLS[$i]}" ]] && continue                          # skip columns marked for dropping
        _tarr+=("${LABELS[$i]}:${TYPES[$i]}(_c_foo_value.${LABELS[$i]})")
done
echo "$(IFS=,; echo "${_tarr[*]}")"
