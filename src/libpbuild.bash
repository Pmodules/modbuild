#!/bin/bash

#.............................................................................
# disable auto-echo feature of 'cd'
unset CDPATH

#.............................................................................
# define constants
declare -r FNAME_RDEPS='.dependencies'
declare -r FNAME_IDEPS='.install_dependencies'

# relative path of documentation
# abs. path is "${PREFIX}/${_docdir}/${module_name}"
declare -r  _DOCDIR='share/doc'

declare -a SOURCE_URLS=()
declare -a SOURCE_NAMES=()
declare -a SOURCE_STRIP_DIRS=() 
declare -a SOURCE_UNPACKER=()
declare -a SOURCE_UNPACK_DIRS=()
declare -ax CONFIGURE_ARGS=()
declare -a PATCH_FILES=()
declare -a PATCH_STRIPS=()
declare -- PATCH_STRIP_DEFAULT='1'
declare -- SRC_DIR=''
declare -- BUILD_DIR=''

declare -i group_depth=0

declare -- COMPILER=''
declare -- MPI=''

#.............................................................................
#
# Exit script on errror.
#
# $1	exit code
#
#set -o errexit

_error_handler() {
	local -i ec=$?

	std::die ${ec} "Oops"
}
readonly -f _error_handler

trap "_error_handler" ERR

#******************************************************************************
#
# function in the "namespace" (with prefix) 'pbuild::' can be used in
# build-scripts
#

#..............................................................................
#
# Test whether a module with the given name is available. If yes, return
# release
#
# Arguments:
#   $1: module name
#   $2: optional variable name to return release
#
# Notes:
#   The passed module name must be module/version!
#
# Exit codes:
#   0 if module/version is available
#   1 otherwise
#
pbuild::module_is_avail() {
	local -- name=''
	local -- release=''
	if [[ -v PMODULES_HOME ]]; then
		while read -r name release; do
			if [[ "${name}" == "$1" || "${name}" == "${1}.lua" ]]; then
				# return relase in second argument if defined
				if (( $# > 1 )); then
					local -n _relstage="$2"
					_relstage="${release}"
				fi
				return 0
			fi
		done < <(modulecmd bash avail -a -m "$1" 2>&1 1>/dev/null)
		return 1
	else
		local -- xtrace_is_on=''
		if [[ "$-" == *x* ]]; then
			xtrace_is_on=':'
			#set +x
		fi
		local output=$(modulecmd bash avail --all --output=tag --terse "$1" 2>&1)
		[[ "${xtrace_is_on}" ]] && set -x
		while read -r name release; do
			if [[ "${name}" == "$1" || "${name}" == "${1}.lua" ]]; then
				# return relase in second argument if defined
				case ${release} in
				'<d>'|'<d:*'|'*:d>'|'*:d:*' )
					release='deprecated'
					;;
				'<u>'|'<u:*'|'*:u>'|'*:u:*' )
					release='unstable'
					;;
				* )
					release='stable'
				esac
				if (( $# > 1 )); then
					local -n _result="$2"
					_result="${release}"
				fi
				return 0
			fi
		done <<<"${output}"
		return 1
	fi
}
readonly -f pbuild::module_is_avail

#..............................................................................
#
pbuild::use_flag() {
	[[ "${ModuleConfig['use_flags']}" =~ " ${1} " ]]
}
readonly -f pbuild::use_flag

##############################################################################
#
# functions to prepare the sources

#..............................................................................
#
pbuild::unpack(){
	local -- fname="$1"
	local -- dir="$2"
	local -r strip="${3:-1}"
	local -- unpacker="${4:-tar}"

	fname=$(envsubst <<<"${fname}")
	if [[ -z "${dir}" ]]; then
		dir="${SRC_DIR}"
	else
		dir=$(envsubst <<<"${dir}")
	fi
	unpacker=$(envsubst <<<"${unpacker}")
	mkdir -p "${dir}"

	case "${unpacker}" in
		tar )
			tar \
				--directory="${dir}" \
				-xv \
				--exclude-vcs \
				--strip-components "${strip}" \
				-f "${fname}"
			;;
		7z )
			sevenz \
				x \
				-y \
				-o"${dir}" \
				"${fname}"
			;;
		none )
			cp "${fname}" "${dir}"
			;;
		* )
			std::die 1 "Unsupportet tool for unpacking -- '${unpacker}'"
			;;
	esac
}

#..............................................................................
#
# extract sources. For the time being only tar-files are supported.
#
pbuild::pre_prep(){
	:
}
pbuild::post_prep(){
	:
}
pbuild::prep() {
	search_source_file(){
		local -n  ref_dir="$1"
		local -r fname="$2"
		local -a dirs=(
			"${PMODULES_DISTFILESDIR}"
			"${BUILDBLOCK_DIR}"
			"${BUILDBLOCK_DIR}/files"
		)
		# return if neither a URL nor a file name given
		[[ -n "${fname}" ]] || return 0
		local -- dir=''
		for dir in "${dirs[@]}"; do
			if [[ -r "${dir}/${fname}" ]]; then
				ref_dir="${dir}"
				return 0
			fi
		done
		ref_dir=''
		return 1
	}

	download_source_file() {
		local -- src_dir="$1"
		local -i idx="$2"
		if [[ -z "${SOURCE_NAMES[idx]}" ]]; then
			SOURCE_NAMES[idx]="${PMODULES_DISTFILESDIR}/${SOURCE_URLS[idx]##*/}"
		fi
		curl \
			--location \
				--fail \
				--output "${src_dir}/${SOURCE_NAMES[idx]}" \
				"${SOURCE_URLS[idx]}" || \
				std::die 42 \
					 "%s " \
					 "${module_name}/${module_version}:" \
					 "downloading source file '${SOURCE_NAMES[idx]}' failed!"

			# :FIXME: How to handle insecure downloads? 
			#if (( $? != 0 )); then
			#	curl \
			#		--insecure \
			#		--output "${fname}" \
			#		"${url}"
			#fi
	}

	unpack() {
		local -r  src_dir="$1"
		local -ri idx="$2"

		local -r fname="${src_dir}/${SOURCE_NAMES[idx]}"
		local -r dir="${SOURCE_UNPACK_DIRS[idx]}"
		local -r strip="${SOURCE_STRIP_DIRS[idx]}"
		local -r unpacker="${SOURCE_UNPACKER[idx]}"

		if ! pbuild::unpack "${fname}" "${dir}" "${strip}" "${unpacker}"; then
			rm -f "${fname}"
			std::die 4 \
				 "%s " \
				 "${module_name}/${module_version}:" \
				 "cannot unpack sources!"
		fi
	}

	check_hash_sum() {
		local -r  src_dir="$1"
		local -ri idx="$2"
		local -r fname="${SOURCE_NAMES[idx]}"
		if [[ -v ModuleConfig[shasum:${fname}] ]]; then
			local -- hash_sum=''
			hash_sum=$(sha256sum "${src_dir}/${fname}" | awk '{print $1}')
			test "${hash_sum}" == "${ModuleConfig[shasum:${fname}]}" || \
				std::die 42 \
					 "%s " \
					 "${module_name}/${module_version}:" \
					 "hash-sum missmatch for file '${fname}'!"
			std::info "${module_name}/${module_version}: SHA256 hash sum is OK ..." 
		else
			std::info "${module_name}/${module_version}: SHA256 hash sum missing NOK ..." 
		fi
	}

	apply_patch(){
		local -r fname="$1"
		local -r strip="$2"
		local -r dir="$3"
		std::info \
			"%s " \
			"${module_name}/${module_version}:" \
			"Appling patch '${fname}' ..."
		patch \
			--strip="${strip}" \
			--directory="${dir}" < "${fname}" || \
			std::die 4 \
				 "%s " \
				 "${module_name}/${module_version}:" \
				 "error patching sources!"
	}

	patch_sources() {
		local -i _i=0
		for ((_i = 0; _i < ${#PATCH_FILES[@]}; _i++)); do
			local -i strip=
			apply_patch \
				"${BUILDBLOCK_DIR}/${PATCH_FILES[_i]}" \
				"${PATCH_STRIPS[_i]:-${PATCH_STRIP_DEFAULT}}" \
				"${SRC_DIR}"
		done
	}

	(( ${#SOURCE_URLS[@]} == 0 )) && return 0
	mkdir -p "${PMODULES_DISTFILESDIR}"
	local -i i=0
	for ((i = 0; i < ${#SOURCE_URLS[@]}; i++)); do
		local -- src_dir=''
		local -i ec=0

		# if file name is not specified, use last component of URL as file name
		# check whether file exist
		# try to download if not and URL is specified
		[[ -z "${SOURCE_NAMES[i]}" ]] && SOURCE_NAMES[i]="${SOURCE_URLS[i]##*/}"
		if [[ -n "${SOURCE_NAMES[i]}" ]]; then
			if ! search_source_file src_dir "${SOURCE_NAMES[i]}"; then
				if [[ -n "${SOURCE_URLS[i]}" ]]; then
					src_dir="${PMODULES_DISTFILESDIR}"
					download_source_file "${src_dir}" "$i"
				fi
			fi
		fi
		if [[ -n "${SOURCE_NAMES[i]}" ]]; then
			check_hash_sum "${src_dir}" "$i"
			unpack "${src_dir}" "$i"
		fi
		if [[ -n "${SOURCE_PATCH_FILES[i]}" ]]; then
			search_source_file src_dir "${SOURCE_PATCH_FILES[i]}" || \
				std::die 42 \
					 "%s " \
					 "${module_name}/${module_version}:" \
					 "patch file '${SOURCE_PATCH_FILES[i]}' not found!"
			local -- target_dir=''
			if [[ -z "${SOURCE_UNPACK_DIRS[i]}" ]]; then
				target_dir="${SRC_DIR}"
			else
				target_dir="${SOURCE_UNPACK_DIRS[i]}"
			fi
			mkdir -p "${target_dir}"

			apply_patch \
				"${src_dir}/${SOURCE_PATCH_FILES[i]}" \
				 "${SOURCE_PATCH_STRIPS[i]:-${PATCH_STRIP_DEFAULT}}" \
				"${target_dir}"
		fi
	done
	patch_sources
	# create build directory
	mkdir -p "${BUILD_DIR}"
}
pbuild::prep_pip3(){
	python3 -m venv "${PREFIX}"
	source "${PREFIX}/bin/activate"

}
###############################################################################
#
# functions to configure the sources

#..............................................................................
#
pbuild::add_configure_args(){
	CONFIGURE_ARGS+=( "$@" )
}
readonly -f pbuild::add_configure_args

#..............................................................................
#
# Configure the software to be compiled.
#
# Arguments:
#	none
#
pbuild::pre_configure() {
	:
}
pbuild::post_configure() {
	:
}
pbuild::configure() {
	local -r configure_with="${ModuleConfig['configure_with']}"
	case "${configure_with}" in
		autotools )
        		if [[ ! -r "${SRC_DIR}/configure" ]]; then
				std::die 3 \
					 "%s " "${module_name}/${module_version}:" \
					 "${FUNCNAME[0]}:" \
					 "autotools configuration not available, aborting..."
			fi
			;;
		cmake )
			if [[ ! -r "${SRC_DIR}/CMakeLists.txt" ]]; then
				std::die 3 \
					 "%s " "${module_name}/${module_version}:" \
					 "${FUNCNAME[0]}:" \
					 "CMake script not available, aborting..."
			fi
			;;
	esac
	local -a config_args=()
	local -- arg=''
	for arg in "${CONFIGURE_ARGS[@]}"; do
		config_args+=( "$(envsubst <<<"${arg}")" )
	done
	if [[ -r "${SRC_DIR}/configure" ]] && \
		   [[ "${configure_with}" == 'auto' ]] || \
			   [[ "${configure_with}" == 'autotools' ]]; then
		std::info "%s " "${SRC_DIR}/configure --prefix=${PREFIX} ${config_args[@]}"
		"${SRC_DIR}/configure" \
			  --prefix="${PREFIX}" \
			  "${config_args[@]}" || \
			std::die 3 \
				 "%s " "${module_name}/${module_version}:" \
				 "configure failed"
	elif [[ -r "${SRC_DIR}/CMakeLists.txt" ]] && \
		     [[ "${configure_with}" == 'auto' ]] || \
			     [[ "${configure_with}" == "cmake" ]]; then
		# note: in most/many cases a cmake module is used!
		cmake \
			-DCMAKE_INSTALL_PREFIX="${PREFIX}" \
			"${config_args[@]}" \
			"${SRC_DIR}" || \
			std::die 3 \
				 "%s " "${module_name}/${module_version}:" \
				 "cmake failed"
	else
		std::info \
			"%s " \
			"${module_name}/${module_version}:" \
			"${FUNCNAME[0]}: skipping..."
	fi
}


##############################################################################
#
# functions to compile the sources

#..............................................................................
#
# Default compile function.
#
# Note:
# Makefiles generated by autotools can fail if the environemnt variable
# V is set.
#
# Arguments:
#	none
#
pbuild::pre_compile() {
	:
}
pbuild::post_compile() {
	:
}
pbuild::compile() {
	local -- tmp_v="$V"
	local -- restore='no'
	local -- tmp_verbose=''
	if [[ -v VERBOSE ]]; then
		tmp_verbose="${VERBOSE}"
		restore='yes'
	fi
	if (( Options['verbose'] > 0 )); then
		declare -g V=1
		declare -g VERBOSE=1
	else
		unset V
	fi
	# number of parallel make jobs
	local -i num_jobs="${Options['num_jobs']}"
	make -j${num_jobs} -e || \
		std::die 3 \
			 "%s " "${module_name}/${module_version}:" \
			 "compilation failed!"
	declare -g V="${tmp_v}"
	if [[ "${restore}" == 'yes' ]]; then
		VERBOSE="${tmp_verbose}"
	fi
}

##############################################################################
#
# functions to install everything

#..............................................................................
#
# Default install function.
#
# Arguments:
#	none
#
pbuild::pre_install() {
	:
}
pbuild::post_install() {
	:
}
pbuild::post_install_pip3(){
	mkdir -p "${PREFIX}/.bin"
	mv "${PREFIX}/bin/python3"  "${PREFIX}/.bin"
	rm -vf \
	   "${PREFIX}"/bin/activate*\
	   "${PREFIX}"/bin/python*\
	   "${PREFIX}"/bin/pip\
	   "${PREFIX}"/bin/pip3*\
	   "${PREFIX}"/bin/normalizer
	local -a scripts=()
	if [[ -d "${PREFIX}/bin" ]]; then
		scripts=( $(find "${PREFIX}/bin" -type f -exec grep -Il '^#!.*python' {} \;) )
	fi
	if [[ -d "${PREFIX}/sbin" ]]; then
		scripts+=( $(find "${PREFIX}/sbin" -type f -exec grep -Il '^#!.*python' {} \;) )
	fi
	for script in "${scripts[@]}"; do
		sed -i "1s|^#!.*|#!${PREFIX}/.bin/python3|" "${script}"
	done
}

pbuild::install() {
	make install || \
		std::die 3 \
			 "%s " "${module_name}/${module_version}:" \
			 "compilation failed!"
}

#..............................................................................
#
pbuild::install_shared_libs() {
	local -r binary="$1"
	local -r dstdir="$2"
	local -r pattern="${3//\//\\/}" # escape slash

	install_shared_libs_Linux() {
		local -a libs=()
		mapfile -t libs < <(ldd "${binary}" | \
				       awk "/ => \// && /${pattern}/ {print \$3}")
		if (( ${#libs[@]} > 0 )); then
			cp -vL "${libs[@]}" "${dstdir}" || return $?
		fi
		return 0
	}

	install_shared_libs_Darwin() {
		# https://stackoverflow.com/questions/33991581/install-name-tool-to-update-a-executable-to-search-for-dylib-in-mac-os-x
		local -a libs=()
		mapfile -t libs < <(${otool} -L "${binary}" | \
				       awk "/${pattern}/ {print \$1}")
		if (( ${#libs[@]} > 0 )); then
			cp -vL "${libs[@]}" "${dstdir}" || return $?
		fi
		return 0
	}

	test -e "${binary}" || \
		std::die 3 \
			 "%s " "${module_name}/${module_version}:" \
			 "${binary}: does not exist or is not executable!"
	mkdir -p "${dstdir}"
	case "${KERNEL_NAME}" in
		Linux )
			install_shared_libs_Linux
			;;
		Darwin )
			install_shared_libs_Darwin
			;;
	esac
}

###############################################################################
#
# The following two functions are the entry points called by modbuild!
#

declare -n ModuleConfig
declare -n Options
declare -a Systems=()
declare -a UseOverlays=()
pbuild::_module_yaml(){
	local -- module_name="$1"
	local -- module_version="$2"
	ModuleConfig="$3"
	Options="$4"
	shift 4

	eval $( modulecmd bash purge )
	if [[ -v __MODULES_OVERLAYS ]]; then
		local -a overlays=()
		local -- overlay=''
		IFS=':' read -r -a overlays <<<"${__MODULES_OVERLAYS}"
		for overlay in "${overlays[@]}"; do
			eval $(modulecmd bash unuse "${overlay}")
		done
	fi
	unset	C_INCLUDE_PATH
	unset	CPLUS_INCLUDE_PATH
	unset	CPP_INCLUDE_PATH
	unset	LIBRARY_PATH
	unset	LD_LIBRARY_PATH
	unset	DYLD_LIBRARY_PATH

	unset	CFLAGS
	unset	CPPFLAGS
	unset	CXXFLAGS
	unset	LIBS
	unset	LDFLAGS

	unset	CC
	unset	CXX
	unset	FC
	unset	F77
	unset	F90

	local -- module_relstage="${ModuleConfig['relstage']}"
	if [[ -n "${ModuleConfig['systems']}" ]]; then
		readarray -t Systems <<< "${ModuleConfig['systems']}"
	fi
	if [[ -n "${ModuleConfig['use_overlays']}" ]]; then
		readarray -t UseOverlays <<< "${ModuleConfig['use_overlays']}"
	fi
	if [[ -n "${ModuleConfig['configure_args']}" ]]; then
		readarray -t CONFIGURE_ARGS <<< "${ModuleConfig['configure_args']}"
	fi
	if [[ -n "${ModuleConfig['patch_files']}" ]]; then
		local -a items=()
		readarray -t items <<< "${ModuleConfig['patch_files']}"
		local -- item=''
		for item in "${items[@]}"; do
			[[ -z "${item}" ]] && continue
 			if [[ ${item} == *:* ]]; then
				PATCH_FILES+=( "${item%%:*}" )
				PATCH_STRIPS+=( "${item##*:}" )
			else
				PATCH_FILES+=( "${item}" )
				PATCH_STRIPS+=( "${PATCH_STRIP_DEFAULT}" )
			fi
		done
	fi
	local -i i=0 num_sources="${ModuleConfig['num_sources']}"
	for ((i=0; i<num_sources; i++)); do
		if [[ -n "${ModuleConfig[url:$i]}" ]]; then
			SOURCE_URLS[i]=$(envsubst <<<"${ModuleConfig[url:$i]}")
		else
			SOURCE_URLS[i]=''
		fi
		if [[ -n "${ModuleConfig[name:$i]}" ]]; then
			SOURCE_NAMES[i]=$(envsubst <<<"${ModuleConfig[name:$i]}")
		else
			SOURCE_NAMES[i]=''
		fi
		SOURCE_STRIP_DIRS[i]="${ModuleConfig[strip_dirs:$i]}"
		SOURCE_UNPACKER[i]="${ModuleConfig[unpacker:$i]}"
		if [[ -n "${ModuleConfig[unpack_dir:$i]}" ]]; then
			SOURCE_UNPACK_DIRS[i]=$(envsubst <<<"${ModuleConfig[unpack_dir:$i]}")
		else
			SOURCE_UNPACK_DIRS[i]=''
		fi
		if [[ -n "${ModuleConfig[patch_file:$i]}" ]]; then
			SOURCE_PATCH_FILES[i]=$(envsubst <<<"${ModuleConfig[patch_file:$i]}")
		else
			SOURCE_PATCH_FILES[i]=''
		fi
		SOURCE_PATCH_STRIPS[i]="${ModuleConfig[patch_strip:$i]}"
	done
	_build_module "${module_name}" "${module_version}" "${module_relstage}" "$@"
}
readonly -f pbuild::_module_yaml

#..............................................................................
#
# The real worker function.
#
_build_module() {
	declare -gx module_name="$1"
	declare -gx module_version="$2"
	declare -gx module_release="$3"
	shift 3
	with_modules=( "$@" )

	# used in _make_all
	declare -a runtime_dependencies=()
	declare -a install_dependencies=()

	#......................................................................
	#
	# test whether a module is loaded or not
	#
	# Arguments:
	#	$1	module name
	#
	bm::is_loaded() {
		[[ -v LOADEDMODULES ]] || return 1
		[[ :${LOADEDMODULES}: =~ :$1: ]] && return 0
		[[ :${LOADEDMODULES}: =~ :$1.lua: ]] && return 0
		return 1
	}

	bm::load_overlays(){
		[[ -n ${ModuleConfig['use_overlays']} ]] || return 0
		std::info "%s " \
			  "using overlays ${UseOverlays[@]}"
		eval "$( modulecmd bash use "${UseOverlays[@]}" )"
	}

	#......................................................................
	#
	# Load build- and run-time dependencies.
	#
	# Arguments:
	#	none
	#
	# Variables
	#	module_release		set if defined in a variants file
	#	runtime_dependencies    runtime dependencies from variants added
	#
	bm::load_build_dependencies() {

 		#..............................................................
		#
		# build a dependency
		#
		# $1: name of module to build
		#
		# :FIXME: needs testing
		#
		build_dependency() {
			find_build_script(){
				local -- p="$1"
				local -- script=''
				script=$(find "${BUILDBLOCK_DIR}/../.." \
						 -path "*/$p/build")
				std::get_abspath "${script}"
			}

			local -r m="$1"
			std::info "%s " \
				  "$m: module does not exist, trying to build it..."
			local args=( '' )
			set -- "${ARGS[@]}"
			while (( $# > 0 )); do
				case $1 in
					-j )
						args+=( "-j $2" )
						shift
						;;
					--jobs=[0-9]* )
						args+=( "$1" )
						;;
					-v | --verbose)
						args+=( "$1" )
						;;
					--with=*/* )
						args+=( "$1" )
						;;
				esac
				shift
			done

			local -- buildscript=''
			buildscript=$(find_build_script "${m%/*}")
			[[ -x "${buildscript}" ]] || \
				std::die 1 \
					 "$m: build-block not found!"
			if ! "${buildscript}" "${m#*/}" "${args[@]}"; then
				std::die 1 \
					 "$m: oops: build failed..."
			fi
		}

		local -- m=''
		for m in "${with_modules[@]}"; do

			# module name prefixes in dependency declarations:
			# 'b:' this is a build dependency
			# 'r:' this a run-time dependency, *not* required for
			#      building
			# without prefix: this is a build and
			#      run-time dependency
			if [[ "${m:0:2}" == "b:" ]]; then
				m=${m#*:}   # remove 'b:'
			elif [[ "${m:0:2}" == "r:" ]]; then
				m=${m#*:}   # remove 'r:'
				runtime_dependencies+=( "$m" )
			elif [[ "${m:0:2}" == "R:" ]]; then
				m=${m#*:}   # remove 'R:'
				install_dependencies+=( "$m" )
				continue
			else
				runtime_dependencies+=( "$m" )
			fi
			bm::is_loaded "$m" && continue

			# 'module avail' might output multiple matches if module
			# name and version are not fully specified or in case
			# modules with and without a release number exist.
			# Example:
			# mpc/1.1.0 and mpc/1.1.0-1. Since we get a sorted list
			# from 'module avail' and the full version should be set
			# in the variants file, we look for the first exact
			# match.
			local -- release_of_dependency=''
			if ! pbuild::module_is_avail "$m" release_of_dependency; then
				build_dependency "$m" || \
					std::die 6 "building dependency failed!"
				pbuild::module_is_avail "$m" release_of_dependency || \
					std::die 6 "Oops"
			fi
			# for a stable module all dependencies must be stable
			if [[ "${module_release}" == 'stable' ]] \
				   && [[ "${release_of_dependency}" != 'stable' ]]; then
				std::die 5 \
					 "%s " "${module_name}/${module_version}:" \
					 "release cannot be set to '${module_release}'" \
					 "since the dependency '$m' is ${release_of_dependency}"
				# for a unstable module no dependency must be deprecated
			elif [[ "${module_release}" == 'unstable' ]] \
				     && [[ "${release_of_dependency}" == 'deprecated' ]]; then
				std::die 5 \
					 "%s " "${module_name}/${module_version}:" \
					 "release cannot be set to '${module_release}'" \
					 "since the dependency '$m' is ${release_of_dependency}"
			fi

			std::info "Loading module: ${m}"
			local output="$(modulecmd bash load "${m}")";
			eval "${output}"
			if ! bm::is_loaded "$m"; then
				modulecmd bash list
				std::die 5 \
					 "%s " "${m}:" \
					 "module cannot be loaded!"
			fi
		done
	} # bm::load_build_dependencies

	#......................................................................
	#
	# compute full module name and installation prefix
	#
	# The following variables are expected to be set:
	#	GROUP	    module group
	#	P		    module name
	#	V		    module version
	#       variables defining the hierarchical environment like
	#	COMPILER and COMPILER_VERSION
	#
	# The following variables are set in this function
	#	modulefile_dir
	#	modulefile_name
	#	PREFIX
	#
	bm::set_full_module_name_and_prefix() {
		local -r group="${ModuleConfig['group']}"
		die_no_compiler(){
			std::die 1 \
				 "%s: %s" \
				 "${module_name}/${module_version}" \
				 "module is in group '${group}' but no compiler loaded!"
		}
		die_no_mpi(){
			std::die 1 \
				 "%s: %s" \
				 "${module_name}/${module_version}" \
				 "module is in group '${group}' but no MPI module loaded!"
		}
		die_no_hdf5(){
			std::die 1 \
				 "%s: %s" \
				 "${module_name}/${module_version}" \
				 "module is in group '${group}' but no HDF5 module loaded!"
		}

		modulefile_dir="${ol_modulefiles_root}/${group}/${__MODULEFILES_DIR__}/"
		PREFIX="${ol_install_root}/${group}/${module_name}/${module_version}/"
		case "${group}" in
			Compiler )
				[[ -v COMPILER_VERSION ]] || die_no_compiler
				modulefile_dir+="${COMPILER}/${COMPILER_VERSION}/"
				PREFIX+="${COMPILER}/${COMPILER_VERSION}/"
				group_depth=2
				;;
			MPI )
				[[ -v COMPILER_VERSION ]] || die_no_compiler
				[[ -v MPI_VERSION ]] || die_no_mpi
				modulefile_dir+="${COMPILER}/${COMPILER_VERSION}/"
				modulefile_dir+="${MPI}/${MPI_VERSION}/"
				PREFIX+="${MPI}/${MPI_VERSION}/"
				PREFIX+="${COMPILER}/${COMPILER_VERSION}/"
				group_depth=4
				;;
			HDF5 )
				[[ -v COMPILER_VERSION ]] || die_no_compiler
				[[ -v MPI_VERSION ]] || die_no_mpi
				[[ -v HDF5_VERSION ]] || die_no_hdf5
				modulefile_dir+="${COMPILER}/${COMPILER_VERSION}/"
				modulefile_dir+="${MPI}/${MPI_VERSION}/"
				modulefile_dir+="hdf5/${HDF5_VERSION}/"
				PREFIX+="hdf5/${HDF5_VERSION}/"
				PREFIX+="${MPI}/${MPI_VERSION}/"
				PREFIX+="${COMPILER}/${COMPILER_VERSION}/"
				group_depth=6
				;;
			HDF5_serial )
				[[ -v COMPILER_VERSION ]] || die_no_compiler
				[[ -v HDF5_SERIAL_VERSION ]] || die_no_hdf5
				modulefile_dir+="${COMPILER}/${COMPILER_VERSION}/"
				modulefile_dir+="hdf5_serial/${HDF5_SERIAL_VERSION}/"
				PREFIX+="hdf5_serial/${HDF5_SERIAL_VERSION}/"
				PREFIX+="${COMPILER}/${COMPILER_VERSION}/"
				group_depth=4
				;;
			* )
				:
				;;
		esac
		modulefile_dir+="${module_name}"
		modulefile_name="${modulefile_dir}/${module_version}"
	} # bm::set_full_module_name_and_prefix
	
	#......................................................................
	# post-install.
	#
	# Arguments:
	#	none
	bm::post_install() {
		#..............................................................
		# post-install:
		# - build-script
		# - list of loaded modules while building
		# - doc-files specified in the build-script
		#
		# Arguments:
		#     none
		#
		install_doc() {
			local -r docdir="${PREFIX}/${_DOCDIR}/${module_name}"
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"installing documentation to ${docdir}"
			install -m 0755 -d "${docdir}"
			install -m 0644 "${BUILD_SCRIPT}" "${docdir}"
			modulecmd bash list -t 2>&1 1>/dev/null | \
				grep -v "Currently Loaded" > \
				      "${docdir}/dependencies" || :
			[[ -n ${module_config['docfiles']} ]] || return 0
			local -a docfiles=()
			readarray -t docfiles <<<"${module_config['docfiles']}"
			install -m0644 \
				"${docfiles[@]/#/${SRC_DIR}/}" \
				"${docdir}"
			return 0
		}

		#..............................................................
		# post-install: for Linux we need a special post-install to
		# solve the multilib problem with LIBRARY_PATH on 64-bit systems
		post_install_linux() {
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"running post-installation for ${KERNEL_NAME} ..."
			{
				cd "${PREFIX}"
				[[ -d "lib" ]] && [[ ! -d "lib64" ]] && ln -s lib lib64
			};
			return 0
		}

		#..............................................................
		# post-install
		cd "${BUILD_DIR}"
		[[ "${KERNEL_NAME}" == "Linux" ]] && post_install_linux
		install_doc
		return 0
	} # bm::post_install

 	#......................................................................
	bm::install_module_config(){
		local -r __doc__='
		Install modulefile.
		'
		[[ "${Options['is_subpkg']}" == 'yes' ]] && return 0

		local -- src=''
		if [[ -n "${ModuleConfig['modulefile']}" ]]; then
			if [[ ! -e "${ModuleConfig['modulefile']}" ]]; then
				std::die 3 \
					 "%s " \
					 "${module_name}/${module_version}:" \
					 "modulefile '${ModuleConfig['modulefile']}" \
					 "does not exist!"
			fi
			src="${ModuleConfig['modulefile']}"
		elif [[ -e "${BUILDBLOCK_DIR}/modulefile" ]]; then
			src="${BUILDBLOCK_DIR}/modulefile"
		else
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"skipping modulefile installation ..."
			return
		fi
		std::info \
			"%s " \
			"${module_name}/${module_version}:" \
			"adding modulefile to overlay '${ol_name}' ..."
		mkdir -p "${modulefile_dir}"
		install -m 0644 "${src}" "${modulefile_name}"
	}

	#..............................................................
	bm::install_runtime_dependencies() {
		local -r __doc__="Install runtime dependencies."
		_write_file(){
			local -r fname="$1"
			shift
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"writing run-time dependencies to ${fname} ..."
			echo -n "" > "${fname}"
			local -- dep=''
			for dep in "$@"; do
				[[ -z $dep ]] && continue
				if [[ ! $dep == */* ]]; then
					# no version given: derive the version
					# from the currently loaded module
					dep=$( modulecmd bash list -t 2>&1 1>/dev/null \
						       | grep "^${dep}/" )
				fi
				echo "${dep}" >> "${fname}"
			done
		}
		rm -f "${PREFIX}/${FNAME_RDEPS}"
		rm -f "${modulefile_dir}/.deps-${module_version}"
		rm -f "${PREFIX}/${FNAME_IDEPS}"
		if (( ${#runtime_dependencies[@]} > 0 )); then
			if [[ "${ol_name}" == 'base' ]]; then
				_write_file \
					"${PREFIX}/${FNAME_RDEPS}" \
					"${runtime_dependencies[@]}"
			fi
			_write_file \
				"${modulefile_dir}/.deps-${module_version}" \
				"${runtime_dependencies[@]}"
		fi
		if (( ${#install_dependencies[@]} > 0 )); then
			_write_file \
				"${PREFIX}/${FNAME_IDEPS}" \
				"${install_dependencies[@]}"
		fi

	}

	#..............................................................
	bm::set_relstages() {
		local __doc__='
		      Set/update release stages.
		      '
		[[ "${Options['is_subpkg']}" == 'yes' ]] && return 0

		#
		# update .config-${module_version}
		#
 		local -r yaml_config_file="${modulefile_dir}/.config-${module_version}"
		local -- relstage='new'
		if [[ -r "${yaml_config_file}" ]]; then
			while read -r key value; do
				local -n ref="${key:0:-1}"
				ref="${value}"
			done < "${yaml_config_file}"
		fi
		if [[ "${relstage}" != "${module_release}" ]]; then
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"changing release stage from" \
				"'${relstage}' to '${module_release}' ..."
		else
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"setting release stage to '${module_release}' ..."
		fi

		echo "relstage: ${module_release}" > "${yaml_config_file}"
		if (( ${#Systems[@]} > 0 )); then
			echo -n "systems: [${Systems[0]}" >> "${yaml_config_file}"
			local -- system=''
			for system in "${Systems[@]:1}"; do
				echo -n ", ${system}" >> "${yaml_config_file}"
			done
			echo "]" >> "${yaml_config_file}"
		fi

		#
		# Update .modulerc
		#
		local -r modulerc_file="${modulefile_dir}/.modulerc"
		echo '#%Module' > "${modulerc_file}"
		echo 'if {[info exists ModuleTool] && $ModuleTool == {Modules}} {' \
		     >> "${modulerc_file}"

		while read config_file; do
			local version="${config_file##*/}"
			version="${version/.config-}"
			local name="${module_name}/${version}"
			local relstage=$(awk '/relstage:/ {print $2}' "${config_file}")
			case ${relstage} in
				unstable )
					echo "   module-tag u ${name}" \
					     >> "${modulerc_file}"
					;;
				deprecated )
					echo "   module-tag d ${name}" \
					     >> "${modulerc_file}"
					;;
			esac
		done < <(find "${modulefile_dir}"  -type f -name '.config-*')
		echo '}' >> "${modulerc_file}"
	}

	#..............................................................
	bm::cleanup_modulefiles(){
		#
		# FIXME: Can it happen, that we remove module-/config-files which
		#        we shouldn't remove?
		#        For now we exclude removing from the overlay 'base' only
		#	 This function is only called if the option '--cleanup-modulefiles'
		#	 was specified.
		#
		[[ "${Options['is_subpkg']}" == 'yes' ]] && return 0
		local -- ol=''
		for ol in "${Overlays[@]}"; do
			[[ "${ol}" == "${ol_name}" ]] && continue
			[[ "${ol}" == 'base' ]] && continue
			local -- modulefiles_root="${OverlayInfo[${ol}:modulefiles_root]}"
			local -- dir="${modulefile_dir/${ol_modulefiles_root}/${modulefiles_root}}"
			local -- fname="${dir}/${module_version}"
			if [[ -e "${fname}" ]]; then
				std::info "%s "\
					  "${module_name}/${module_version}:" \
					  "removing modulefile from overlay '${ol}' ..."
				rm -f  "${fname}"
			fi
			fname="${dir}/.release-${module_version}"
			if [[ -e "${fname}" ]]; then
				std::info \
					"%s " \
					"${module_name}/${module_version}:" \
					"removing release file from overlay '${ol}' ..."
				rm -f "${fname}"
			fi
		done
	}

	#..............................................................
	bm::cleanup_build() {
		[[ ${Options['cleanup_build']} != 'yes' ]] && return 0
		[[ "${BUILD_DIR}" == "${SRC_DIR}" ]] && return 0
		[[ -d "${BUILD_DIR}/../.." ]] || return 0
		{
			cd "/${BUILD_DIR}/.." || std::die 42 "Internal error"
			[[ "$(pwd)" == "/" ]] && \
				std::die 1 \
					 "%s " "${module_name}/${module_version}:" \
					 "Oops: internal error:" \
			     		 "BUILD_DIR is set to '/'"

			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"Cleaning up '${BUILD_DIR}'..."
			rm -rf "${BUILD_DIR##*/}"
		};
		return 0
	}

	#..............................................................
	bm::cleanup_src() {
		[[ ${Options['cleanup_src']} != 'yes' ]] && return 0
		[[ -d "${BUILD_DIR}/../.." ]] || return 0
    		{
			cd "/${SRC_DIR}/.." || std::die 42 "Internal error"
			[[ $(pwd) == / ]] && \
				std::die 1 \
					 "%s " "${module_name}/${module_version}:" \
					 "Oops: internal error:" \
			     		 "SRC_DIR is set to '/'"
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"Cleaning up '${SRC_DIR}'..."
			rm -rf "${SRC_DIR##*/}"
   		};
		return 0
	}

	#......................................................................
	# build module ${module_name}/${module_version}
	bm::compile_and_install() {
		build_target() {
			local -- dir="$1"		# src or build directory, depends on target
			local -- target="$2"	# prep, configure, compile or install

			if [[ -e "${BUILD_DIR}/.${target}" ]] && \
				   [[ ${Options['force_rebuild']} == 'no' ]]; then
				return 0
			fi
			local -- t=''
			if (( ${#ModuleConfig[target_funcs:${target}]} == 0 )); then
				touch "${BUILD_DIR}/.${target}"
				return 0
			fi
			local -A target_info=(
				[prep]='preparing sources'
				[configure]='configuring'
				[compile]='compiling'
				[install]='installing'
			)
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"${target_info[${target}]} ..."
			local -- t=''
			for t in ${ModuleConfig[target_funcs:${target}]}; do
				# We cd into the dir before calling the function -
				# just to be sure we are in the right directory.
				#
				# Executing the function in a sub-process doesn't
				# work because in some function global variables
				# might/need to be set.
				#
				cd "${dir}"
				if typeset -F "$t" 2>/dev/null; then
					"$t" || std::die 10 "Aborting..."
				else
					std::die 10 "Function is not defined -- $t"
				fi
			done
			touch "${BUILD_DIR}/.${target}"
		} # build_target()

		mkdir -p "${SRC_DIR}"
		mkdir -p "${BUILD_DIR}"

		build_target "${SRC_DIR}" prep
		[[ "${Options['build_target']}" == "prep" ]] && return 0

		build_target "${BUILD_DIR}" configure
		[[ "${Options['build_target']}" == "configure" ]] && return 0

		build_target "${BUILD_DIR}" compile
		[[ "${Options['build_target']}" == "compile" ]] && return 0

		mkdir -p "${PREFIX}"
		build_target "${BUILD_DIR}" install
	} # bm::compile_and_install()

	#......................................................................
	bm::remove_module() {
		if [[ -d "${PREFIX}" ]]; then
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"removing all files in '${PREFIX}' ..."
			rm -rf "${PREFIX}"
		fi
		if [[ -e "${modulefile_name}" ]]; then
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"removing modulefile '${modulefile_name}' ..."
			rm -vf "${modulefile_name}"
		fi
		local -- release_file="${modulefile_dir}/.release-${module_version}"
		if [[ -e "${release_file}" ]]; then
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"removing release file '${release_file}' ..."
			rm -vf "${release_file}"
		fi
		release_file="${modulefile_dir}/.config-${module_version}"
		if [[ -e "${release_file}" ]]; then
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"removing release file '${release_file}' ..."
			rm -vf "${release_file}"
		fi
		rmdir -p "${modulefile_dir}" 2>/dev/null || :
	}

	#......................................................................
	bm::deprecate_module(){
		std::info \
			"%s " \
			"${module_name}/${module_version}:" \
			"is deprecated, skiping!"
		bm::set_relstages
	}

	#......................................................................
	die_sub_package_name_missing(){
		std::die 3 "Name of sub-package not specified in \n===\n$1\n===\n"
	}
	die_sub_package_version_missing(){
		std::die 3 "Version of sub-package not specified in \n===\n$1\n===\n"
	}
	bm::build_sub_packages(){
		[[ "${Options['skip_subpkgs']}" == 'yes' ]] && return 0

		local -- sub_packages_yml="$1"

		[[ -n "${sub_packages_yml}" ]] || return 0

		# get no of sub-packages to build
		local -i l=0
		yml::get_seq_length l sub_packages_yml .
		(( l == 0 )) && return 0

		std::info "\n %d sub-package(s) to build..." "$l"
		local -i i=0
		local -- fname=''
		for ((i=0; i<l; i++)); do
			local -- node=".[$i]"
			local -- pkg_name=''
			local -- pkg_version=''
			local -a pkg_build_args=()

			local -- key=''
			local -a keys=()
			yml::get_keys keys sub_packages_yml "${node}"
			for key in "${keys[@]}"; do
				case ${key,,} in
					'name' )
						yml::get_value \
							pkg_name \
							sub_packages_yml \
							"${node}.${key}" \
							'!!str'
						;;
					'version' )
						yml::get_value \
							pkg_version \
							sub_packages_yml \
							"${node}.${key}" \
							'!!str'
						;;
					'build_args' )
						local -- value=''
						yml::get_seq \
							value \
							sub_packages_yml \
							"${node}.${key}"
						readarray -t pkg_build_args <<< "${value}"
						;;
					* )
						die_invalid_key \
							"${sub_packages_yml}" \
							"in subpackage '$i'" \
							"${key}"
						;;
				esac
			done
			[[ -n "${pkg_name}" ]] || \
				die_sub_package_name_missing "${sub_packages_yml}"
			[[ -n "${pkg_version}" ]] || \
				die_sub_package_version_missing "${sub_packages_yml}"

			(( Options['verbose'] > 0 )) && \
				pkg_build_args+=( '--verbose' )
			[[ "${Options['debug']}" == 'yes' ]] && \
				pkg_build_args+=( '--debug' )
			[[ "${Options['force_rebuild']}" == 'yes' ]] && \
				pkg_build_args+=( '-f' )
			pkg_build_args+=( "--parent-prefix=${PREFIX}" )
			"$BUILDBLOCK_DIR/build-${pkg_name}" \
				"${pkg_name}/${pkg_version}" \
				"${pkg_build_args[@]}" || \
				std::die 255 "Building sub-package failed - ${pkg_name}/${pkg_version}"
		done
	}

	std::info \
		"%s " \
		"${module_name}/${module_version}:" \
		${with_modules:+with ${with_modules[@]}}

	bm::load_overlays
	bm::load_build_dependencies
	BUILD_ROOT="${PMODULES_TMPDIR}/${module_name}-${module_version}"
	SRC_DIR="${BUILD_ROOT}/src"
	if [[ "${ModuleConfig['compile_in_sourcetree']}" == 'yes' ]]; then
		BUILD_DIR="${SRC_DIR}"
	else
		BUILD_DIR="${BUILD_ROOT}/build"
	fi

	source "${BUILD_SCRIPT}"
	
	# module name including path in hierarchy and version
	# (ex: 'gcc/6.1.0/openmpi/1.10.2' for openmpi compiled with gcc 6.1.0)
	local -- modulefile_dir=''
	local -- modulefile_name=''

	if [[ "${Options['is_subpkg']}" != 'yes' ]]; then
		bm::set_full_module_name_and_prefix
	else
		PREFIX="${Options['prefix']}"
	fi
	# ok, finally we can start ...
	if [[ "${module_release}" == 'remove' ]]; then
		bm::remove_module
	elif [[ "${module_release}" == 'deprecated' ]]; then
		bm::deprecate_module
	elif [[ -d "${PREFIX}" && \
			"${Options['is_subpkg']}" != 'yes' && \
			"${Options['force_rebuild']}" == 'no' ]]; then
 		std::info \
			"%s " \
			"${module_name}/${module_version}:" \
			"already exists, not rebuilding ..."
		if [[ "${Options['update_modulefiles']}" == 'yes' ]]; then
			bm::install_module_config
			bm::install_runtime_dependencies
			bm::set_relstages
		elif [[ "${Options['update_relstage']}" == 'yes' ]]; then
			bm::set_relstages
		else
 			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"modulefile and configuration are not updated."
		fi
	else
		if [[ "${Options['clean_install']}" == 'yes' ]]; then
			std::info \
				"%s " \
				"${module_name}/${module_version}:" \
				"remove module, if already exists ..."
			bm::remove_module
		fi
		std::info \
			"%s " \
			"${module_name}/${module_version}:" \
			"start building ..."
		bm::cleanup_build
		bm::cleanup_src
		bm::compile_and_install
		bm::post_install
		bm::install_module_config
		bm::install_runtime_dependencies
		bm::set_relstages
		bm::cleanup_build
		bm::cleanup_src
		bm::build_sub_packages "${ModuleConfig['sub_packages']}"

	fi
	if [[ "${Options['cleanup_modulefiles']}" == 'yes' ]]; then
		bm::cleanup_modulefiles
	fi
 	std::info \
		"%s\n%s" \
		"${module_name}/${module_version}: done" \
		"* * * * *"
}
readonly -f _build_module

# Local Variables:
# mode: sh
# sh-basic-offset: 8
# tab-width: 8
# End:
