#!/bin/bash

(( BASH_VERSINFO[0] >= 5 )) || \
        {
                printf "%s\n" "Bash 5.0+ is required" 1>&2
                exit 255
        }

[[ -v __LIBSTD_BASH__ ]] && return 0

declare -- __LIBSTD_BASH__='1'

set   -o pipefail
set   -o nounset
shopt -s extglob
shopt -s nullglob
shopt -s expand_aliases

##
## std::{log,info,error,debug} - Write a message to stderr
##
## Arguments:
##   $1 - [in] printf format string
##   ${@:2} - [in] Message content
##
## Returns:
##   exit code of printf
##
## Usage:
##   std::info "%s" "This is a message"
##
std::log() {
        (( $# < 2 )) && \
                std::die 255 "Wrong number of arguments in call to std::log!"
        local -ri fd="$1"
        local -r fmt="$2"
        shift 2
        printf -- "${fmt}" "$@" 1>&$fd
        printf -- '\n' 1>&$fd
}
readonly -f std::log

std::info() {
        std::log 2 "$1" "${@:2}"
}
readonly -f std::info

std::error() {
        std::log 2 "$1" "${@:2}"
}
readonly -f std::error

std::debug() {
        [[ -v PMODULES_DEBUG ]] || return 0
        std::log 2 "$1" "${@:2}"
}
readonly -f std::debug

##
## std::die - Write a message to stdout/stderr and exits program
##
## Arguments:
##   $1 - [in] exit code
##   $2 - [in] optional printf format string
##   ${@:3} [in] optional message content
##
## Usage:
##   std::die 2 "%s" "Invalid option -- foo"
##
std::die() {
        local -ri ec="$1"
        shift
        if (( $# > 0 )); then
                local -r fmt="$1"
                shift
                std::log 2 "${fmt}" "$@"
        fi
        exit "$ec"
}
readonly -f std::die

##
## std::{def_cmd,def_cmd2} - Define function for used system tools.
##
## While building a module the PATH variable can change. With these
## functions we stick a system binary to a certain path. The function
## std::def_cmd2 unsets LD_PRELOAD to prevent code injection.
##
## If a binary is not in PATH, the function terminates the program.
##
## TODO:
## For most tools LD_LIBRARY_PATH should be unset.
## Exceptions: modulecmd, make
##
## Arguments:
##   $1 - [in] system tool
##
## Globals:
##   PATH
##
## Usage:
##   std::def_cmd2 'ls'
##
std::def_cmd(){
        local -r name="$1"
        [[ ${name} =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || \
                std::die 255 "Invalid function name: '${name}'"
        local -- bin=''
        bin=$(command -v "$1") || std::die 255 "'${name}' not found!"

        alias "${name}"="${bin}"
}
readonly -f std::def_cmd

std::def_cmd2(){
        local -r name="$1"
        [[ ${name} =~ ^[a-zA-Z_][a-zA-Z0-9_]*$ ]] || \
                std::die 255 "Invalid function name: '${name}'"
        local -- bin=''
        bin=$(command -v "$1") || std::die 255 "'${name}' not found!"

        alias "${name}"="LD_PRELOAD= ${bin}"
}
readonly -f std::def_cmd2

declare -rg KERNEL_NAME="$(uname -s)"
declare -rg SYSTEM_CPU="$(uname -m)"

case ${KERNEL_NAME} in
        Darwin )
                PATH+=':/opt/local/bin:/usr/local/bin'
		;;
esac

#
# Since we are using aliases, we have to define some before using them in a function.
# Alias expansion happens when a function is parsed!
##
std::def_cmd2 'awk'
std::def_cmd2 'base64'
std::def_cmd2 'basename'
std::def_cmd2 'bash'
std::def_cmd2 'cat'
std::def_cmd2 'cp'
std::def_cmd2 'curl'
std::def_cmd2 'envsubst'
std::def_cmd2 'date'
std::def_cmd2 'dirname'
std::def_cmd2 'file'
std::def_cmd2 'find'
std::def_cmd2 'getopt'
std::def_cmd2 'grep'
std::def_cmd2 'hostname'
std::def_cmd2 'id'
std::def_cmd2 'install'
std::def_cmd2 'ln'
std::def_cmd2 'logger'
std::def_cmd2 'make'
std::def_cmd2 'md5sum'
std::def_cmd2 'mkdir'
std::def_cmd2 'mktemp'
std::def_cmd2 'mv'
std::def_cmd2 'patch'
std::def_cmd2 'readlink'
std::def_cmd2 'rm'
std::def_cmd2 'rmdir'
std::def_cmd2 'sed'
std::def_cmd2 'seq'
std::def_cmd2 'sort'
std::def_cmd2 'stat'
std::def_cmd2 'tar'
std::def_cmd2 'tee'
std::def_cmd2 'touch'
std::def_cmd2 'tput'
std::def_cmd2 'uname'
std::def_cmd2 'yq'

case ${KERNEL_NAME} in
        Linux )
                std::def_cmd2 'ldd'
                std::def_cmd2 'patchelf'
                std::def_cmd2 'sha256sum'
                ;;
        Darwin )
                std::def_cmd2 'otool'
                std::def_cmd2 'shasum'
                std::def_cmd2 'sysctl'
                sha256sum(){
                        shasum -a 256 "$@"
                }
                ;;
        * )
                std::die 255 "Unsupported kernel - ${KERNEL_NAME}"
                ;;
esac

##
## std::is_uint() - check whether argument is an integer
##
## Arguments:
##   $1 - string to test
##
## Returns:
##   0 - if string is an unsigned int
##   1 - otherwise
##
std::is_uint() {
        [[ $1 =~ ^[0-9]+$ ]]
}
readonly -f std::is_uint

##
## std::version_{compare,lt,le,eq,ge,gt} - Compare two version numbers.
##
## Arguments:
##   $1 - [in] first version number
##   $2 - [in] optional second version number, if not set V_PKG is used
##
## Returns:
##     std::version_compare
##         0 if the version numbers are equal
##         1 if first version number is higher
##         2 if second version number is higher
##
##    std::version_lt
##        0 if second version number is higher, otherwise 1
##    std::version_le
##        0 if second version number is higher or equal, otherwise 1
##    std::version_gt
##        0 if first version number is higher, otherwise 1
##    std::version_ge
##        0 if first version number is higher or equal, otherwise 1
##
## Globals:
##    V_PKG (used if second version number is missing)
## Note:
#       Original implementation found on stackoverflow:
# https://stackoverflow.com/questions/4023830/how-to-compare-two-strings-in-dot-separated-version-format-in-bash
#
std::version_compare () {
        [[  $# -eq 2 && "$1" == "$2" ]] && return 0

        local -a ver1 ver2
        if (( $# == 2 )); then
                IFS='.' read -r -a ver1 <<<"$1"
                IFS='.' read -r -a ver2 <<<"$2"
        elif [[ $# == 1 && -v V_PKG ]]; then
                IFS='.' read -r -a ver1 <<<"$1"
                IFS='.' read -r -a ver2 <<<"${V_PKG}"
        else
                std::die 3 "Oops: '${FUNCNAME[0]}' called with wrong number of args!"
        fi

        # fill empty fields in ver1 with zeros
        local -i i=0
        for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
                ver1[i]=0
        done
        for ((i=0; i<${#ver1[@]}; i++)); do
                [[ -v ver2[i] ]] || ver2[i]=0
                if std::is_uint "${ver1[i]}" && std::is_uint "${ver2[i]}"; then
                        ((10#${ver1[i]} > 10#${ver2[i]})) && return 1
                        ((10#${ver1[i]} < 10#${ver2[i]})) && return 2
                else
                        [[ ${ver1[i]} > ${ver2[i]} ]] && return 1
                        [[ ${ver1[i]} < ${ver2[i]} ]] && return 2
                fi
        done
        return 0
}
readonly -f std::version_compare

std::version_lt() {
        std::version_compare "$@"
        (( $? == 2 ))
}
readonly -f std::version_lt

std::version_le() {
        std::version_compare "$@"
        local -i exit_code=$?
        (( exit_code == 0 || exit_code == 2 ))
}
readonly -f std::version_le

std::version_gt() {
        std::version_compare "$@"
        (( $? == 1 ))
}
readonly -f std::version_gt

std::version_ge() {
        std::version_compare "$@"
        local -i exit_code=$?
        (( exit_code == 0 || exit_code == 1 ))
}
readonly -f std::version_ge

std::version_eq() {
        std::version_compare "$@"
}
readonly -f std::version_eq

##
## std::get_YN_answer - Get answer to yes/no question.
##
## Arguments:
##   $1 - [in] prompt
##
## Returns:
##   0 - answer was yes
##   1 - otherwise
##
std::get_YN_answer() {
        local -r prompt="$1"
        local -- ans
        read -r -p "${prompt}" ans
        case ${ans} in
                y|Y )
                        return 0;;
                * )
                        return 1;;
        esac
}
readonly -f std::get_YN_answer

##
## std::get_abspath() - return normalized absolute pathname
##
## Return the absolute path of a given file- or directory name. Symbolic
## links are NOT resolved!
##
## The script will be terminated, if the path doesn't exists.
##
## Arguments:
##   $1 - [in] file- or directory name
##
## Outputs:
##   absolute path
##
std::get_abspath() {
        local -r fname="$1"
        local -- abspath=''
        [[ -e "${fname}" ]] || \
                std::die 3 "'${FUNCNAME[0]}' called with a non-existing file-/directory name -- $1"
        if [[ -d "${fname}" ]]; then
                abspath=$(cd "${fname}" && pwd -L)
        else
                local -- dname bname
                dname=$(dirname "${fname}")
                bname=$(basename "${fname}")
                abspath="$(cd "${dname}" && pwd -L)/${bname}"
        fi
        echo "${abspath}"
}
readonly -f std::get_abspath

##
## std::{modify,append,prepend}_path - append or prepend directories to a path
##
## Arguments:
##   $1 - [in/out] reference to path like variable
##   $2  - [in] mode, either append or prepend
##   $3... - [in] directories to append or prepend
##
## Returns:
##   0
##
## Notes:
##   :FIXME:
##   What happens if first argument is the name of a non-existing variable?
##
std::modify_path() {
        local -n __mp_path="$1"
        local -r __mp_mode="$2"
        shift 2
        local -a __mp_dirs=("$@")

        # Ignore directories that are already in ${__mp_path}
        local -- __new_dirs='' __mp_dir=''
        for __mp_dir in "${__mp_dirs[@]}"; do
                [[ ":${__mp_path}:" == *":${__mp_dir}:"* ]] && continue
                __new_dirs+="${__mp_dir}:"
        done
        [[ -n "${__new_dirs}" ]] || return 0

        # Assemble new __mp_path, removing trailing ':' first
        __new_dirs="${__new_dirs%:}"
        if [[ -z "${__mp_path}" ]]; then
                __mp_path="${__new_dirs}"
        else
                case "$__mp_mode" in
                        append)
                                __mp_path="${__mp_path}:${__new_dirs}"
                                ;;
                        prepend)
                                __mp_path="${__new_dirs}:${__mp_path}"
                                ;;
                        *)
                                std::die 1 "Invalid mode: $__mp_mode"
                                ;;
                esac
        fi
}
readonly -f std::modify_path

std::append_path()  { std::modify_path "$1" append  "${@:2}"; }
std::prepend_path() { std::modify_path "$1" prepend "${@:2}"; }
readonly -f std::append_path
readonly -f std::prepend_path

##
## std::remove_path - remove directories from a path
##
## Arguments:
##   $1 - [in/out] reference to path like variable
##   $2... - [in] directories to remove
##
## Returns:
##   0
##
std::remove_path() {
        local -n __rp_path="$1"
        shift 1
        local -ar __rp_dirs=("$@")

        local -a __rp_paths=()
        IFS=':' read -r -a __rp_paths <<<"${__rp_path}"
        local -- __rp_dir=''
        for __rp_dir in "${__rp_dirs[@]}"; do
                # loop over all entries in path and mark
                # the to be deleted directories.
                local -i i=0
                for ((i=0; i<${#__rp_paths[@]}; i++)); do
                        [[ "${__rp_paths[i]}" == "${__rp_dir}" ]] && __rp_paths[i]=''
                done
        done
        # assemble new path
        __rp_path=''
        for __rp_dir in "${__rp_paths[@]}"; do
                [[ -n "${__rp_dir}" ]] && __rp_path+="${__rp_dir}:"
        done
        __rp_path="${__rp_path%:}"          # remove trailing ':'
}
readonly -f std::remove_path

##
## std::get_os_release - get OS release of a linux distribution.
## std::get_os_release_linux
## std::get_os_release_macos
##
## Outputs:
##   release string (e.g. rhel8)
##
## Notes:
##   For the time being only RHEL and clones, Ubuntu and SUSE distributions
##   are supported (and macOS).
##
std::get_os_release_linux() {
        local -- ID=''
        local -- VERSION_ID=''

        if command -v 'lsb_release' >/dev/null 2>&1; then
                ID=$(lsb_release -is)
                VERSION_ID=$(lsb_release -rs)
        elif [[ -r '/etc/os-release' ]]; then
                local key value
                while IFS='=' read -r key value; do
                        value="${value//\"/}"
                        case "${key}" in
                                ID) ID="${value}" ;;
                                VERSION_ID) VERSION_ID="${value}" ;;
                        esac
                done < <(grep -E '^(ID|VERSION_ID)=' /etc/os-release)
        else
                std::die 4 "Cannot determine OS release!"
        fi

        case "${ID,,}" in
                redhatenterpriseserver | redhatenterprise | scientific | springdale \
                        | rhel | centos | fedora )
                        echo "rhel${VERSION_ID%%.*}"
                        ;;
                ubuntu )
                        echo "Ubuntu${VERSION_ID%%.*}"
                        ;;
                suse )
                        echo "sles${VERSION_ID%%.*}"
                        ;;
                * )
                        std::die 4 "Unknown OS ID: ${ID}"
                        ;;
        esac
}
readonly -f std::get_os_release_linux

std::get_os_release_macos() {
        local -- VERSION_ID
        VERSION_ID=$(sw_vers -productVersion)
        echo "macOS${VERSION_ID%%.*}"
}
readonly -f std::get_os_release_macos

std::get_os_release() {
        local -A func_map
        func_map['Linux']=std::get_os_release_linux
        func_map['Darwin']=std::get_os_release_macos
        ${func_map[${KERNEL_NAME}]}
}
readonly -f std::get_os_release

##
## std::get_kernel_name - get name of kernel
##
## Outputs:
##   name of kernel
##
std::get_kernel_name() {
        echo "${KERNEL_NAME}"
}
readonly -f std::get_kernel_name

##
## std::get_system_cpu - get the CPU name of the system
##
## Outputs:
##   CPU name
##
std::get_system_cpu() {
        echo "${SYSTEM_CPU}"
}
readonly -f std::get_system_cpu

##
## std::array::contains - Check if given array contains given element.
##
## Arguments:
##   $1 - [in] element to check
##   $2... - [in] array
##
## Returns:
##   0 - if $1 is in given array
##   1 - otherwise
##
## Notes:
##   Here we do a linear search. For small arrays this is ok.
##
std::array::contains(){
        local -- item="$1"
        shift 1
        local -- el=''
        for el in "$@"; do
                [[ "${item}" == "${el}" ]] && return 0
        done
        return 1
}
readonly -f std::array::contains

##
## std::array::is_subset - Check if an array is a subset of another array.
##
## Arguments:
##   $1 - [in] reference to array/subset
##   $2... - [in] superset
##
## Returns:
##   0 - if yes
##   1 - otherwise
##
## Notes:
##   Here we do a linear search. For small arrays this is ok.
##
std::array::is_subset() {
        local -n __i_sub="$1"
        shift 1
        local -A __i_seen=()
        local -- __i_el=''
        for __i_el in "$@"; do
                __i_seen[${__i_el}]=1;
        done
        for __i_el in "${__i_sub[@]}"; do
                [[ -v __i_seen[${__i_el}] ]] || return 1
        done
        return 0
}
readonly -f std::array::is_subset

##
## std::array::difference - compute difference of two arrays
##
## Return the elements which are in the first array but not in the second.
##
## Arguments:
##   $1 - reference variable to return result
##   $2 - first array A
##   $3 - second array B
##
std::array::difference() {
        local -n __ad_result="$1"
        local -n __ad_arrA="$2"
        local -n __ad_arrB="$3"

        local -A __ad_inB=()
        local -- __ad_el=''
        __ad_result=()
        for __ad_el in "${__ad_arrB[@]}"; do
                __ad_inB[${__ad_el}]=1
        done
        for __ad_el in "${__ad_arrA[@]}"; do
                [[ -v __ad_inB[${__ad_el}] ]] || __ad_result+=( "${__ad_el}" )
        done
}
readonly -f std::array::difference

##
## std::dict::copy - create copy from dictionary/associative array
##
## Arguments:
##   $1 - reference variable to the copy
##   $2 - reference variable to the original
##
std::dict::copy() {
        local -n __dc_dst="$1"
        local -n __dc_src="$2"
        local -- __dc_suffix="${3:-}"
        local -- __dc_key=''
        __dc_dst=()
        for __dc_key in "${!__dc_src[@]}"; do
                __dc_dst[${__dc_key}${__dc_suffix}]="${__dc_src[${__dc_key}]}"
        done
}
readonly -f std::dict::copy

##
## std::dict::merge - merge two dictionaries
##
## Arguments:
##   $1 - reference variable to the copy
##   $2 - reference variable to the original
##
std::dict::merge() {
        local -n __dm_dst="$1"
        local -n __dm_src="$2"
        local -- __dm_suffix="${3:-}"
        local -- __dm_key=''
        for __dm_key in "${!__dm_src[@]}"; do
                __dm_dst[${__dm_key}${__dm_suffix}]="${__dm_src[${__dm_key}]}"
        done
}
readonly -f std::dict::merge

##
## std::find_elf64_binaries - find ELF64 binaries in given directories.
##
## Arguments:
##   $@ - [in] directories to search
##
## Returns:
##   exit code of pipe
##
## Output:
##   list of ELF64 binaries
##
## Notes:
##   We read the first 5 bytes of each file with 'read -r -N 5'. This might return
##   less than 5 bytes. But then the comparison to the ELF64 magic fails anyway.
##
std::find_elf64_binaries(){
        local -r elf64_magic=$'\x7fELF\x02'
        find "$@" -type f -perm -u+x -not -name '*.pyc' -not -name '*.sh' | \
                while IFS= read -r f; do
                        read -r -N 5 magic < "$f"
                        [[ "${magic}" == "${elf64_magic}" ]] && echo "$f"
                done
}
readonly -f std::find_elf64_binaries

##
## std::get_num_cores - Get number of cores.
##
## Returns:
##   0
##
## Output:
##  Number of cores
##
std::get_num_cores() {
        case "${KERNEL_NAME}" in
        Linux )
                nproc || grep -c '^processor[[:space:]]*:' /proc/cpuinfo
                ;;
        Darwin )
                sysctl -n hw.ncpu
                ;;
        esac
}
readonly -f std::get_num_cores

##
## std::expand_braces - Bash brace expansion
##
## Perform Bash brace expansion on given string.
##
## Note:
##  - This implementation is not perfect but should be save enough
##    for our use-case.
##  - This function run in a subshell -> 'set -o noglob' stays local!
##
## Arguments:
##   $1 - text to expand
##
## Output:
##   The expanded text.
##
std::expand_braces() (
	[[ "$1" =~ [[:cntrl:]] ]] && exit 1
        local s
        s=$(sed 's|[^[:alnum:]_/.:=+@%^,{}-]|\\&|g' <<<"$1")
        eval "printf '%s\n' $s"
)

##
## yml::die_parsing
## yml::die_type_error
## yml::die_undefined(){
##
## Exit program on error
##
yml::die_type_error(){
        std::die 3 "Type error for key '$1': must be '$2', but is -- $3"
}
readonly -f yml::die_type_error

yml::die_undefined(){
        std::die 3 "Key not defined in YAML document - $1"
}
readonly -f yml::die_undefined

yml::die_parsing(){
        std::die 3 "error parsing YAML:\n----\n%s\n----" "$1"
}
readonly -f yml::die_parsing

##
## yml::read_file - read a YAML file
##
## Read a YAML formatted file.
## The program terminates on an error.
##
## Arguments:
##   $1 - [out] reference to variable to return content
##   $2 - [in] name of file to read
##
## Returns:
##   0
##
yml::read_file(){
        local -n __rf_text="$1"
        local -- __rf_fname="$2"

        __rf_text=$(yq -N ".|explode(.)" "${__rf_fname}") || \
                std::die 3 "Cannot read file. Please check with yamllint -- $2"
}
readonly -f yml::read_file

##
## yml::has_key -- test whether key is defined in a given YAML document
##
## Arguments:
##   $1 - [in] reference variable to a YAML document
##   $2 - [in] key to test
##
## Returns:
##   0 - if defined in YAML document
##   1 - otherwise
##
yml::has_key(){
        local -n __hk_text="$1"
        local -- __hk_key="$2"

        [[ $(KEY="${__hk_key}" yq 'has(strenv(KEY))' <<<"${__hk_text}") == 'true' ]]
}
readonly -f yml::has_key

##
## yml::get_keys - return the key inside an entry
##
## Example:
##
## foo:
##   bar: 42
##   x: 1
##
## returns the keys 'bar' and 'x' as Bash array.
##
## If the entry doesn't have any keys, return an empty array.
##
## The program terminates on an error.
##
## Arguments:
##   $1 - [out] reference to variable to return the keys
##   $2 - [in] reference variable with YAML text
##   $3 - [in] the key of the entry to be searched for keys.
##
## Returns:
##   0
##
yml::get_keys(){
        local -n __gk_keys="$1"
        local -n __gk_text="$2"
        local -- __gk_key="$3"

        local -- __gk_str
        __gk_str="$(yq -N "${__gk_key}" <<<"${__gk_text}")" || \
                yml::die_parsing "${__gk_text}"
        if [[ -z "${__gk_str}" || "${__gk_str}" == 'null' || "${__gk_str}" == 'false' ]]; then
                __gk_keys=()
                return 0
        fi
        __gk_str="$(yq -N ".|keys[]" <<<"${__gk_str}")" || \
                yml::die_parsing  "${__gk_text}"
        readarray -t __gk_keys <<<"${__gk_str}"
}
readonly -f yml::get_keys

##
## yml::get_type - get type of node
##
## Arguments:
##   $1 - [out] reference variable to return type
##   $2 - [in] YAML text
##   $3 - [in] key of entry
##
yml::get_type(){
        local -n __gt_type="$1"
        local -n __gt_text="$2"
        local -- __gt_key="$3"
        __gt_type="$(yq -N "${__gt_key}|type" <<<"${__gt_text}")" || \
                yml::die_parsing "${__gt_text}"
}
readonly -f yml::get_type

##
## yml::get_value - get node/value of entry
##
## Arguments:
##   $1 - [out] reference variable to return node
##   $2 - [in] YAML text
##   $3 - [in] key of entry
##   $4 - [in] expected type of node
##
yml::get_value(){
        local -n __gv_val="$1"
        local -n __gv_text="$2"
        local -- __gv_key="$3"
        local -- __gv_type="$4"

        # Step 1: metadata only - line number and actual tag.
        # NOTE: no '-e' here! yq exits 1 for a value of 'false' or 'null',
        #       which would be indistinguishable from a parse error.
        local -- __gv_info=''
        __gv_info=$(yq -N "${__gv_key} | [(. | line), (. | tag)] | join(\" \")" \
                  <<<"${__gv_text}") || yml::die_parsing "${__gv_text}"

        local -i __gv_lineno=0
        local -- __gv_got_type=''
        read -r __gv_lineno __gv_got_type <<<"${__gv_info}"

        # Step 2: decide in bash.
        if (( __gv_lineno == 0 )); then
                yml::die_undefined "${__gv_key}"          # node not in the document
        elif [[ "${__gv_got_type}" == '!!null' ]]; then
                __gv_val=''                                # key exists, has no value
                return 0
        elif [[ "${__gv_got_type}" != "${__gv_type}" ]]; then
                echo -en "Error in configuration file:\n---\n" 1>&2
                sed -n "${__gv_lineno}p" <<<"${__gv_text}" 1>&2
                echo -en "---\n" 1>&2
                yml::die_type_error "${__gv_key}" "${__gv_type}" "${__gv_got_type}"
        fi

        # Step 3: only now fetch the value.
        __gv_val=$(yq -N "${__gv_key}" <<<"${__gv_text}") || yml::die_parsing "${__gv_text}"
        return 0
}
readonly -f yml::get_value

##
## yml::get_seq_length - get the length of a sequence
##
## Return 0 if the key does not exist or the node is empty (!!null).
## Terminate the script if the node exists but is not a sequence, or if the
## YAML text cannot be parsed.
##
## Arguments:
##   $1 - [out] reference variable for the result
##   $2 - [in]  reference variable holding the YAML text
##   $3 - [in]  key of entry
##
yml::get_seq_length(){
        local -n __gsl_result="$1"
        local -n __gsl_text="$2"
        local -r __gsl_key="$3"

        # A single query returns "<line> <tag> [<length>]"; the length is only
        # emitted for sequences.  Do not use 'yq -e' here: it signals failure
        # for a result of 'null' or 'false', which cannot be distinguished
        # from a real parsing error.
        local -- __gsl_out=''
        __gsl_out=$(yq -N "${__gsl_key} |
                           [(. | line | tostring),
                            tag,
                            (select(tag == \"!!seq\") | length | tostring)]
                           | join(\" \")" <<<"${__gsl_text}") \
                || yml::die_parsing "${__gsl_text}"

        local -i __gsl_line=0
        local -- __gsl_tag='' __gsl_len=''
        read -r __gsl_line __gsl_tag __gsl_len <<<"${__gsl_out}"

        # the key is not in the document, or it has no value
        if (( __gsl_line == 0 )) || [[ "${__gsl_tag}" == '!!null' ]]; then
                __gsl_result=0
                return 0
        fi

        if [[ "${__gsl_tag}" != '!!seq' ]]; then
                echo -en "Error in configuration file:\n---\n" 1>&2
                sed -n "${__gsl_line}p" <<<"${__gsl_text}" 1>&2
                echo -en "---\n" 1>&2
                yml::die_type_error "${__gsl_key}" '!!seq' "${__gsl_tag}"
        fi

        __gsl_result="${__gsl_len}"
        return 0
}
readonly -f yml::get_seq_length

##
## yml::get_seq - get sequence
##
## Return the an empty string if an entry with the passed key doesn't exists.
## Terminate script if type is not a sequence.
##
## Arguments:
##   $1 - [out] reference variable to return result
##   $2 - [in] YAML text
##   $3 - [in] key of entry
##
yml::get_seq(){
        local -n __gs_val="$1"
        local -n __gs_text="$2"
        local -- __gs_key="$3"

        local -- type=''
        type=$( yq "${__gs_key}|type" <<<"${__gs_text}")
        if [[ "${type}" == '!!null' ]]; then
                __gs_val=''
                return 0
        fi
        [[ "${type}" == '!!seq' ]] || \
                yml::die_type_error "${__gs_key}" '!!seq' "${type}"
        local -i length=0
        length=$(yq "${__gs_key}|length" <<<"${__gs_text}")
        if (( length == 0 )); then
                __gs_val=''
                return 0
        fi
        __gs_val=$( yq "${__gs_key}[]" <<<"${__gs_text}" ) || \
                yml::die_parsing "${__gs_text}"
}
readonly -f yml::get_seq

# Local Variables:
# mode: sh
# sh-basic-offset: 8
# tab-width: 8
# End:
