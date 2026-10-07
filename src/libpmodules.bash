#!/bin/bash

# Requires: yq (Go version) >= 4.0!

set   -o pipefail
set   -o nounset
shopt -s extglob
shopt -s nullglob

(( BASH_VERSINFO[0] >= 5 && BASH_VERSINFO[1] >= 3 )) || \
        {
                printf "%s\n" "Bash 5.3+ required" 1>&2
                exit 255
        }


declare -r __MODULEFILES_DIR__='modulefiles'
declare -g PMODULES_DISTFILESDIR PMODULES_TMPDIR

declare -a Overlays=()
declare -A OverlayInfo=()

# An overlay has a type defining the way modules in this overlay
# make modules in the other overlays unavailable.
#
# 'normal'
#       Make modules in other overlay unavailable with the same full name.
#       If the overlay doesn't support groups, the overlay should provide
#       only modules with different names from the modules in the other
#       overlays. Otherwise you modules as available which cannot be loaded.
#       Example:
#       A overlay providing modules with name gcc doesn't conceal the gcc
#       modules in the base overlay, but they are listed as available.
#
#
# 'hiding'
#       Make modules in other overlay unavailable with the same name.
#       Examples:
#       - If a module with name 'gcc' is in a overlay with this
#         type, only the gcc modules in this overlay are available. This
#         can for example be used to conceal old versions of gcc.
#       - In same case we need special variants of a module for a system,
#         for exampe openmpi and mpich. Variants of these software can be
#         made available in an overlay. If such an overlay is used, modules
#         which should not be used can be concealed.
#       If the overlay doesn't support groups, a module in the overlay
#       conceals all modules in other overlays independend from the group.
#       Example:
#       - In the Spack overlays - which doesn't support groups - are modules
#         with name gcc. The gcc modules in the Spack overlays conceals the
#         gcc modules in the group Programming of the base overlay.
# 'replacing'
#       This type can be used to make a groups unavailable.
#
#
declare -A DefaultPmodulesConfig=(
        ['tmp_dir']="/var/tmp/${USER:-$(id -un)}"
        ['download_dir']="${HOME}/.cache/Pmodules/distfiles"
)

declare -A OverlayConfigKeys=(
        ['install_root']='/opt/psi'
        ['modulefiles_root']=''
        ['type']='n'
        ['layout']='Pmodules'
)

rtcfg::die_invalid_key(){
        std::die 3 "%b" "Invalid key in configuration -- $1\n$2"
}

rtcfg::die_invalid_ol_install_root(){
        std::die 3 "%s" "Invalid installation root directory for overlay '$1' -- $2"
}


rtcfg::die_invalid_ol_modulefiles_root(){
        std::die 3 "%s" "Invalid modulefiles root directory for overlay '$1' -- $2"
}

rtcfg::die_invalid_ol_type(){
        std::die 3 "%s" "Invalid type for overlay '$1' -- $2"
}

rtcfg::die_invalid_ol_layout(){
        std::die 3 "%b" "Invalid layout for overlay '$1' -- $2\nAllowed values are 'Pmodules', 'Spack' and 'flat'."
}

##
## rtcfg::_get_config_of_overlay - read configuration of an overlay
##
## Arguments:
##   $1 - YAML formatted overlay configuration
##   $2 - name of overlay
##
rtcfg::_get_config_of_overlay(){
        local -r yaml_input="$1"        # YAML formatted string
        local -r ol_name="$2"           # name of overlay

        Overlays+=( "${ol_name}" )
        # init overlay with defaults
        local -- key=''
        for key in "${!OverlayConfigKeys[@]}"; do
                OverlayInfo[${ol_name}:${key}]="${OverlayConfigKeys[${key}]}"
        done
        # get keys in YAML input
        local -- node=".\"${ol_name}\""
        local -a keys=()
        yml::get_keys keys yaml_input "${node}"
        local -- value=''
        for key in "${keys[@]}"; do
                case ${key,,} in
                        install_root )
                                yml::get_value value yaml_input "${node}.${key}" '!!str'
                                OverlayInfo[${ol_name}:install_root]=$(envsubst <<< "${value}")
                                mkdir -p "${OverlayInfo[${ol_name}:install_root]}" 2>/dev/null
                                [[ -d ${OverlayInfo[${ol_name}:install_root]} ]] || \
                                        rtcfg::die_invalid_ol_install_root "${ol_name}" "${value}"
                                ;;
                        modulefiles_root )
                                yml::get_value value yaml_input "${node}.${key}" '!!str'
                                OverlayInfo[${ol_name}:modulefiles_root]=$(envsubst <<< "${value}")
                                mkdir -p "${OverlayInfo[${ol_name}:modulefiles_root]}" 2>/dev/null
                                [[ -d ${OverlayInfo[${ol_name}:modulefiles_root]} ]] || \
                                        rtcfg::die_invalid_ol_modulefiles_root \
                                                "${ol_name}" "${value}"
                                ;;
                        type )
                                yml::get_value value yaml_input "${node}.${key}" '!!str'
                                case ${value} in
                                        'n' | 'h' | 'r' )
                                                :
                                                ;;
                                        * )
                                                rtcfg::die_invalid_ol_type \
                                                        "${ol_name}" "${value}"
                                                ;;
                                esac
                                OverlayInfo[${ol_name}:type]="${value}"
                                ;;
                        layout )
                                yml::get_value value yaml_input "${node}.${key}" '!!str'
                                case ${value} in
                                        'Pmodules' | 'Spack' | 'flat' )
                                                :
                                                ;;
                                        * )
                                                rtcfg::die_invalid_ol_layout \
                                                        "${ol_name}" "${value}"
                                                ;;
                                esac
                                OverlayInfo[${ol_name}:${key,,}]="${value}"
                                ;;
                        * )
                                rtcfg::die_invalid_key "${key}" "${yaml_input}"
                                ;;
                esac
        done
        OverlayInfo[${ol_name}:used]='no'
        if [[ -z "${OverlayInfo[${ol_name}:modulefiles_root]}" ]]; then
                OverlayInfo[${ol_name}:modulefiles_root]=${OverlayInfo[${ol_name}:install_root]}
        fi
}

##
## rtcfg::read_config -
##
## In case of Tcl Environment Modules get the config from running
## module use
##
rtcfg::read_config(){
        local -- tmp_dir="${DefaultPmodulesConfig['tmp_dir']}"
        local -- download_dir="${DefaultPmodulesConfig['download_dir']}"

        # With Tcl Environment Modules retrieving the overlays
        # is hacky as long as we don't have a solution to query the
        # overlays via the module command in a well defined format.
        # For now the output of `module use` is parsed. In the PSI's
        # extension the overlays and their configuration are printed
        # first in YAML format. The output that follows is truncated
        # using sed(1).

        local -- str="$(modulecmd bash use 2>&1)"
        local -- yaml_input
        yaml_input="$(sed -n '/Used release stages/q;p' <<<"${str}")"
        yaml_input="$(yq -e '.*' <<<"${yaml_input}")"
        local -a overlays=( $(yq -e 'keys|.[]' <<<"${yaml_input}") )
        local -- overlay
        for overlay in "${overlays[@]}"; do
                rtcfg::_get_config_of_overlay "${yaml_input}" "${overlay}"
        done

        OverlayInfo[none:type]='n'
        OverlayInfo[none:layout]='flat'

        PMODULES_DISTFILESDIR="${PMODULES_DISTFILESDIR:-${download_dir}}"
        PMODULES_TMPDIR="${PMODULES_TMPDIR:-${tmp_dir}}"
}

# Local Variables:
# mode: sh
# sh-basic-offset: 8
# tab-width: 8
# End:
