#!/bin/bash

#.............................................................................
# disable auto-echo feature of 'cd'
unset CDPATH

#.............................................................................
# define constants

# relative path of documentation
# abs. path is "${PREFIX}/${_docdir}/${module_name}"
declare -r  _DOCDIR='share/doc'

# default value for patch -pN
declare -r PATCH_STRIP_DEFAULT='1'

#.............................................................................

#******************************************************************************
#
# function in the "namespace" (with prefix) 'pbuild::' can be used in
# build-scripts
#

#..............................................................................
#
# Test whether a module with the given name is available. If yes, return
# release stage in second argument.
#
# Arguments:
#   $1: module name
#   $2: optional variable name to return release stage
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
        local -- relstage=''
        if [[ -v PMODULES_HOME ]]; then
                local -r output=$(modulecmd bash avail -a -m "$1" 2>&1 1>/dev/null)
                while read -r name relstage; do
                        if [[ "${name}" == "$1" || "${name}" == "${1}.lua" ]]; then
                                if (( $# > 1 )); then
                                        local -n _relstage="$2"
                                        _relstage="${relstage}"
                                fi
                                return 0
                        fi
                done <<<"${output}"
                return 1
        else
                local -r output=$(modulecmd bash avail --all --output=tag --terse "$1" 2>&1)
                while read -r name relstage; do
                        if [[ "${name}" == "$1" || "${name}" == "${1}.lua" ]]; then
                                case ${relstage} in
                                        '<d>'|'<d:'*|*':d>'|*':d:'* )
                                        relstage='deprecated'
                                        ;;
                                '<u>'|'<u:'*|*':u>'|*':u:'* )
                                        relstage='unstable'
                                        ;;
                                * )
                                        relstage='stable'
                                esac
                                if (( $# > 1 )); then
                                        local -n _relstage="$2"
                                        _relstage="${relstage}"
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
        [[ " ${ModuleConfig['use_flags']} " == *" ${1} "* ]]
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
                        std::die 1 "Unsupported tool for unpacking -- '${unpacker}'"
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
        local -r mod_namevers="${ModuleConfig['name']}/${ModuleConfig['version']}"

        local -i i=0 num_sources="${ModuleConfig['num_sources']}"
        for ((i=0; i<num_sources; i++)); do
                local -- url=''
                if [[ -n "${ModuleConfig[url:$i]}" ]]; then
                        url=$(envsubst <<<"${ModuleConfig[url:$i]}")
                else
                        url=''
                fi
                local -- fname=''
                if [[ -n "${ModuleConfig[name:$i]}" ]]; then
                        fname=$(envsubst <<<"${ModuleConfig[name:$i]}")
                elif [[ -n "${url}" ]]; then
                        fname="${url##*/}"
                fi

                if [[ -n "${fname}" ]]; then
                        local -- strip_dirs="${ModuleConfig[strip_dirs:$i]}"
                        local -- unpacker="${ModuleConfig[unpacker:$i]}"
                        local -- unpack_dir="${SRC_DIR}"
                        if [[ -n "${ModuleConfig[unpack_dir:$i]}" ]]; then
                                unpack_dir=$(envsubst <<<"${ModuleConfig[unpack_dir:$i]}")
                        fi

                        local -- src_dir=''
                        src_dir=$(pbcore::search_source_file "${fname}")
			if (( $? != 0 )); then
                                if [[ -n "${url}" ]]; then
                                        src_dir="${PMODULES_DISTFILESDIR}"
                                        pbcore::download_source_file \
                                                "${src_dir}" \
                                                "${url}" \
                                                "${fname}"
                                fi
                        fi
                        pbcore::check_hash_sum \
                                "${src_dir}" \
                                "${fname}"
                        pbcore::unpack \
                                "${src_dir}" \
                                "${fname}" \
                                "${unpack_dir}" \
                                "${strip_dirs}" \
                                "${unpacker}"

                fi
                if [[ -n "${ModuleConfig[patch_file:$i]}" ]]; then
                        local -- patch_file=$(envsubst <<<"${ModuleConfig[patch_file:$i]}")
                        local -- patch_strip="${ModuleConfig[patch_strip:$i]:-${PATCH_STRIP_DEFAULT}}"

                        local -- src_dir=''
                        src_dir="$(pbcore::search_source_file "${patch_file}")" || \
                                std::die 42 \
                                         "%s " \
                                         "${mod_namevers}:" \
                                         "patch file '${patch_file}' not found!"
                        local -- unpack_dir="${SRC_DIR}"
                        if [[ -n "${ModuleConfig[unpack_dir:$i]}" ]]; then
                                unpack_dir=$(envsubst <<<"${ModuleConfig[unpack_dir:$i]}")
                        fi
                        mkdir -p "${unpack_dir}"

                        pbcore::apply_patch \
                                "${src_dir}" \
				"${patch_file}" \
                                "${patch_strip}" \
                                "${unpack_dir}"
                fi
        done
        pbcore::patch_sources
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
declare -a CONFIGURE_ARGS=()
pbuild::add_configure_args(){
        CONFIGURE_ARGS+=( "$@" )
}
readonly -f pbuild::add_configure_args

#..............................................................................
#
# Configure the software to be compiled.
#
# Arguments:
#       none
#
pbuild::pre_configure() {
        :
}
pbuild::post_configure() {
        :
}
pbuild::configure() {
        local -r mod_namevers="${ModuleConfig['name']}/${ModuleConfig['version']}"
        local -r configure_with="${ModuleConfig['configure_with']}"
        case "${configure_with}" in
                autotools )
                        if [[ ! -r "${SRC_DIR}/configure" ]]; then
                                std::die 3 \
                                         "%s " "${mod_namevers}:" \
                                         "${FUNCNAME[0]}:" \
                                         "autotools configuration not available, aborting..."
                        fi
                        ;;
                cmake )
                        if [[ ! -r "${SRC_DIR}/CMakeLists.txt" ]]; then
                                std::die 3 \
                                         "%s " "${mod_namevers}:" \
                                         "${FUNCNAME[0]}:" \
                                         "CMake script not available, aborting..."
                        fi
                        ;;
        esac
        local -a config_args=()
        local -a config_args=()
        if [[ -n "${ModuleConfig['configure_args']}" ]]; then
                readarray -t config_args <<< "${ModuleConfig['configure_args']}"
        fi
        config_args+=( "${CONFIGURE_ARGS[@]}")
        local -i i=0 n=${#config_args[@]}
        for ((i=0; i<n; i++)); do
                config_args[i]="$(envsubst <<<"${config_args[i]}")"
        done
        if [[ -r "${SRC_DIR}/configure" ]] && \
                   [[ "${configure_with}" == 'auto' ]] || \
                           [[ "${configure_with}" == 'autotools' ]]; then
                std::info "%s " "${SRC_DIR}/configure --prefix=${PREFIX} ${config_args[*]}"
                "${SRC_DIR}/configure" \
                          --prefix="${PREFIX}" \
                          "${config_args[@]}" || \
                        std::die 3 \
                                 "%s " "${mod_namevers}:" \
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
                                 "%s " "${mod_namevers}:" \
                                 "cmake failed"
        else
                std::info \
                        "%s " \
                        "${mod_namevers}:" \
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
#       none
#
pbuild::pre_compile() {
        :
}
pbuild::post_compile() {
        :
}
pbuild::compile() {
        local -r mod_namevers="${ModuleConfig['name']}/${ModuleConfig['version']}"

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
                         "%s " "${mod_namevers}:" \
                         "compilation failed!"
        declare -gx V="${tmp_v}"
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
#       none
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
        local -- script
        for script in "${scripts[@]}"; do
                sed -i "1s|^#!.*|#!${PREFIX}/.bin/python3|" "${script}"
        done
}

pbuild::install() {
        local -r mod_namevers="${ModuleConfig['name']}/${ModuleConfig['version']}"

        make install || \
                std::die 3 \
                         "%s " "${mod_namevers}:" \
                         "compilation failed!"
}

#..............................................................................
#
pbuild::install_shared_libs() {
        local -r binary="$1"
        local -r dstdir="$2"
        local -r pattern="${3//\//\\/}" # escape slash

        local -r mod_namevers="${ModuleConfig['name']}/${ModuleConfig['version']}"

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
                mapfile -t libs < <(otool -L "${binary}" | \
                                       awk "/${pattern}/ {print \$1}")
                if (( ${#libs[@]} > 0 )); then
                        cp -vL "${libs[@]}" "${dstdir}" || return $?
                fi
                return 0
        }

        test -e "${binary}" || \
                std::die 3 \
                         "%s " "${mod_namevers}:" \
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

##
## pbcore::search_source_file - search for file in default directories
##
## Arguments:
##   $1 - relative file name
##
## Returns:
##   0 - if found; echo directory to stdout
##   1 - otherwise; echo empty string to stdout
##
## Used global variables:
##   PMODULES_DISTFILESDIR
##   BUILDBLOCK_DIR
##
pbcore::search_source_file(){
        local -r fname="$1"

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
                        echo "${dir}"
                        return 0
                fi
        done
        echo ''
        return 1
}

##
## pbcore::download_source_file - download file from given URL
##
## Arguments:
##   $1 - target directory
##   $2 - URL
##   $3 - file name to be used to save the file
##
## Used global variables:
##   ModuleConfig
##
pbcore::download_source_file() {
        local -r target_dir="$1"
        local -r url="$2"
        local -r fname="$3"

        mkdir -p "${target_dir}"
        curl \
                --location \
                --fail \
                --output "${target_dir}/${fname}" \
                "${url}" || \
                std::die 42 \
                         "%s " \
                         "${ModuleConfig['namevers']}:" \
                         "downloading source file '${fname}' failed!"

        # :FIXME: How to handle insecure downloads?
        #if (( $? != 0 )); then
        #       curl \
                #               --insecure \
                #               --output "${fname}" \
                #               "${url}"
        #fi
}

##
## pbcore::unpack - unpack given file
##
## Arguments:
##   $1 - source directory file
##   $2 - relative file name (to source directory)
##   $3 - target directory (if supported by tool)
##   $4 - directories to strip while unpacking (if supported by tool)
##   $5 - the tool to use (tar, zip, ...)
##
## Used global variables:
##   ModuleConfig
##   BUILDBLOCK_DIR
##
pbcore::unpack() {
        local -r src_dir="$1"
        local -r fname="${src_dir}/$2"
        local -r target_dir="$3"
        local -r strip="$4"
        local -r unpacker="$5"

        if ! pbuild::unpack "${fname}" "${target_dir}" "${strip}" "${unpacker}"; then
                if [[ -n "${src_dir}" && "${src_dir}" != "${BUILDBLOCK_DIR}" ]]; then
                        rm -f "${fname}"
                fi
                std::die 4 \
                         "%s " \
                         "${ModuleConfig['namevers']}:" \
                         "cannot unpack file" \
                         "${fname}!"
        fi
}

##
## pbcore::check_hash_sum - check the SHA256 hash-sum of a file
##
## Arguments:
##   $1 - absolut file name
##
## Used global variables:
##   ModuleConfig
##
pbcore::check_hash_sum() {
        local -r  src_dir="$1"
        local -r fname="$2"

        if [[ -v ModuleConfig[shasum:${fname}] ]]; then
                local -- hash_sum=''
                hash_sum=$(sha256sum "${src_dir}/${fname}" | awk '{print $1}')
                test "${hash_sum}" == "${ModuleConfig[shasum:${fname}]}" || \
                        std::die 42 \
                                 "%s " \
                                 "${ModuleConfig['namevers']}:" \
                                 "SHA256 hash mismatch for file '${fname}'!"
                std::info "%s " "${ModuleConfig['namevers']}: SHA256 hash sum is OK ..."
        else
                std::info "%s " "${ModuleConfig['namevers']}: SHA256 hash sum missing NOK ..."
        fi
}

##
## pbcore::apply_patch - apply a single patch
##
## Arguments:
##   $1 - absolut file name
##   $2 - strip this number of directories
##   $3 - target directory
##
## Used global variables:
##   ModuleConfig
##
pbcore::apply_patch(){
	local -r src_dir="$1"
        local -r fname="$2"
        local -r strip="$3"
        local -r target_dir="$4"

        std::info \
                "%s " \
                "${ModuleConfig['namevers']}:" \
                "Applying patch '${fname}' ..."
        patch \
                --strip="${strip}" \
                --directory="${target_dir}" < "${src_dir}/${fname}" || \
                std::die 4 \
                         "%s " \
                         "${ModuleConfig['namevers']}:" \
                         "error patching sources!"
}

##
## pbcore::patch_sources - apply patches listed in configuration
##
## Each patch-file entry has the form file_name[:strip]
##
## Arguments:
##   none
##
## Used global variable:
##   ModuleConfig
##   PATCH_STRIP_DEFAULT
##   BUILDBLOCK_DIR
##   SRC_DIR
##
pbcore::patch_sources() {
        [[ -n "${ModuleConfig['patch_files']}" ]] || return 0

        local -a patch_files=()
        readarray -t patch_files <<< "${ModuleConfig['patch_files']}"
        local -- patch_file=''
        for patch_file in "${patch_files[@]}"; do
                [[ -z "${patch_file}" ]] && continue
                local -i patch_strip="${PATCH_STRIP_DEFAULT}"
                if [[ ${patch_file} == *:* ]]; then
                        patch_strip="${patch_file##*:}"
                        patch_file="${patch_file%%:*}"
                fi
                pbcore::apply_patch \
                        "${BUILDBLOCK_DIR}" \
			"${patch_file}" \
                        "${patch_strip}" \
                        "${SRC_DIR}"
        done
}

##
## pbcore::is_loaded - test whether a module is loaded or not
##
## Arguments:
##   $1 -       module name
##
## Returns:
##   0 - if module is loaded
##   1 - otherwise
##
pbcore::is_loaded() {
        [[ -v LOADEDMODULES ]] || return 1
        [[ :${LOADEDMODULES}: == *":$1:"* ]] && return 0
        [[ :${LOADEDMODULES}: == *":$1.lua:"* ]] && return 0
        return 1
}

##
## pbcore::load_overlays - load overlays defined in config.yaml
##
## Arguments:
##   none
##
## Returns:
##   0
##
## Global variables:
##   ModuleConfig
##
pbcore::load_overlays(){
        local -n config="$1"

        [[ -n ${config['use_overlays']} ]] || return 0

        local -a use_overlays=()
        readarray -t use_overlays <<< "${config['use_overlays']}"

        std::info "%s " \
                  "using overlays ${use_overlays[*]}"
        eval "$( modulecmd bash use "${use_overlays[@]}" )"
}

##
## pbcore::load_dependencies - Load dependencies.
##
## Arguments:
##   $1 - module name
##   $2 - module version
##   $3 - release stage of module
##   $4... - dependencies
##
pbcore::load_dependencies() {
        local -n config="$1"
        shift 1

        local -a build_requires=()
        if [[ -n ${module_config['build_requires']} ]]; then
                readarray -t build_requires <<<"${module_config['build_requires']}"
        fi

        local -ar dependencies+=( "$@" "${build_requires[@]}" )

        local -- m=''
        for m in "${dependencies[@]}"; do
                pbcore::is_loaded "$m" && continue
                local -- relstage_of_dependency=''
                pbuild::module_is_avail "$m" relstage_of_dependency || \
                        std::die 6 "Module is not available - $m"

                # for a stable module all dependencies must be stable
                if [[ "${config['relstage']}" == 'stable' ]] \
                           && [[ "${relstage_of_dependency}" != 'stable' ]]; then
                        std::die 5 \
                                 "%s " "${config['name']}/${config['version']}:" \
                                 "release cannot be set to '${config['relstage']}'" \
                                 "since the dependency '$m' is ${relstage_of_dependency}"
                        # for a unstable module no dependency must be deprecated
                elif [[ "${config['relstage']}" == 'unstable' ]] \
                             && [[ "${relstage_of_dependency}" == 'deprecated' ]]; then
                        std::die 5 \
                                 "%s " "${config['name']}/${config['version']}:" \
                                 "release cannot be set to '${config['relstage']}'" \
                                 "since the dependency '$m' is ${relstage_of_dependency}"
                fi

                std::info "%s" "Loading module: ${m}"
                local output="$(modulecmd bash load "${m}")";
                eval "${output}"
                if ! pbcore::is_loaded "$m"; then
                        std::die 5 \
                                 "%s " "${m}:" \
                                 "module cannot be loaded!"
                fi
        done
}

##
## compute full module name and installation prefix
##
## The following variables are expected to be set:
##       variables defining the hierarchical environment like
##      COMPILER and COMPILER_VERSION
##
##
pbcore::set_mod_dir_and_prefix() {
        local -n config="$1"
        local -n prefix="$2"

        local -r mod_name="${config['name']}"
        local -r mod_version="${config['version']}"
        local -r group="${config['group']}"
        local -r ol_name="${config['overlay']}"
        local -r ol_install_root="${OverlayInfo[${ol_name}:install_root]}"
        local -r ol_modulefiles_root="${OverlayInfo[${ol_name}:modulefiles_root]}"

        die_no_compiler(){
                std::die 1 \
                         "%s: %s" \
                         "${mod_name}/${mod_version}" \
                         "module is in group '${group}' but no compiler loaded!"
        }
        die_no_mpi(){
                std::die 1 \
                         "%s: %s" \
                         "${mod_name}/${mod_version}" \
                         "module is in group '${group}' but no MPI module loaded!"
        }
        die_no_hdf5(){
                std::die 1 \
                         "%s: %s" \
                         "${mod_name}/${mod_version}" \
                         "module is in group '${group}' but no HDF5 module loaded!"
        }

        local -- mod_dir="${ol_modulefiles_root}/${group}/${__MODULEFILES_DIR__}/"
        prefix="${ol_install_root}/${group}/${mod_name}/${mod_version}/"
        case "${group,,}" in
                compiler )
                        [[ -v COMPILER && -v COMPILER_VERSION ]] || die_no_compiler
                        mod_dir+="${COMPILER}/${COMPILER_VERSION}/"
                        prefix+="${COMPILER}/${COMPILER_VERSION}/"
                        ;;
                mpi )
                        [[ -v COMPILER && -v COMPILER_VERSION ]] || die_no_compiler
                        [[ -v MPI && -v MPI_VERSION ]] || die_no_mpi
                        mod_dir+="${COMPILER}/${COMPILER_VERSION}/"
                        mod_dir+="${MPI}/${MPI_VERSION}/"
                        prefix+="${MPI}/${MPI_VERSION}/"
                        prefix+="${COMPILER}/${COMPILER_VERSION}/"
                        ;;
                hdf5 )
                        [[ -v COMPILER && -v COMPILER_VERSION ]] || die_no_compiler
                        [[ -v MPI && -v MPI_VERSION ]] || die_no_mpi
                        [[ -v HDF5 && -v HDF5_VERSION ]] || die_no_hdf5
                        mod_dir+="${COMPILER}/${COMPILER_VERSION}/"
                        mod_dir+="${MPI}/${MPI_VERSION}/"
                        mod_dir+="hdf5/${HDF5_VERSION}/"
                        prefix+="hdf5/${HDF5_VERSION}/"
                        prefix+="${MPI}/${MPI_VERSION}/"
                        prefix+="${COMPILER}/${COMPILER_VERSION}/"
                        ;;
                hdf5_serial )
                        [[ -v COMPILER && -v COMPILER_VERSION ]] || die_no_compiler
                        [[ -v HDF5_SERIAL && -v HDF5_SERIAL_VERSION ]] || die_no_hdf5
                        mod_dir+="${COMPILER}/${COMPILER_VERSION}/"
                        mod_dir+="hdf5_serial/${HDF5_SERIAL_VERSION}/"
                        prefix+="hdf5_serial/${HDF5_SERIAL_VERSION}/"
                        prefix+="${COMPILER}/${COMPILER_VERSION}/"
                        ;;
                * )
                        :
                        ;;
        esac
        mod_dir+="${mod_name}"
        config['modulefile_dir']="${mod_dir}"
}

#......................................................................
# post-install.
#
# Arguments:
#       none
pbcore::post_install() {
        local -n config="$1"

        local -r mod_name="${config['name']}"
        local -r mod_version="${config['version']}"

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
                local -r docdir="${PREFIX}/${_DOCDIR}/${mod_name}"
                std::info \
                        "%s " \
                        "${mod_name}/${mod_version}:" \
                        "installing documentation to ${docdir}"
                install -m 0755 -d "${docdir}"
                install -m 0644 "${BUILD_SCRIPT}" "${docdir}"
                modulecmd bash list -t 2>&1 1>/dev/null | \
                        grep -v "Currently Loaded" > \
                             "${docdir}/dependencies" || :
                [[ -n ${config['docfiles']} ]] || return 0
                local -a docfiles=()
                readarray -t docfiles <<<"${config['docfiles']}"
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
                        "${mod_name}/${mod_version}:" \
                        "running post-installation for ${KERNEL_NAME} ..."
                (
                        cd "${PREFIX}" || \
                                std::die 4 "%s " \
                                         "Changing to directory '${PREFIX}' failed!"
                        [[ -d "lib" ]] && [[ ! -d "lib64" ]] && ln -s lib lib64
                );
                return 0
        }

        #..............................................................
        # post-install
        cd "${BUILD_DIR}" || std::die 4 "%s " \
                                      "Changing to directory '${BUILD_DIR}' failed!"
        [[ "${KERNEL_NAME}" == "Linux" ]] && post_install_linux
        install_doc
        return 0
}

#......................................................................
pbcore::install_module_config(){
        local -n config="$1"

        [[ "${Options['is_subpkg']}" == 'yes' ]] && return 0

        local -- src=''
        if [[ -n "${config['modulefile']}" ]]; then
                if [[ ! -e "${config['modulefile']}" ]]; then
                        std::die 3 \
                                 "%s " \
                                 "${config['name']}/${config['version']}:" \
                                 "modulefile '${config['modulefile']}" \
                                 "does not exist!"
                fi
                src="${config['modulefile']}"
        elif [[ -e "${BUILDBLOCK_DIR}/modulefile" ]]; then
                src="${BUILDBLOCK_DIR}/modulefile"
        else
                std::info \
                        "%s " \
                        "${config['name']}/${config['version']}:" \
                        "skipping modulefile installation ..."
                return
        fi
        std::info \
                "%s " \
                "${config['name']}/${config['version']}:" \
                "adding modulefile to overlay '${config[overlay]}' ..."
        mkdir -p "${config['modulefile_dir']}"
        install -m 0644 "${src}" "${config['modulefile_dir']}/${config['version']}"
}

#..............................................................
pbcore::install_runtime_dependencies() {
        local -n config="$1"
        shift

        local -a runtime_deps=()
        if [[ -n ${module_config['runtime_deps']} ]]; then
                readarray -t runtime_deps <<<"${module_config['runtime_deps']}"
        fi
        local -a dependencies=( "$@" "${runtime_deps[@]}" )


        # We remove the file even if the module has no dependencies - just in
        # case an older version had dependencies.
        local -r fname="${config['modulefile_dir']}/.deps-${config['version']}"
        rm -f "${fname}"
        (( ${#dependencies[@]} == 0 )) && return

        std::info \
                "%s " \
                "${config['name']}/${config['version']}:" \
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

##
## pbcore::set_relstages - set the release stage
##
## :FIXME: this function must be reviewed/rewritten after switching to
## Tcl Environment Modules!
##
## Arguments:
##   $1 - reference to module configuration
##
pbcore::set_relstages() {
        local -n config="$1"

        [[ "${Options['is_subpkg']}" == 'yes' ]] && return 0

        #
        # update .config-${module_version}
        #
        local -r yaml_config_file="${config['modulefile_dir']}/.config-${config['version']}"
        local -- relstage='new'
        if [[ -r "${yaml_config_file}" ]]; then
                relstage="$(awk '/relstage:/ {print $2}' "${yaml_config_file}")"
        fi
        if [[ "${relstage}" != "${config['relstage']}" ]]; then
                std::info \
                        "%s " \
                        "${config['name']}/${config['version']}:" \
                        "changing release stage from" \
                        "'${relstage}' to '${config['relstage']}' ..."
        else
                std::info \
                        "%s " \
                        "${config['name']}/${config['version']}:" \
                        "setting release stage to '${config['relstage']}' ..."
        fi

        echo "relstage: ${config['relstage']}" > "${yaml_config_file}"

        if [[ -n "${config['systems']}" ]]; then
                local -a systems=()
                readarray -t systems <<< "${config['systems']}"
                echo -n "systems: [${systems[0]}" >> "${yaml_config_file}"
                local -- system=''
                for system in "${systems[@]:1}"; do
                        echo -n ", ${system}" >> "${yaml_config_file}"
                done
                echo "]" >> "${yaml_config_file}"
        fi

        #
        # Update .modulerc
        #
        local -r modulerc_file="${config['modulefile_dir']}/.modulerc"
        echo '#%Module' > "${modulerc_file}"
        echo 'if {[info exists ModuleTool] && $ModuleTool == {Modules}} {' \
             >> "${modulerc_file}"

        local -- config_file
        while read -r config_file; do
                local version="${config_file##*/}"
                version="${version/.config-}"
                local name="${config['name']}/${version}"
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
        done < <(find "${config['modulefile_dir']}"  -type f -name '.config-*')
        echo '}' >> "${modulerc_file}"
}

#..............................................................
pbcore::cleanup_modulefiles(){
        local -n config="$1"

        #
        # FIXME: Can it happen, that we remove module-/config-files which
        #        we shouldn't remove?
        #        For now we exclude removing from the overlay 'base' only
        #        This function is only called if the option '--cleanup-modulefiles'
        #        was specified.
        #
        [[ "${Options['is_subpkg']}" == 'yes' ]] && return 0

        local -r ol_name="${config['overlay']}"
        local -r ol_modulefiles_root="${OverlayInfo[${ol_name}:modulefiles_root]}"
        local -r modulefile_dir="${config['modulefile_dir']}"
        local -r mod_namevers="${config['name']}/${config['version']}"

        local -- ol=''
        for ol in "${Overlays[@]}"; do
                [[ "${ol}" == "${ol_name}" ]] && continue
                [[ "${ol}" == 'base' ]] && continue
                local -- modulefiles_root="${OverlayInfo[${ol}:modulefiles_root]}"
                local -- dir="${modulefile_dir/#"${ol_modulefiles_root}"/${modulefiles_root}}"

                pbcore::remove_file \
                        "${dir}/${config['version']}" \
                        "${mod_namevers}: removing modulefile from overlay '${ol}' ..."
                pbcore::remove_file \
                        "${dir}/.release-${config['version']}" \
                        "${mod_namevers}: removing release file from overlay '${ol}' ..."
                pbcore::remove_file \
                        "${dir}/.config-${config['version']}" \
                        "${mod_namevers}: removing config file from overlay '${ol}' ..."
                pbcore::remove_file \
                        "${dir}/.deps-${config['version']}" \
                        "${mod_namevers}: removing dependencies file from overlay '${ol}' ..."
        done
}

#..............................................................
pbcore::cleanup_build() {
        local -n config="$1"

        [[ ${Options['cleanup_build']} != 'yes' ]] && return 0
        [[ "${BUILD_DIR}" == "${SRC_DIR}" ]] && return 0
        [[ -d "${BUILD_DIR}/../.." ]] || return 0
        cd "${BUILD_DIR}/.." || \
                std::die 4 "%s " \
                         "Changing to directory '${BUILD_DIR}/..' failed!"

        [[ "${PWD}" == '/' ]] && \
                std::die 255 \
                         "%s " "${config['name']}/${config['version']}:" \
                         "Oops: internal error:" \
                         "BUILD_DIR is set to '/'"
	[[ "${PWD}" == "${BUILDBLOCK_DIR}" ]] && return 0
        std::info \
                "%s " \
                "${config['name']}/${config['version']}:" \
                "Cleaning up build directory '${BUILD_DIR}' ..."
        rm -rf "${BUILD_DIR}" 1>&2
        return 0
}

#..............................................................
pbcore::cleanup_src() {
        local -n config="$1"

        [[ ${Options['cleanup_src']} != 'yes' ]] && return 0
        [[ -d "/${SRC_DIR}/.." ]] || return 0
        cd "${SRC_DIR}/.." || \
                std::die 4 "%s " \
                         "Changing to directory '${SRC_DIR}/..' failed!"
        [[ "${PWD}" == '/' ]] && \
                std::die 1 \
                         "%s " "${config['name']}/${config['version']}:" \
                         "Oops: internal error:" \
                         "SRC_DIR is set to '/'"
	[[ "${PWD}" == "${BUILDBLOCK_DIR}" ]] && return 0
        std::info \
                "%s " \
                "${config['name']}/${config['version']}:" \
                "Cleaning up source directory '${SRC_DIR}' ..."
        rm -rf "${SRC_DIR}" 1>&2
        return 0
}

#......................................................................
# build module ${module_name}/${module_version}
pbcore::compile_and_install() {
        local -n config="$1"

        build_target() {
                local -- dir="$1"       # src or build directory, depends on target
                local -- target="$2"    # prep, configure, compile or install

                if [[ -e "${BUILD_DIR}/.${target}" ]] && \
                           [[ ${Options['force_rebuild']} == 'no' ]]; then
                        return 0
                fi
                local -- t=''
                if (( ${#config[target_funcs:${target}]} == 0 )); then
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
                        "${config['name']}/${config['version']}:" \
                        "${target_info[${target}]} ..."
                local -- t=''
                for t in ${config[target_funcs:${target}]}; do
                        # We cd into the dir before calling the function -
                        # just to be sure we are in the right directory.
                        #
                        # Executing the function in a sub-process doesn't
                        # work because in some function global variables
                        # might/need to be set.
                        #
                        cd "${dir}" || \
                                std::die 4 "%s " \
                                         "Changing to directory '${dir}' failed!"

                        if typeset -F "$t" 1>/dev/null; then
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
}

pbcore::remove_file() {
        local -r fname="$1"
        local -r text="$2"
        if [[ -e "${fname}" ]]; then
                std::info \
                        "%s " \
                        "${text} '${fname}' ..."
                rm -vf "${fname}"
        fi
}

#......................................................................
pbcore::remove_module() {
        local -n rm_cfg="$1"
        local -r mod_namevers="${rm_cfg['name']}/${rm_cfg['version']}"

        if [[ -n "${PREFIX}" && -d "${PREFIX}" && "${PREFIX}" != '/' ]]; then
                std::info \
                        "%s " \
                        "${mod_namevers}:" \
                        "removing all files in '${PREFIX}' ..."
                rm -rf "${PREFIX}"
        fi
        pbcore::remove_file \
                "${rm_cfg['modulefile_dir']}/${rm_cfg['version']}" \
                "${mod_namevers}: removing modulefile"
        pbcore::remove_file \
                "${rm_cfg['modulefile_dir']}/.release-${rm_cfg['version']}" \
                "${mod_namevers}: removing release file"
        pbcore::remove_file \
                "${rm_cfg['modulefile_dir']}/.config-${rm_cfg['version']}" \
                "${mod_namevers}: removing config file"
        pbcore::remove_file \
                "${rm_cfg['modulefile_dir']}/.deps-${rm_cfg['version']}" \
                "${mod_namevers}: removing dependencies file"
        rmdir -p "${config['modulefile_dir']}" 2>/dev/null || :
}

#......................................................................
die_sub_package_name_missing(){
        std::die 3 "Name of sub-package not specified in \n===\n$1\n===\n"
}
die_sub_package_version_missing(){
        std::die 3 "Version of sub-package not specified in \n===\n$1\n===\n"
}
pbcore::build_sub_packages(){
        [[ "${Options['skip_subpkgs']}" == 'yes' ]] && return 0

        local -n __bsp_cfg="$1"
        local -- sub_packages_yml="${__bsp_cfg['sub_packages']}"

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
                                        cfg::err_invalid_key \
                                                 '__bsp_cfg' \
                                                 "in requested sub-package '${i}" \
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
                PATH="${save_PATH}" "$BUILDBLOCK_DIR/build-${pkg_name}" \
                        "${pkg_name}/${pkg_version}" \
                        "${pkg_build_args[@]}" || \
                        std::die 255 "Building sub-package failed - ${pkg_name}/${pkg_version}"
        done
}

#..............................................................................
#
# The real worker function.
#
pbcore::build(){
        local -n mod_config="$1"
        declare -ng ModuleConfig="$1"
        declare -ng Options="$2"
        shift 2
        local -a with_modules=( "$@" )

	ModuleConfig['namevers']="${ModuleConfig['name']}/${ModuleConfig['version']}"
        local -r mod_namevers="${mod_config['name']}/${mod_config['version']}"

        eval "$( modulecmd bash purge )"
        if [[ -v __MODULES_OVERLAYS ]]; then
                local -a overlays=()
                local -- overlay=''
                IFS=':' read -r -a overlays <<<"${__MODULES_OVERLAYS}"
                for overlay in "${overlays[@]}"; do
                        eval "$(modulecmd bash unuse "${overlay}")"
                done
        fi
        unset   C_INCLUDE_PATH CPLUS_INCLUDE_PATH CPP_INCLUDE_PATH
        unset   LIBRARY_PATH LD_LIBRARY_PATH DYLD_LIBRARY_PATH
        unset   CFLAGS CPPFLAGS CXXFLAGS
        unset   LIBS LDFLAGS
        unset   CC CXX FC F77 F90

	(( ${#with_modules[@]} > 0 )) && \
		std::info \
			"%s " \
			"${mod_namevers}:" \
			"with" "${with_modules[@]}"

        pbcore::load_overlays 'mod_config'
        pbcore::load_dependencies 'mod_config' "${with_modules[@]}"
        BUILD_ROOT="${PMODULES_TMPDIR}/${mod_config['name']}-${mod_config['version']}"
        SRC_DIR="${BUILD_ROOT}/src"
	echo "${mod_config['compile_in_sourcetree']}" 1>&2
        if [[ "${mod_config['compile_in_sourcetree']}" == 'yes' ]]; then
                BUILD_DIR="${SRC_DIR}"
        else
                BUILD_DIR="${BUILD_ROOT}/build"
        fi

        source "${BUILD_SCRIPT}"

	echo "BUILD_DIR: $BUILD_DIR" 1>&2
	echo "SRC_DIR: $SRC_DIR" 1>&2

        if [[ "${Options['is_subpkg']}" != 'yes' ]]; then
                pbcore::set_mod_dir_and_prefix mod_config 'PREFIX'
        else
                PREFIX="${Options['prefix']}"
                mod_config['modulefile_dir']="${PREFIX}"
        fi
        # ok, finally we can start ...
        if [[ "${mod_config['relstage']}" == 'remove' ]]; then
                pbcore::remove_module 'mod_config'
        elif [[ "${mod_config['relstage']}" == 'deprecated' ]]; then
                pbcore::set_relstages mod_config
        elif [[ -d "${PREFIX}" && \
                        "${Options['is_subpkg']}" != 'yes' && \
                        "${Options['force_rebuild']}" == 'no' ]]; then
                std::info \
                        "%s " \
                        "${mod_config['name']}/${mod_config['version']}:" \
                        "already exists, not rebuilding ..."
                if [[ "${Options['update_modulefiles']}" == 'yes' ]]; then
                        pbcore::install_module_config mod_config
                        pbcore::install_runtime_dependencies 'mod_config' "${with_modules[@]}"
                        pbcore::set_relstages mod_config
                elif [[ "${Options['update_relstage']}" == 'yes' ]]; then
                        pbcore::set_relstages mod_config
                else
                        std::info \
                                "%s " \
                                "${mod_config['name']}/${mod_config['version']}:" \
                                "modulefile and configuration are not updated."
                fi
        else
                if [[ "${Options['clean_install']}" == 'yes' ]]; then
                        std::info \
                                "%s " \
                                "${mod_config['name']}/${mod_config['version']}:" \
                                "remove module, if already exists ..."
                        pbcore::remove_module 'mod_config'
                fi
                std::info \
                        "%s " \
                        "${mod_config['name']}/${mod_config['version']}:" \
                        "start building ..."
                pbcore::cleanup_build 'mod_config'
                pbcore::cleanup_src 'mod_config'
                pbcore::compile_and_install  'mod_config'
                pbcore::post_install  'mod_config'
                pbcore::install_module_config  'mod_config'
                pbcore::install_runtime_dependencies 'mod_config' "${with_modules[@]}"
                pbcore::set_relstages mod_config
                pbcore::cleanup_build  'mod_config'
                pbcore::cleanup_src  'mod_config'
                pbcore::build_sub_packages 'mod_config'

        fi
        if [[ "${Options['cleanup_modulefiles']}" == 'yes' ]]; then
                pbcore::cleanup_modulefiles  'mod_config'
        fi
        std::info \
                "%s\n%s" \
                "${mod_config['name']}/${mod_config['version']}: done" \
                "* * * * *"
}
readonly -f pbcore::build

# Local Variables:
# mode: sh
# sh-basic-offset: 8
# tab-width: 8
# End:
