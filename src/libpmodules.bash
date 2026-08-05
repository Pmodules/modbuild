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
declare -A OverlayInfo

# An overlay has a type defining the way modules in this overlay
# make modules in the other overlays unavailable.
#
# 'normal'
#	Make modules in other overlay unavailable with the same full name.
#	If the overlay doesn't support groups, the overlay should provide
#	only modules with different names from the modules in the other
#	overlays. Otherwise you modules as available which cannot be loaded.
#	Example:
#	A overlay providing modules with name gcc doesn't conceal the gcc
#	modules in the base overlay, but they are listed as available.
#
#
# 'hiding'
#	Make modules in other overlay unavailable with the same name.
#	Examples:
#	- If a module with name 'gcc' is in a overlay with this
#	  type, only the gcc modules in this overlay are available. This
#	  can for example be used to conceal old versions of gcc.
#	- In same case we need special variants of a module for a system,
#	  for exampe openmpi and mpich. Variants of these software can be
#	  made available in an overlay. If such an overlay is used, modules
#	  which should not be used can be concealed.
#	If the overlay doesn't support groups, a module in the overlay
#	conceals all modules in other overlays independend from the group.
#	Example:
#	- In the Spack overlays - which doesn't support groups - are modules
#	  with name gcc. The gcc modules in the Spack overlays conceals the
#	  gcc modules in the group Programming of the base overlay.
# 'replacing'
#	This type can be used to make hole groups unavailable.
#
# 
declare -r OL_NORMAL='n'
declare -r OL_HIDING='h'
declare -r OL_REPLACING='r'

declare -A DefaultPmodulesConfig=(
	['defaultgroups']='Tools:Programming'
	['default_groups']='Tools:Programming'
	['defaultreleasestages']='stable'
	['default_reltages']='stable'
	['tmpdir']="/var/tmp/${USER}"
	['tmp_dir']="/var/tmp/${USER}"
	['download_dir']="${HOME}/.cache/Pmodules/distfiles"
)

declare -A OverlayConfigKeys=(
	['install_root']='/opt/psi'
	['modulefiles_root']=''
	['excludes']=''
	['type']='n'
	['conflicts']=''
	['path_config']=''
	['default_relstage']='unstable'
	['layout']='Pmodules'
	['has_additional_modulepaths']='false'
	['groups']=''
)

declare -A OverlayPathConfigKeys=(
	['target_cpus']=''
	['modulepath']=''
	['modulepath_unstable']=''
	['modulepath_stable']=''
	['modulepath_deprecated']=''

)

pm::die_invalid_key(){
	std::die 3 "Invalid key in configuration -- $1\n$2"
}

pm::die_invalid_ol_install_root(){
	std::die 3 "Invalid installation root directory for overlay '$1' -- $2"
}


pm::die_invalid_ol_modulefiles_root(){
	std::die 3 "Invalid modulefiles root directory for overlay '$1' -- $2"
}

pm::die_invalid_ol_type(){
	std::die 3 "Invalid type for overlay '$1' -- $2"
}

pm::die_invalid_ol_layout(){
	std::die 3 "Invalid layout for overlay '$1' -- $2\nAllowed values are 'Pmodules', 'Spack' and 'flat'."
}

pm::die_invalid_ol_relstage(){
	std::die 3 "Invalid default release stage for overlay '$1' -- $2"
}

pm::parse_path_config(){
	local -n yaml="$1"
	local -- ol_name="$2"

	local -- key=''
	for key in "${!OverlayPathConfigKeys[@]}"; do
		OverlayInfo[${ol_name}:${key}]="${OverlayPathConfigKeys[${key}]}"
	done
	local -i l=0
	yml::get_seq_length l yaml .
	local -i i=0
	for ((i=0; i<l; i++)); do
		local -a target_cpus=()
		local -- node=".[$i]"
		local -a keys=()
		yml::get_keys keys yaml "${node}"
		for key in "${keys[@]}"; do
			case ${key} in
				target_cpus )
					local -- str=''
					yml::get_seq \
						str \
						yaml \
						"${node}.${key}"
					readarray -t target_cpus <<<${str}
					local -- system_cpu=$(uname -p)
					local -- cpu=''
					local -- found='no'
					for cpu in "${target_cpus[@]}"; do
						if [[ ${cpu} == ${system_cpu} ]]; then
							found='yes'
							break 1
						fi
					done
					[[ ${found} == 'no' ]] && break 1
					;;
				modulepath | modulepath_unstable | modulepath_stable | modulepath_deprecated)
					local -- str=''
					yml::get_seq str yaml "${node}.${key}"
					local -a tmp_array=()
					readarray -t tmp_array <<<${str}
					local -- modulepath=''
					local -- dir=''
					local -- target_cpu=''
					for dir in "${tmp_array[@]}"; do
						for target_cpu in "${target_cpus[@]}"; do
							std::append_path modulepath $(envsubst <<< "${dir}")
						done
					done
					OverlayInfo[${ol_name}:${key}]="${modulepath}"
					OverlayInfo[${ol_name}:has_additional_modulepaths]='true'
					;;
			esac
		done
	done
}

pm::read_config(){
	local -r __doc__='
	Read modules configuration.

	In case of Pmodules read 'PMODULES_ROOT/config/Pmodules.yaml'
	and '${HOME}/.Pmodules/Pmodules.yaml'.

	In case of Tcl Environemnt Modules get the config from running
	module use
	'
	local -- tmp_dir="${DefaultPmodulesConfig['tmp_dir']}"
	local -- download_dir="${DefaultPmodulesConfig['download_dir']}"

	get_config_of_overlay(){
		: "
		Get configuration of an overlay.
		"
		local -r yaml_input="$1"	# YAML formatted string
		local -r ol_name="$2"		# name of overlay

		Overlays+=( "${ol_name}" )
		# init overlay with defaults
		local -- key=''
		for key in "${!OverlayConfigKeys[@]}"; do
			OverlayInfo[${ol_name}:${key}]="${OverlayConfigKeys[${key}]}"
		done
		for key in "${!OverlayPathConfigKeys[@]}"; do
			OverlayInfo[${ol_name}:${key}]="${OverlayPathConfigKeys[${key}]}"
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
						pm::die_invalid_ol_install_root "${ol_name}" "${value}"
					;;
				modulefiles_root )
					yml::get_value value yaml_input "${node}.${key}" '!!str'
					OverlayInfo[${ol_name}:modulefiles_root]=$(envsubst <<< "${value}")
					mkdir -p "${OverlayInfo[${ol_name}:modulefiles_root]}" 2>/dev/null
					[[ -d ${OverlayInfo[${ol_name}:modulefiles_root]} ]] || \
						pm::die_invalid_ol_modulefiles_root "${ol_name}" "${value}"
					;;
				type )
					yml::get_value value yaml_input "${node}.${key}" '!!str'
					case ${value} in
						"${OL_NORMAL}" | "${OL_REPLACING}" | "${OL_HIDING}" )
							:
							;;
						* )
							pm::die_invalid_ol_type "${ol_name}" "${value}"
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
							pm::die_invalid_ol_layout "${ol_name}" "${value}"
							;;
					esac
					OverlayInfo[${ol_name}:${key,,}]="${value}"
					;;
				default_relstage )
					yml::get_value value yaml_input "${node}.${key}" '!!str'
					case ${value} in
						'unstable' | 'stable' | 'deprecated' )
							:
							;;
						*)
							pm::die_invalid_ol_relstage "${ol_name}" "${value}"
							;;
					esac
					OverlayInfo[${ol_name}:${key}]="${value}"
					;;
				conflicts | excludes | groups)
					yml::get_seq value yaml_input "${node}.${key}"
					local -a tmp_array=()
					readarray -t tmp_array <<<${value}
					local -- tmp_str=''
					printf -v tmp_str "%s:" "${tmp_array[@]}"
					OverlayInfo[${ol_name}:${key}]=$(envsubst <<<"${tmp_str%:}" )
					;;
				path_config )
					yml::get_value value yaml_input "${node}.${key}" '!!seq'
					pm::parse_path_config value "${ol_name}"
					;;
				* )
					pm::die_invalid_key "${key}" "${yaml_input}"
					;;

			esac
		done
		OverlayInfo[${ol_name}:used]='no'
		if [[ -z "${OverlayInfo[${ol_name}:modulefiles_root]}" ]]; then
			OverlayInfo[${ol_name}:modulefiles_root]=${OverlayInfo[${ol_name}:install_root]}
		fi
	}

	get_config(){
		: "
		Get Pmodules configuration.
		"
		local -r config_file="$1"	# Pmodules configuration file

		local -- yaml_input=''
		yml::read_file yaml_input "${config_file}"

		local -- key=''
		local -a keys=()
		yml::get_keys keys yaml_input '.'
		for key in "${keys[@]}"; do
			case ${key,,} in
				defaultgroups | default_groups )
					: # ignore
					;;
				defaultreleasestages | default_reltages )
					: # ignore
					;;
				tmpdir | tmp_dir )
					yml::get_value tmp_dir yaml_input ".${key}" '!!str'
					tmp_dir="$(envsubst <<<"${tmp_dir}")"
					;;
				distfilesdir | download_dir )
					yml::get_value download_dir yaml_input ".${key}" '!!str'
					download_dir="$(envsubst <<<"${download_dir}")"
					;;
				overlays )
					local -- overlay=''
					local -a overlays=()
					local -- ol_configs=''
					yml::get_value ol_configs yaml_input ".${key}" "!!map"
					yml::get_keys overlays ol_configs "."
					for overlay in "${overlays[@]}"; do
						get_config_of_overlay "${yaml_input}" "${overlay}"
					done
					;;
				* )
					pm::die_invalid_key "${key}" "${yaml_input}"
					;;
			esac
		done
	}

	if [[ -v PMODULES_HOME ]]; then
		# system config file
		local -- sys_config_file="${PMODULES_HOME%%/Tools*}/config/Pmodules.yaml"
		if [[ -v PMODULES_CONFIG_FILE && -n "${PMODULES_CONFIG_FILE}" ]]; then
			sys_config_file="${PMODULES_HOME%%/Tools*}/config/${PMODULES_CONFIG_FILE}"
		fi
		sys_config_file=$(readlink -f "${sys_config_file}")
		test -r "${sys_config_file}" || \
			std::die 3 \
				 "%s %s -- %s" \
				 "Configuration file " \
				 "does not exist or is not readable" \
				 "$_"
		
		get_config "${sys_config_file}"
		
		local -r usr_config_file="${HOME}/.Pmodules/Pmodules.yaml"
		if [[ -r "${usr_config_file}" ]]; then
			get_config "${usr_config_file}"
		fi
	else
		# If Tcl Environemnt Modules are used, retrieving the overlays
		# is hacky as long as we don't have a solution to query the
		# overlays via the module command in a well defined format.
		# For now the output of `module use` is parsed. In the PSI's 
		# extension the overlays and their configuration are printed
		# first in YAML format. The output that follows is truncated
		# using sed(1).
		
		# for the module use command xtrace must be switched off!
		local -- xtrace_is_on=''
		if [[ "$-" == *x* ]]; then
			xtrace_is_on=':'
			set +x
		fi
		local -- str="$(module use)"
		[[ "${xtrace_is_on}" ]] && set -x
		yaml_input="$(sed -n '/Used release stages/q;p' <<<"${str}")"
		yaml_input="$(yq -e '.*' <<<"${yaml_input}")"
		local -a overlays=( $(yq -e 'keys|.[]' <<<"${yaml_input}") )
		for overlay in "${overlays[@]}"; do
			get_config_of_overlay "${yaml_input}" "${overlay}"
		done
	fi
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
