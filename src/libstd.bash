#!/usr/bin/env bash

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
## std::{log,info,error,debug} - Write a message to stdout/stderr
##
## Arguments:
##   $1     - printf format string 
##   ${@:2} - Message content
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
##   $1     - exit code
##   $2     - optional printf format string 
##   ${@:3} - optional message content
##
## Usage:
##   std::die 2 "%s" "Invalid option -- foo"
##
std::die() {
	local -ri ec="$1"
	shift
	if (( ${#@} > 0 )); then
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
##   $1 - system tool
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

#
# Since we are using aliases, we have to define some before using them in a function.
# Alias expansion happens when a function is parsed!
##
std::def_cmd2 'awk'
std::def_cmd2 'base64'
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
std::def_cmd2 'install'
std::def_cmd2 'logger'
std::def_cmd2 'make'
std::def_cmd2 'md5sum'
std::def_cmd2 'mkdir'
std::def_cmd2 'mktemp'
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

declare -rg KERNEL_NAME="$(uname -s)"
declare -rg SYSTEM_CPU="$(uname -m)"

case ${KERNEL_NAME} in
	Linux )
		std::def_cmd2 'ldd'
		std::def_cmd2 'patchelf'
		std::def_cmd2 'sha256sum'
		;;
	Darwin )
		PATH+=':/opt/local/bin'
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
std::is_uint() {
	[[ $1 =~ ^[0-9]+$ ]]
}
readonly -f std::is_uint

##
## std::version_{compare,lt,le,eq,ge,gt} - Compare two version numbers.
##
## Arguments:
##   $1 first version number
##   $2 optional second version number, if not set V_PKG is used
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
#	Original implementation found on stackoverflow:
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
		std::die 3 "Oops: '${FUNCNAME}' called with wrong number of args!"
	fi

	# fill empty fields in ver1 with zeros
	local -i i=0
	for ((i=${#ver1[@]}; i<${#ver2[@]}; i++)); do
		ver1[i]=0
	done
	for ((i=0; i<${#ver1[@]}; i++)); do
		[[ -z ${ver2[i]} ]] && ver2[i]=0
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
##   $1 - prompt
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
##   $1: file- or directory name
##
std::get_abspath() {
	local -r fname="$1"
	local -- abspath=''
	[[ -e "${fname}" ]] || \
		std::die 3 "'${FUNCNAME}' called with a non-existing file-/directory name -- $1"
	if [[ -d "${fname}" ]]; then
		abspath=$(cd "${fname}" && pwd -L)
	else
		local -r dname=$(dirname "${fname}")
		abspath=$(cd "${dname}" && pwd -L)/$(basename "${fname}")
	fi
	echo "${abspath}"
}
readonly -f std::get_abspath

##
## std::{modify,append,prepend}_path - append or prepend directories to a path
##
## Arguments:
##   $1 - name of path like variable
##   $2  - mode, either append or prepend
##   $3... - directories to append or prepend
##
## Returns:
##   0
##
## Notes:
##   :FIXME:
##   What happens if first argument is the name of a non-existing variable?  
##
std::modify_path() {
	local -n path="$1"
	local -r mode="$2"
	shift 2
	local -a dirs=("$@")

	# Ignore directories that are already in ${path}
	local -- new_dirs='' dir=''
	for dir in "${dirs[@]}"; do
		[[ ":${path}:" == *":${dir}:"* ]] && continue
		new_dirs+="${dir}:"
	done
	[[ -n "${new_dirs}" ]] || return 0

	# Assemble new path, removing trailing ':' first
	new_dirs="${new_dirs%:}"
	if [[ -z "${path}" ]]; then
		path="${new_dirs}"
	else
		case "$mode" in
			append)
				path="${path}:${new_dirs}"
				;;
			prepend)
				path="${new_dirs}:${path}"
				;;
			*)
				std::die 1 "Invalid mode: $mode"
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
##   $1 - name of path like variable
##   $2... - directories to append or prepend
##
## Returns:
##   0
##
std::remove_path() {
	local -n path="$1"
	shift 1
	local -ar remove_dirs=("$@")

	local -a _path=()
	IFS=':' read -r -a _path <<<"${path}"
	local -- dir=''
	for dir in "${remove_dirs[@]}"; do
		# loop over all entries in path and mark
		# the to be deleted directories.
		local -i i=0
		for ((i=0; i<${#_path[@]}; i++)); do
			[[ "${_path[i]}" == "${dir}" ]] && _path[i]=''
		done
	done
	# assemble new path
	path=''
	for dir in "${_path[@]}"; do
		[[ -n "${dir}" ]] && path+="${dir}:"
	done
	path="${path%:}"		# remove trailing ':'
}
readonly -f std::remove_path

##
## std::get_os_release_linux - get OS release of a linux distribution.
##
## Notes:
##   For the time being only RHEL and clones, Ubuntu and SUSE distributions
##   are supported.
##
std::get_os_release_linux() {
	local -- ID=''
	local -- VERSION_ID=''

	if command -v 'lsb_release' >/dev/null 2>&1; then
		ID=$(lsb_release -is)
		VERSION_ID=$(lsb_release -rs)
	elif [[ -r '/etc/os-release' ]]; then
		while IFS='=' read -r key value; do
			value="${value//\"/}"
			case "${key}" in
				ID) ID="${value}" ;;
				VERSION_ID) VERSION_ID="${value}" ;;
			esac
		done < <(grep -E '^(ID|VERSION_ID)=' /etc/os-release)
	else
		std::die 4 "Cannot determin OS release!"
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

##
## std::get_os_release_macos - Get macOS release
##
std::get_os_release_macos() {
	local -r VERSION_ID=$(sw_vers -productVersion)
	echo "macOS${VERSION_ID%%.*}"
}
readonly -f std::get_os_release_macos

##
## std::get_os_release - Get release of OS.
##
std::get_os_release() {
	local -A func_map;
	func_map['Linux']=std::get_os_release_linux
	func_map['Darwin']=std::get_os_release_macos
	${func_map[${KERNEL_NAME}]}
}
readonly -f std::get_os_release

std::get_kernel_name() {
	echo "${KERNEL_NAME}"
}
readonly -f std::get_kernel_name

std::get_system_cpu() {
	echo "${SYSTEM_CPU}"
}
readonly -f std::get_system_cpu

##
## std::array::contains - Check if given array contains given element.
##
## Arguments:
##   $1 - element to check
##   $2... - array
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
##   $1 - reference to array/subset 
##   $2... - superset
##
## Returns:
##   0 - if yes
##   1 - otherwise
##
## Notes:
##   Here we do a linear search. For small arrays this is ok.
##
std::array::is_subset() {
	local -n _sub=$1
	shift 1
	local -A _seen=()
	local -- el=''
	for el in "$@"; do _seen["${el}"]=1; done
	for el in "${_sub[@]}"; do [[ -v _seen["${el}"] ]] || return 1; done
}
readonly -f std::array::is_subset

##
## std::find_elf64_binaries - find ELF64 binaries in given directories.
##
## Arguments:
##   $1... - directories to search
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

#std::find_elf64_binaries(){
#	local -r elf64_magic=$'\x7fELF\x02'
#	find "$@" -type f -not -name '*.pyc' -not -name '*.sh' -executable \
#		-exec sh -c 'for f; do head -c5 "$f" | LC_ALL=C grep -Fq "${magic#}" && echo $f; done' _ {} +
#}

#std::find_elf64_binaries(){
#	find "$@" -type f -not -name '*.pyc' -not -name '*.sh' -executable | \
#		file -f - | \
#		awk '/ELF 64-bit/ {print substr($1, 1, length($1)-1)}'
#}

std::get_dir_depth(){
	local -r tmp="${1//[^\/]/}"
	echo "${#tmp}"
}
readonly -f std::get_dir_depth

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
## yml::die_type_error
## yml::die_parsing
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
##   $1 - reference to variable to return content
##   $2 - name of file to read
##
## Returns:
##   0
##
yml::read_file(){
	local -n yml_string="$1"
	local -- yml_fname="$2"

	yml_string=$(yq -N ".|explode(.)" "${yml_fname}") || \
		std::die 3 "Cannot read file. Please check with yamllint -- $1"
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
	local -n yml_string="$1"
	local -- yml_key="$2"

	[[ $(KEY="${yml_key}" yq 'has(strenv(KEY))' <<<"${yml_string}") == 'true' ]]
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
##   $1 - reference to variable to return the keys
##   $2 - YAML stream
##   $3 - the entry to be searched for keys.
##
## Returns:
##   0
##
yml::get_keys(){
	local -n yml_keys="$1"
	local -n yml_text="$2"
	local -- yml_key="$3"

	local -- str
	str="$(yq -N "${yml_key}" <<<"${yml_text}")" || \
		yml::die_parsing "${yml_text}"
 	if [[ -z "${str}" || "${str}" == 'null' || "${str}" == 'false' ]]; then
		yml_keys=()
		return 0
	fi
	str="$(yq -N ".|keys[]" <<<"${str}")" || \
		yml::die_parsing  "${yml_text}"
	readarray -t yml_keys <<<"${str}"
}
readonly -f yml::get_keys

yml::get_type(){
	local -n yml_type="$1"
	local -n yml_text="$2"
	local -- yml_key="$3"
	yml_type="$(yq -N "${yml_key}|type" <<<"${yml_text}")" || \
		yml::die_parsing "${yml_text}"
}
readonly -f yml::get_type

yml::get_value(){
	local -n yml_val="$1"
	local -n yml_text="$2"
	local -- yml_key="$3"
	local -- yml_type="$4"
	yml_val=$( yml_type="${yml_type}" yq -Ne \
		       'strenv(yml_type) as $yml_type
		           | '"${yml_key}"'
			   | (select(tag == $yml_type) 
			       // ("Error in line: " + (.|line)
			           + ", path: " + (.|path | join("."))
				   + " expected type: " + $yml_type + ", got: " + (.|tag)))' \
					   <<<"${yml_text}" )
	if [[ "${yml_val}" != "Error in line: "* ]]; then
		return 0 
	elif [[ "${yml_val}" == "Error in line: 0,"* ]]; then
		yml::die_undefined "${yml_key}"
	elif [[ "${yml_val}" == *"got: !!null" ]]; then
		# key has no node/value
		yml_val=''
		return 0
	else
		local -- got_type=''
		local -- lineno
		got_type=$(awk '{print $NF}' <<<"${yml_val}")
		lineno=$(awk '{print $4}' <<<"${yml_val}")
		lineno="${lineno/,}"
		## (( lineno+=1))
		echo -en "Error in configuration file:\n---\n" 1>&2
		sed -n "${lineno}p" <<<"${yml_text}" 1>&2
		echo -en "---\n" 1>&2
		yml::die_type_error "${yml_key}" "${yml_type}" "${got_type}"
	fi
}
readonly -f yml::get_value

#yml::get_value(){
#	local -n yml_val="$1"
#	local -n yml_text="$2"
#	local -- yml_key="$3"
#	local -- yml_expected_type="$4"
#	
#	yml_val=$( yq -N "${yml_key} | select(tag == \"${yml_expected_type}\")" \
#			   <<<"${yml_text}" ) || \
#		yml::die_type_error "${yml_key}" "${yml_expected_type}" "${type}"
#}

##
## yml::get_seq_length - get the length of a sequence
##
## Return 0 as length, if the key doesn't exists or the node is not a sequence.
##
## Arguments:
##   $1 - reference variable for result
##   $2 - YAML string
##   $3 - key of sequence
##
yml::get_seq_length(){
	local -n yml_seq_length="$1"
	local -n yml_text="$2"
	local -- yml_key="$3"

	local -i len=0
	len=$(yq -e "${yml_key} | select(tag == \"!!seq\") | length" <<<"${yml_text}") || \
		yml::die_parsing "${yml_text}"
	yml_seq_length="${len}"
}
readonly -f yml::get_seq_length

##
## yml::get_seq - get sequence
##
## Return the an empty string if an entry with the passed key doesn't exists.
## Terminate script if type is not a sequence.
##
## Arguments:
##   $1 - refernce variable to return result
##   $2 - YAML text
##   $3 - key of sequence
##
yml::get_seq(){
	local -n yml_val="$1"
	local -n yml_text="$2"
	local -- yml_key="$3"

	local -- type=''
	type=$( yq "${yml_key}|type" <<<"${yml_text}")
	if [[ "${type}" == '!!null' ]]; then
		yml_val=''
		return 0
	fi
	[[ "${type}" == '!!seq' ]] || \
		yml::die_type_error "${yml_key}" '!!seq' "${type}"
	local -i length=0
	length=$(yq "${yml_key}|length" <<<"${yml_text}")
	if (( length == 0 )); then
		yml_val=''
		return 0
	fi
	yml_val=$( yq "${yml_key}[]" <<<"${yml_text}" ) || \
		yml::die_parsing "${yml_text}"
}
readonly -f yml::get_seq

# Local Variables:
# mode: sh
# sh-basic-offset: 8
# tab-width: 8
# End:
