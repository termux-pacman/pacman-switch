#!/usr/bin/bash

set -e

if [[ -z "${_PS_RUN_IN_ALPM_HOOKS}" || ("${_PS_RUN_IN_ALPM_HOOKS}" != "true" && "${_PS_RUN_IN_ALPM_HOOKS}" != "false") ]]; then
	_PS_RUN_IN_ALPM_HOOKS=false
fi

# pacman-switch system info
_ps_version="1.0.0-BETA"
_ps_prefix="${PWD}/usr"
_ps_switcher_files_path="${_ps_prefix}/share/pacman-switch"
_ps_enabled_switchers_path="${_ps_prefix}/var/lib/pacman/switch"

# database
_ps_enabled_sw=()
_ps_selected_sw=()
_ps_static_selected_sw=()
_ps_non_integrity_sw=()

# style
_ps_bold=""
_ps_nostyle=""
_ps_blue=""
_ps_green=""
_ps_yellow=""
_ps_red=""

# system variable settings for internal work
_ps_nomessage=false
_ps_select_selected_sw=false
_ps_selfmode=false
_ps_noprogress=false
_ps_nowarning=false
_ps_noerror=false
_ps_onlygroup=false
_ps_onlyswitcher=false
_ps_norequire_sw=false
_ps_haserror=false
_ps_arg_is_swfile=false
_ps_progress_noret=false

# user variable settings / user options
_ps_needed=false
_ps_noconfirm=false
_ps_noghost=false
_ps_enable_select=false
_ps_reject_disable=false
_ps_reject_replace=false
_ps_disable_reject=false
_ps_disable_ghost=false
_ps_guery_check=false
_ps_query_groups=false
_ps_query_global_list=false
_ps_query_list=false
_ps_query_info=false
_ps_query_switchers=false
_ps_query_switcherfiles=false
_ps_helpmode=false
_ps_automode=false
_ps_updatemode=false
_ps_overwrite=false

_ps_message() {
	! ${_ps_nomessage} && echo -ne "$1" >&2 || true
}

_ps_progress() {
	local now="$1" goal="$2"
	! ${_ps_noprogress} && _ps_message "${_ps_title_progress}(${now}/${goal}) ${3}${_ps_nostyle}$((! ${_ps_progress_noret} && ((now < goal))) && echo '\r' || echo '\n')" || true
}

_ps_header_standard() {
	echo -e "${_ps_title_header}${_ps_bold} $1${_ps_nostyle}"
}

_ps_info() {
	_ps_message "$(_ps_header_standard "$1")\n"
}

_ps_commit() {
	_ps_info "$1..."
}

_ps_warning() {
	! ${_ps_nowarning} && _ps_message "${_ps_yellow}${_ps_title_warning}${_ps_nostyle} $1\n" || true
}

_ps_error_message() {
	_ps_nomessage=false _ps_message "${_ps_red}${_ps_title_error}${_ps_nostyle} $1\n"
}

_ps_init_error() {
	_ps_error_message "$1"
	_ps_haserror=true
}

_ps_error() {
	_ps_error_message "$1"
	exit 1
}

_ps_nothing_to_do() {
	_ps_message "${_ps_title_progress:=" "}there is nothing to do\n"
	exit 0
}

_ps_merge_data() {
	local rows=${1}
	shift 1

	local goal=$((${#}-${#}/rows+1))
	local pi=$(((goal-1)/(rows-1)))
	while (($# >= ${goal})); do
		local index=1
		while ((${index} < ${goal})); do
			echo -ne "${!index}:"
			index=$((index+pi))
		done
		echo "${!goal}"
		shift 1
	done
}

_ps_read_switcher_file() {
	local i=1 goal=$# error=() result=() name group associations switcher_path switcher
	while (($# >= 1)); do
		_ps_progress "${i}" "${goal}" "reading switcher files"
		switcher="${1}"
		i=$((i+1))
		shift 1

		if ${_ps_arg_is_swfile}; then
			switcher_path="${switcher}"
			name="$(basename ${switcher%.*})"
			group=".*"
		else
			name="${switcher##*:}"
			group="${switcher%%:*}"
			if [ "${group}" = "*" ]; then
				group=".*"
			fi
			switcher_path="${_ps_switcher_files_path}/${name}.sw"
		fi

		associations=()
		if [[ "${name}" != "*" && ! -f "${switcher_path}" ]]; then
			error+=("${group:=[unknown]}:${name}:notfound")
			continue
		fi
		local func=$(source ${switcher_path}; declare -f | grep -E "(^| )switcher_group_${group}( |\()" | awk '{printf $1 "|"}')
		for func in $(grep -EHo "(^| )(${func::-1})( |\()" ${switcher_path} | sed 's|(||g; s|\.sw:|:|g'); do
			group="${func//*:switcher_group_/}"
			switcher_path="${func%%:*}"
			name="${switcher_path##*/}"
			func="${func##*:}"
			if [[ " ${result[@]}" =~ " ${group}:${name}:" ]]; then
				continue
			fi
			result+=($(
				source ${switcher_path}.sw
				${func}
				if [[ -z "${group}" || ! "${priority:=0}" =~ ^[0-9]+$ || \
					"$(sed 's/-//g; s/_//g' <<< "${group}${name}")" =~ [[:punct:]] || \
					"${group}${name}" =~ " " ]] || \
					grep -Eq "(^|/|:| )(/|:| |$)" <<< "${associations[@]}" || \
					(($(grep -o ':' <<< "${associations[@]}" | wc -l) != ${#associations[@]})); then
					exit 1
				fi
				awk -v RS=" " \
					-v group="${group}" \
					-v switcher="${name}" \
					-v priority="${priority:=0}" \
					-v prefix="${_ps_prefix}" \
					'{split($1,path,":"); print group ":" switcher ":" priority ":" prefix "/" path[1] ":" prefix "/" path[2]}' \
					<<< "${associations[@]}"
			)) || error+=("${group:=[unknown]}:${name}:syntax")
		done
	done
	tr ' ' '\n' <<< "${result[@]}"
	if ! ${_ps_noerror} && [ -n "${error}" ]; then
		local sw
		for i in ${error[@]}; do
			sw="${i%:*}"
			case "${i##*:}" in
				syntax) _ps_error_message "syntax error in switcher file: ${sw}";;
				notfound) _ps_error_message "switcher file not found: ${sw}"
			esac
		done
		exit 1
	fi
}

_ps_read_enabled_switchers() {
	_ps_enabled_sw=($(for association in $(find "${_ps_enabled_switchers_path}" -mindepth 1 -type f); do
		association="${association//${_ps_enabled_switchers_path}\//}"
		awk -v association="${association//\//:}" -F "=" '{if ($1 == "association") print association ":" $2}' "${_ps_enabled_switchers_path}/${association}"
	done))
}

_ps_read_selected_switchers() {
	_ps_selected_sw=($(find "${_ps_enabled_switchers_path}" -type l -exec readlink -fn {} \; -printf ':%f\n' | sed "s|${_ps_enabled_switchers_path}/||g; s|:.*:select:|:|g; s|/|:|g"))
}

_ps_get_selected_switchers() {
	grep -E ${@} "^($(tr ' ' '|' <<< "${_ps_selected_sw[@]%:*}")):" || true
}

_ps_get_enabled_switcher() {
	local i=1 goal=$# notfound=() list=$(tr ' ' '\n' <<< "${_ps_enabled_sw[@]}") result=() type="enabled"
	if ${_ps_select_selected_sw}; then
		list=$(_ps_get_selected_switchers <<< "${list}")
		type="selected"
	fi
	while (($# >= 1)); do
		_ps_progress "${i}" "${goal}" "getting ${type} switchers"
		result+=($(grep "^${1//\*/\.*}:" <<< "${list}")) || notfound+=("${1}")
		i=$((i+1))
		shift 1
	done
	tr ' ' '\n' <<< "${result[@]}" | sort -u
	if ! ${_ps_noerror} && [ -n "${notfound}" ]; then
		for i in ${notfound[@]}; do
			_ps_error_message "${type} switcher not found: ${i}"
		done
		exit 1
	fi
}

_ps_return_enabled_switcher() {
	tr ' ' '\n' <<< "${_ps_enabled_sw[@]}" | grep -Ev "^($(tr ' ' '|' <<< "${_ps_non_integrity_sw[@]}"))$"
}

_ps_chmod_switchers() {
	local paths=($(find "${_ps_enabled_switchers_path}" -mindepth 1 -type f -o -type d))
	[ -z "${paths}" ] || chmod ${1} ${paths[@]}
}

_ps_get_checksum_switcher() {
	sha256sum "${1}" | awk '{print "checksum=" $1}'
}

_ps_check_checksum_switcher() {
	awk -F '=' -v sw_file="${_ps_switcher_files_path}/${1##*:}.sw" '{ if ($1 == "checksum") { print $2, sw_file } else {exit} }' "${_ps_enabled_switchers_path}/${1//://}:"* | sha256sum -c --status 2>/dev/null
	return $?
}

_ps_check_switcher_data_integrity() {
	local i=0 goal="$#"
	while (($# >= 1)); do
		_ps_progress "$((i+1))" "${goal}" "checking switcher data integrity"
		awk -v i="${i}" '{
			if (!(split($0, data, ":") == 5 &&
				data[1] != "" && gsub("-", "", data[1])+1 && gsub("_", "", data[1])+1 && data[1] !~ "[[:punct:]]" &&
				data[2] != "" && gsub("-", "", data[2])+1 && gsub("_", "", data[2])+1 && data[2] !~ "[[:punct:]]" &&
				int(data[3]) == data[3] &&
				substr(data[4], 1, 1) == "/" &&
				substr(data[5], 1, 1) == "/" &&
				substr(data[4], length(data[4]), 1) != "/" &&
				substr(data[5], length(data[5]), 1) != "/"))
				print i
		}' <<< "${1}"
		i=$((i+1))
		shift 1
	done
	exit 1
}

_ps_check_existence_root_path() {
	local i=0 goal=$((${#}/2+1)) list="${@}"
	if [ "${operation:-}" = "enable" ]; then
		list+=" $(_ps_return_enabled_switcher | awk -F ':' '{printf $4 " "}')"
	fi
	list="$(tr ' ' '\n' <<< "${list}")"
	while (($# >= ${goal})); do
		_ps_progress "$((i+1))" "$((goal-1))" "checking root paths for existence"
		if [ ! -f "${!goal}" ] && ! (($(grep -c "^${!goal}$" <<< "${list}") > 1)); then
			echo $i
		fi
		i=$((i+1))
		shift 1
	done
}

_ps_check_existence_link_path() {
	local i=0 goal="$#" list="$(tr ' ' '\n' <<< "${@} $(_ps_return_enabled_switcher | _ps_get_selected_switchers | awk -F ':' '{print $4}')")"
	while (($# >= 1)); do
		_ps_progress "$((i+1))" "${goal}" "checking link paths for existence"
		if [ -f "${1}" ] && ! (($(grep -c "^${1}$" <<< "${list}") > 1)); then
			echo $i
		fi
		i=$((i+1))
		shift 1
	done
	exit 1
}

_ps_check_conflict_link_path() {
	local i=0 goal=$((${#}/2+1))
	local d_associations="$(_ps_merge_data 2 ${@} | sort -u)"
	local e_associations="$(_ps_return_enabled_switcher | awk -F ':' '!a[$1 ":" $4]++ {print $1 ":" $4}' | grep -Ev "^($(awk -F ':' '!a[$1]++ {print $1}' <<< "${d_associations}" | paste -sd '|')):")"
	while (($# >= ${goal})); do
		_ps_progress "$((i+1))" "$((goal-1))" "checking link paths for conflicts"
		if (($(grep -c ":${!goal}$" <<< "${d_associations}") > 1)) || grep -q ":${!goal}$" <<< "${e_associations}"; then
			echo $i
		fi
		i=$((i+1))
		shift 1
	done
}

_ps_check_conflict_enabled_switcher() {
	local i=0 goal=$((${#}/2+1)) list="$(_ps_merge_data 2 ${@} | sort -u)" old=""
	while (($# >= ${goal})); do
		_ps_progress "$((i+1))" "$((goal-1))" "checking enabled switchers for conflicts"
		local now="${1}:${!goal}"
		if (($(grep -c "^${1}:" <<< "${list}") > 1)) && [ "${now}" != "${old}" ]; then
			echo $i
			old="${now}"
		fi
		i=$((i+1))
		shift 1
	done
}

_ps_check_valid_link_path() {
	local i=0 goal="$#"
	while (($# >= 1)); do
		_ps_progress "$((i+1))" "${goal}" "checking link paths for validity"
		if [ ! -d "${1%/*}" ]; then
			echo $i
		fi
		i=$((i+1))
		shift 1
	done
}

_ps_check_dependent_switcher() {
	local i=0 goal="$#" list="$(_ps_return_enabled_switcher)"
	if [ "${operation:-}" = "reject" ] && ! ${_ps_reject_disable}; then
		list="$(_ps_get_selected_switchers <<< "${list}")"
	fi
	list="$(awk -F ':' '{print $4 ":" $5}' <<< "${list}" | grep -Ev "^($(tr ' ' '|' <<< "${@}")):")"
	while (($# >= 1)); do
		_ps_progress "$((i+1))" "${goal}" "checking switcher for dependencies"
		if grep -q ":${1}$" <<< "${list}"; then
			echo $i
		fi
		i=$((i+1))
		shift 1
	done
}

_ps_check_duplicate_root_path() {
	local args=($(_ps_merge_data 3 ${@}))
	local i=0 goal=$((${#args[@]})) list="$(_ps_return_enabled_switcher)"
	while ((${i} < ${goal})); do
		_ps_progress "$((i+1))" "${goal}" "checking root paths for duplicate"
		if grep -v "^${args[${i}]%:*}:" <<< "${list}" | grep -q "^${args[${i}]%%:*}:.*:${args[${i}]##*:}$"; then
			echo $i
		fi
		i=$((i+1))
		shift 1
	done
}

_ps_check_switcher_by_algorithm() {
	local alg="${1}" message="${2}"
	shift 2

	local i=0 goal=$((${#}/2+1)) old_sw="" sw
	while (($# >= ${goal})); do
		_ps_progress "$((i+1))" "$((goal-1))" "${message}"
		sw="${1}:${!goal}"
		if [ "${sw}" != "${old_sw}" ]; then
			if eval "${alg}"; then
				echo $i
			fi
			old_sw="${sw}"
		fi
		i=$((i+1))
		shift 1
	done
}

_ps_check_selected_switcher() {
	_ps_check_switcher_by_algorithm '[[ " ${_ps_selected_sw[@]%:*}" =~ " ${sw}:" ]]' \
		'checking for selected switchers' \
		${@}
}

_ps_check_switcher_belong_pkg() {
	_ps_check_switcher_by_algorithm 'grep -q "^${_ps_switcher_files_path:1}/${!goal}.sw$" "${_ps_pacman_dbpath}/local/"*"/files"' \
		'checking switcher files for belong to pkgs' \
		${@}
}

_ps_check_enabled_switcher() {
	_ps_check_switcher_by_algorithm '[[ " ${_ps_enabled_sw[@]}" =~ " ${sw}:" ]]' \
		'checking for enabled switchers' \
		${@}
}

_ps_check_sw() {
	_ps_check_sw_eval() {
		if [ "${operation}" = "query" ]; then
			local _ps_noprogress=true
		fi
		eval "local result_check_${1}=\$(_ps_nomessage=${_ps_noprogress} _ps_check_${1} ${2})
		if [ -n \"\${result_check_${1}}\" ]; then
			_ps_error_message \"${3}\"
			for i in \${result_check_${1}}; do
				_ps_message \"\${list_group[\$i]}:\${list_name[\$i]}: ${4}\n\"
				if [[ ! \" \${list_index_issue[@]} \" =~ \" \${i} \" ]]; then
					list_index_issue+=(\${i})
				fi
			done
			if [ \"\${operation}\" != \"query\" ]; then
				exit 1
			fi
		fi"
	}

	local operation="$1"
	shift 1
	case "${operation}" in
		"enable"|"select"|"disable"|"reject"|"query"|"install"|"uninstall");;
		*) _ps_error "internal error: unknown operation '${operation}' for _ps_check_sw"
	esac

	local i
	if [ "${operation}" != "query" ]; then
		local result_check_switcher_data_integrity=$(_ps_check_switcher_data_integrity ${@})
		if [ -n "${result_check_switcher_data_integrity}" ]; then
			if [[ "${operation}" = "enable" || "${operation}" = "select" || "${operation}" = "install" ]]; then
				_ps_error_message "switcher data integrity problem"
			else
				_ps_warning "found switcher data with an integrity problem, will be ignored"
			fi
			for i in ${result_check_switcher_data_integrity}; do
				i=$((${i}+1))
				_ps_non_integrity_sw+=("${!i}")
				_ps_message "${!i}\n"
			done
			if [[ "${operation}" = "enable" || "${operation}" = "select" ]]; then
				exit 1
			fi
		fi
	fi

	local list_group=() list_name=() list_priority=() list_link_path=() list_root_path=() list_index_issue=()
	while (($# >= 1)); do
		eval "$(awk -F ':' '{
			print "list_group+=(\"" $1 "\")"
			print "list_name+=(\"" $2 "\")"
			print "list_priority+=(\"" $3 "\")"
			print "list_link_path+=(\"" $4 "\")"
			print "list_root_path+=(\"" $5 "\")"
		}' <<< "${1}")"
		shift 1
	done
	if [[ "${operation}" != "query" && -n "${result_check_switcher_data_integrity}" ]]; then
		for i in ${result_check_switcher_data_integrity}; do
			unset list_{group,name,priority,{link,root}_path}[${i}]
		done
		list_group=(${list_group[@]})
		if [ "${#list_group[@]}" = "0" ]; then
			_ps_warning "all switcher data have integrity problems, skip checking to remove corrupted data"
			return
		fi
		list_name=(${list_name[@]})
		list_priority=(${list_priority[@]})
		list_link_path=(${list_link_path[@]})
		list_root_path=(${list_root_path[@]})
	fi

	if [[ "${operation}" = "enable" || "${operation}" = "select" || "${operation}" = "query" || "${operation}" = "install" ]]; then
		_ps_check_sw_eval existence_root_path '${list_link_path[@]} ${list_root_path[@]}' 'invalid root paths' \
			'${list_root_path[$i]} not found for ${list_link_path[$i]##*/}'
		_ps_check_sw_eval valid_link_path '${list_link_path[@]}' 'not valid link paths' \
			'${list_link_path[$i]%/*} not valid'
	fi

	case "${operation}" in
		"enable"|"query")
		_ps_check_sw_eval duplicate_root_path '${list_group[@]} ${list_name[@]} ${list_root_path[@]}' 'duplicate root paths' \
			'${list_root_path[$i]} duplicate'
		_ps_check_sw_eval conflict_link_path '${list_group[@]} ${list_link_path[@]}' 'switcher conflicts' \
			'${list_link_path[$i]} conflicts'
		;;

		"select")
		if ! ${_ps_overwrite}; then
			_ps_check_sw_eval existence_link_path '${list_link_path[@]}' 'link path conflicts' \
				'${list_link_path[$i]} exists in filesystem'
		fi
		_ps_check_sw_eval conflict_enabled_switcher '${list_group[@]} ${list_name[@]}' 'enabled switcher conflicts' 'conflicts'
		;;

		"disable")
		if ! ${_ps_disable_reject}; then
			_ps_check_sw_eval selected_switcher '${list_group[@]} ${list_name[@]}' 'impossible disable selected switcher' 'selected'
		fi
		;;

		"uninstall")
		_ps_check_sw_eval enabled_switcher '${list_group[@]} ${list_name[@]}' 'impossible delete switcher file when its enabled' 'enabled'
		;;
	esac

	if [[ "${operation}" = "disable" || "${operation}" = "reject" ]]; then
		_ps_check_sw_eval dependent_switcher '${list_link_path[@]}' 'switcher presents dependency' 'needed'
	elif [[ "${operation}" = "install" || "${operation}" = "uninstall" ]]; then
		_ps_check_sw_eval switcher_belong_pkg '${list_group[@]} ${list_name[@]}' "impossible ${operation} switcher file belongs to pkg" 'belongs'
	elif [ "${operation}" = "query" ]; then
		echo ${list_index_issue[@]}
	fi
}

_ps_get_mode_by_selected_sw() {
	local len="${#_ps_static_selected_sw[@]}"
	[ "${len}" = "0" ] && return 1
	awk -F ':' -v RS=" " -v gr="${1}" -v len="${len}" '{if ($1 == gr) {print $3; exit 0} else if (NR == len) {exit 1} }' <<< "${_ps_static_selected_sw[@]}"
}

_ps_action_association() {
	local operation="$1"
	shift 1
	case "${operation}" in
		"enable"|"update"|"disable"|"install"|"remove"|"query");;
		*) _ps_error "internal error: unknown operation '${operation}' for _ps_action_association"
	esac

	local old_association i goal args=$(tr ' ' '\n' <<< "$@") mode=$(${_ps_automode} && echo "auto" || echo "manual") group name priority link_path root_path

	while (($# >= 1)); do
		eval "$(awk -F ':' '{
			print "group=" $1
			print "name=" $2
			print "priority=" $3
			print "link_path=" $4
			print "root_path=" $5
		}' <<< "${1}")"

		local switcher="${group}:${name}"
		local association="${group}/${name}:${priority}"
		local group_path="${_ps_enabled_switchers_path}/${group}"
		local association_path="${_ps_enabled_switchers_path}/${association}"

		if [ "${old_association}" != "${association}" ]; then
			i=1
			goal=$(grep -c "^${switcher}:" <<< "${args}")
			if ${_ps_selfmode}; then
				mode=$(_ps_get_mode_by_selected_sw "${group}" || echo "${mode}")
			fi
		fi

		case "${operation}" in
			"enable"|"update")
			_ps_progress "${i}" "${goal}" "${operation::-1}ing associations for ${switcher}"
			if [ "${old_association}" != "${association}" ]; then
				if [ ! -d "${group_path}" ]; then
					mkdir -p "${group_path}"
				else
					find "${group_path}" -type f -name "${name}:*" -delete
				fi
				_ps_get_checksum_switcher "${_ps_switcher_files_path}/${name}.sw" > "${association_path}"
			fi
			echo "association=${link_path}:${root_path}" >> "${association_path}"
			;;

			"install")
			_ps_progress "${i}" "${goal}" "installing associations for ${switcher}"
			if [ "${old_association}" != "${association}" ]; then
				local selected=$(tr ' ' '\n' <<< "${_ps_selected_sw[@]%:*}" | grep "^${group}:")
				if [ -n "${selected}" ]; then
					_ps_nomessage=true _ps_action_association "remove" $(_ps_nomessage=true _ps_get_enabled_switcher ${selected})
				fi
				ln -sr "${association_path}" "${group_path}/select:${mode}"
			fi
			ln -s $(${_ps_overwrite} && echo "-f") "${root_path}" "${link_path}"
			;;

			"disable")
			_ps_progress "${i}" "${goal}" "disabling associations for ${switcher}"
			if [ "${old_association}" != "${association}" ]; then
				rm -f "${association_path}"
			fi
			;;

			"remove")
			_ps_progress "${i}" "${goal}" "removing associations for ${switcher}"
			if [ "${old_association}" != "${association}" ]; then
				rm -f "${group_path}/select:"*
			fi
			if [[ ! " ${_ps_non_integrity_sw[@]} " =~ " ${1} " ]]; then
				rm -f "${link_path}"
			fi
			;;

			"query")
			if [[ ! " ${_ps_non_integrity_sw[@]} " =~ " ${1} " ]]; then
				if [[ "${old_association}" != "${association}" && "${mode}" = "auto" && \
					"$(_ps_return_enabled_switcher | awk -F ':' -v group="${group}" '{if ( group == $1 && int($3) == $3 && i < $3) i = $3} END {print i}')" != "${priority}" ]]; then
					_ps_error_message "selected switcher ${switcher} does not have maximum priority"
					echo "${switcher}"
				fi
				if ! [[ -L "${link_path}" && "$(readlink ${link_path})" = "${root_path}" ]]; then
					_ps_error_message "problem with link: ${link_path}"
					echo "${switcher}"
				fi
			fi
			;;
		esac

		old_association="${association}"
		i=$((i+1))
		shift 1
	done

	case "${operation}" in
		"select"|"reject") _ps_read_selected_switchers;;
	esac

	if [ "${operation}" = "disable" ]; then
		find "${_ps_enabled_switchers_path}/" -mindepth 1 -type d -empty -delete
	fi
}

_ps_choose_sw_by_priority() {
	local group="${1}" sw1 sw2
	local high="${2##*:}" low="${3#*:}"
	if (("${high}" > "${low}")); then
		return 0
	elif (("${high}" == "${low}")); then
		sw1="${_ps_enabled_switchers_path}/${group}/${2}"
		sw2="${_ps_enabled_switchers_path}/${group}/${3}"
		if ! [[ -f "${sw1}" && -f "${sw2}" ]]; then
			sw1="${_ps_switcher_files_path}/${2%:*}.sw"
			sw2="${_ps_switcher_files_path}/${3%:*}.sw"
			if [ ! -f "${sw1}" ]; then
				return 1
			elif [ ! -f "${sw2}" ]; then
				return 0
			fi
		fi
		if (($(date -r "${sw1}" "+%s%N") < $(date -r "${sw2}" "+%s%N"))); then
			return 0
		fi
	fi
	return 1
}

_ps_select_sw() {
	local list="$(tr ' ' '\n' <<< "${@}" | sort -u)" sw sws swi swi_s mode=$(${_ps_automode} && echo "auto" || echo "manual") ghost_sw=()
	for sw in $(awk -F ':' '!a[$1]++ {print $1}' <<< "${list}"); do
		sws=($(grep "^${sw}:" <<< "${list}" | awk -F ':' '!a[$2 ":" $3]++ {print $2 ":" $3}'))
		for swi in ${!sws[@]}; do
			swi_s="${sw}:${sws[${swi}]%:*}"
			if [ ! -f "${_ps_switcher_files_path}/${swi_s#*:}.sw" ]; then
				_ps_warning "switcher ${swi_s} is ghost"
				ghost_sw+=("${swi_s#*:}")
				if ${_ps_noghost}; then
					list=$(sed "/^${swi_s}:/d" <<< "${list}")
					unset sws[${swi}]
				fi
			fi
		done
		sws=(${sws[@]})
		if (("${#sws[@]}" > 1)); then
			swi_s=""
			if ${_ps_selfmode}; then
				mode=$(_ps_get_mode_by_selected_sw "${sw}" || echo "${mode}")
			fi
			if [ "${mode}" = "manual" ]; then
				_ps_info "There are ${#sws[@]} enabled switchers in group ${_ps_blue}${sw}${_ps_bold}:"
				for swi in ${!sws[@]}; do
					_ps_message "  $((${swi}+1))) ${sws[${swi}]%%:*}\n"
				done
				_ps_message "\n"
				while ! ${_ps_noconfirm}; do
					read -p "Enter a selection (default=auto): " swi_s
					if [[ -z "${swi_s}" || "${swi_s}" = "auto" ]]; then
						swi_s=""
						break
					elif ! [[ "${swi_s}" =~ ^[0-9]+$ ]]; then
						_ps_error_message "invalid number: ${swi_s}"
					elif (("${swi_s}" < 1)) || (("${swi_s}" > "${#sws[@]}")); then
						_ps_error_message "invalid value: ${swi_s} is not between 1 and ${#sws[@]}"
					else
						swi_s=$(("${swi_s}"-1))
						break
					fi
					_ps_message "\n"
				done
			fi
			if [ -z "${swi_s}" ]; then
				for swi in ${!sws[@]}; do
					_ps_progress "$((swi+1))" "${#sws[@]}" "Auto-selecting switchers ${sw}:* by priority"
					if [ -z "${swi_s}" ] || _ps_choose_sw_by_priority "${sw}" "${sws[${swi}]}" "${sws[${swi_s}]}"; then
						swi_s="${swi}"
					fi
				done
			fi
			for swi in $(tr ' ' '\n' <<< "${!sws[@]}" | grep -v "^${swi_s}$"); do
				list=$(sed "/^${sw}:${sws[${swi}]}/d" <<< "${list}")
			done
		elif ${_ps_noghost} && (("${#sws[@]}" == 0)); then
			_ps_init_error "all listed switchers of group ${sw} are ghosts: ${ghost_sw[@]}"
		fi
	done
	if ${_ps_haserror}; then
		exit 1
	fi

	for sw in $(_ps_get_selected_switchers -o <<< "${list}" | sort -u); do
		sw="${sw::-1}"
		if [ "${operation}" != "enable" ] || _ps_check_checksum_switcher "${sw}"; then
			_ps_warning "switcher ${sw} is already selected"
			if ${_ps_needed}; then
				list=$(sed "/^${sw}:/d" <<< "${list}")
			fi
		fi
	done
	if [ -n "${ghost_sw}" ] && ! ${_PS_RUN_IN_ALPM_HOOKS}; then
		ghost_sw=($(awk -F ':' '{print $1 ":" $2}' <<< "${list}" | sort -u | grep -E ":($(tr ' ' '|' <<< "${ghost_sw[@]}"))"))
		if [ -n "${ghost_sw}" ]; then
			_ps_info "Ghost switchers are going to be selected:"
			for sw in ${ghost_sw[@]}; do
				_ps_message "  ${_ps_bold}${sw}${_ps_nostyle}\n"
			done
			_ps_question_to_continue
		fi
	fi

	echo "${list}"
}

_ps_sw_analog_by_group() {
	local sws=(${@})
	tr ' ' '\n' <<< "${_ps_enabled_sw[@]}" | \
		grep -E "^($(tr ' ' '\n' <<< "${sws[@]%:*}" | sort -u | paste -sd '|')):" | \
		grep -Ev "^($(tr ' ' '|' <<< "${sws[@]}")):" || true
}

_ps_question_to_continue() {
	local yn
	if ! ${_ps_noconfirm}; then
		_ps_message "\n"
		read -p "$(_ps_header_standard "Do you want to continue? [Y/n] ")" yn
		if ! [[ -z "${yn}" || "${yn,,}" = "y" || "${yn,,}" = "yes" ]]; then
			exit 1
		fi
	fi
}

_ps_notify_about_sw_and_get_confirm() {
	${_PS_RUN_IN_ALPM_HOOKS} && return

	_ps_info "The following switcher will be ${1}:"
	awk -F ':' -v bold="${_ps_bold}" -v nostyle="${_ps_nostyle}" '{
		if (sw != $1 ":" $2) {
			sw = $1 ":" $2
			print "  " bold sw nostyle
		}
		print "    " (($4 == "") ? "[unknown]" : $4)
	}' <<< "${2}"
	shift 1
	shift 1

	while (($#/2 > 0)); do
		if [ -n "${2}" ]; then
			_ps_message "\n"
			_ps_info "${1}:"
			_ps_message "${2}\n"
		fi
		shift 1
		shift 1
	done

	_ps_question_to_continue
}

_ps_enable() {
	_ps_selfmode=true

	local data_sw
	_ps_commit "Reading switcher files"
	data_sw=$(_ps_read_switcher_file ${@})

	_ps_commit "Checking switchers status for enabling"
	local sw sw_select=() sw_reselect=()
	if ${_ps_enable_select}; then
		sw_select+=(${data_sw})
	fi
	local sws=$(awk -F ':' '!a[$1 ":" $2]++ {print $1 ":" $2}' <<< "${data_sw}")
	for sw in ${sws}; do
		if ! ${_ps_enable_select} && ! [[ " ${sw_select[@]}" =~ " ${sw%%:*}:" ]]; then
			if [ "$(_ps_get_mode_by_selected_sw "${sw%%:*}")" = "auto" ]; then
				_ps_warning "switcher group ${sw%%:*} is on auto mode, reselecting needed"
				sw_select+=($(grep "^${sw%%:*}:" <<< "${data_sw}"))
			else
				sws=$(sed "/^${sw%%:*}:/d" <<< "${sws}")
			fi
		fi
		if [[ " ${_ps_enabled_sw[@]}" =~ " ${sw}:" ]]; then
			if _ps_check_checksum_switcher "${sw}"; then
				_ps_warning "switcher ${sw} is already enabled"
				if ${_ps_needed}; then
					data_sw=$(sed "/^${sw}:/d" <<< "${data_sw}")
				fi
			elif ! ${_ps_enable_select} && [[ " ${_ps_selected_sw[@]%:*} " =~ " ${sw} " ]]; then
				_ps_warning "switcher ${sw} requires reselecting"
				sw_reselect+=($(grep "^${sw}:" <<< "${data_sw}"))
			fi
		fi
	done
	if [ -n "${sw_select}" ]; then
		_ps_commit "Checking switchers status for selecting"
		if ${_ps_automode}; then
			for sw in $(awk -F ':' '!a[$1]++ {print $1}' <<< "${sws}"); do
				if [ "$(_ps_get_mode_by_selected_sw "${sw}")" = "manual" ]; then
					_ps_warning "switcher group ${sw} is on manual mode, selecting canceled"
					sws=$(sed "/^${sw}:/d" <<< "${sws}")
				fi
			done
			sw_select=($(tr ' ' '\n' <<< "${sw_select[@]}" | grep -E "^($(paste -sd '|' <<< ${sws})):" || true))
		fi
		if [ -n "${sws}" ]; then
			sw_select=($(_ps_needed=true _ps_select_sw ${sw_select[@]} $(_ps_sw_analog_by_group ${sws})))
		else
			sw_select=()
		fi
	fi
	sw_select+=(${sw_reselect[@]})
	if ${_ps_needed} && [[ -z "${data_sw}" && -z "${sw_select}" ]]; then
		_ps_nothing_to_do
	fi
	if [[ -n "${data_sw}" && -n "${sw_select}" ]]; then
		data_sw="$(tr ' ' '\n' <<< "${sw_select[@]}"; grep -Ev "^($(tr ' ' '|' <<< "${sw_select[@]}"))$" <<< "${data_sw}" || true)"
	fi

	if [ -n "${data_sw}" ]; then
		_ps_commit "Checking switchers for enabling"
		_ps_check_sw "enable" ${data_sw}
	fi

	if [ -n "${sw_select}" ]; then
		_ps_commit "Checking switchers for selecting"
		_ps_check_sw "select" ${sw_select[@]}
	fi

	if [ -n "${data_sw}" ]; then
		_ps_commit "Enabling associations"
		_ps_action_association "enable" ${data_sw}
	fi

	if [ -n "${sw_select}" ]; then
		_ps_commit "Installing associations"
		_ps_action_association "install" ${sw_select[@]}
	fi
}

_ps_disable() {
	_ps_commit "Getting enabled switchers"
	local data_sw
	if [[ -z "${@}" ]]; then
		data_sw="$(tr ' ' '\n' <<< ${_ps_enabled_sw[@]})"
	else
		data_sw=$(_ps_get_enabled_switcher ${@})
	fi

	local sw sws=($(awk -F ':' '!a[$1 ":" $2]++ {print $1 ":" $2}' <<< "${data_sw}"))
	if ${_ps_disable_ghost}; then
		_ps_commit "Searching ghost switchers for disabling"
		for sw in ${!sws[@]}; do
			if [ -f "${_ps_switcher_files_path}/${sws[sw]#*:}.sw" ]; then
				data_sw=$(sed "/^${sws[sw]}:/d" <<< "${data_sw}")
				unset sws[${sw}]
			fi
		done
		if [ -z "${data_sw}" ]; then
			_ps_nothing_to_do
		fi
	fi

	_ps_commit "Checking switchers for disabling"
	_ps_check_sw "disable" ${data_sw}

	local reject_sw
	if ${_ps_disable_reject}; then
		reject_sw=$(_ps_select_selected_sw=true _ps_noerror=true _ps_nomessage=true _ps_get_enabled_switcher ${sws[@]} || true)
		if ! (${_ps_disable_ghost} || ${_ps_automode}) && [ -z "${reject_sw}" ]; then
			_ps_warning "no switchers found that need rejecting"
		fi
	fi
	local select_sw
	if ${_ps_automode}; then
		_ps_commit "Checking switchers status for selecting"
		for sw in ${!sws[@]}; do
			if [ "$(_ps_get_mode_by_selected_sw ${sws[${sw}]%:*})" != "auto" ]; then
				_ps_warning "switcher group ${sws[${sw}]%:*} is on manual mode, reselecting canceled"
				unset sws[${sw}]
			fi
		done
		select_sw=$(_ps_needed=true _ps_select_sw $(_ps_sw_analog_by_group ${sws[@]}))
		if [ -n "${select_sw}" ]; then
			_ps_commit "Checking switchers for selecting"
			_ps_check_sw "select" ${select_sw}
		fi
	fi

	_ps_notify_about_sw_and_get_confirm "disabled" "${data_sw}" \
		"The following switchers will be rejected" \
		"$([ -n "${reject_sw}" ] && awk -F ':' '{ if (sw != $1 ":" $2) {sw = $1 ":" $2; print "  " sw}}' <<< "${reject_sw}" || true)" \
		"The following switchers will be selected" \
		"$(awk -F ':' -v sws="$(tr ' ' ',' <<< ${sws[@]})" '{ if ($1 != "" && $2 != "") !a[$1 ":" $2]++ } END {
			split(sws, sws_array, ",")
			for (i in a) {
				split(i, i_array, ":")
				for (j in sws_array)
					if (sws_array[j] ~ i_array[1] ":")
						print "  " sws_array[j] " -> " i
			}
		}' <<< "${select_sw}")"

	if [ -n "${reject_sw}" ]; then
		_ps_commit "Removing associations"
		_ps_action_association "remove" ${reject_sw}
	fi

	_ps_commit "Disabling associations"
	_ps_action_association "disable" ${data_sw}

	if [ -n "${select_sw}" ]; then
		_ps_commit "Installing associations"
		_ps_action_association "install" ${select_sw}
	fi
}

_ps_select() {
	_ps_commit "Getting enabled switchers"
	local data_sw
	if [[ -z "${@}" ]]; then
		data_sw="$(tr ' ' '\n' <<< ${_ps_enabled_sw[@]})"
	else
		data_sw=$(_ps_get_enabled_switcher ${@})
	fi

	_ps_commit "Checking switchers status for $(${_ps_updatemode} && echo "updating" || echo "selecting")"
	local sws=() sw_select=() sw
	if ${_ps_updatemode}; then
		sws=($(awk -F ':' '!a[$1 ":" $2]++ {print $1 ":" $2}' <<< "${data_sw}"))
		for sw in ${!sws[@]}; do
			if _ps_check_checksum_switcher "${sws[${sw}]}" || \
			([ ! -f "${_ps_switcher_files_path}/${sws[${sw}]##*:}.sw" ] && _ps_warning "switcher ${sws[${sw}]} is ghost, skip updating"); then
				unset sws[${sw}]
			fi
		done
	else
		sw_select=($(_ps_select_sw ${data_sw}))
	fi
	if (${_ps_updatemode} && [[ -z "${sws[@]}" ]]) || (${_ps_needed} && [ -z "${sw_select}" ]); then
		_ps_nothing_to_do
	fi
	if ${_ps_updatemode}; then
		data_sw=$(_ps_read_switcher_file ${sws[@]})
		sw_select=$(_ps_get_selected_switchers <<< "${data_sw}")
	fi

	if ${_ps_updatemode} && [ -n "${data_sw}" ]; then
		_ps_commit "Checking switchers for updating"
		_ps_check_sw "enable" ${data_sw}
	fi

	if [ -n "${sw_select}" ]; then
		_ps_commit "Checking switchers for selecting"
		_ps_check_sw "select" ${sw_select[@]}
	fi

	if ${_ps_updatemode} && [ -n "${data_sw}" ]; then
		_ps_commit "Updating associations"
		_ps_action_association "update" ${data_sw}
	fi

	if [ -n "${sw_select}" ]; then
		_ps_commit "Installing associations"
		_ps_action_association "install" ${sw_select[@]}
	fi
}

_ps_reject() {
	if ! ${_ps_automode} && ${_ps_reject_disable}; then
		_ps_selfmode=true
	fi

	_ps_commit "Getting selected switchers"
	local data_sw
	data_sw=$(_ps_select_selected_sw=true _ps_get_enabled_switcher ${@})

	_ps_commit "Checking switchers for rejecting"
        _ps_check_sw "reject" ${data_sw}

	local sws sw_select sw
	if ${_ps_reject_replace}; then
		_ps_commit "Searching for alternatives for switchers"
		sws=$(awk -F ':' '!a[$1 ":" $2]++ {print $1 ":" $2}' <<< "${data_sw}")
		sw_select=$(_ps_select_sw $(_ps_sw_analog_by_group ${sws}))
		for sw in $(grep -Ev "^$(awk -F ':' '!a[$1]++ {print $1}' <<< "${sw_select}" | paste -sd '|'):" <<< "${sws}"); do
			_ps_warning "could not find alternative to ${sw} switcher"
		done
	fi

	_ps_notify_about_sw_and_get_confirm "rejected$(${_ps_reject_disable} && echo " and disabled" || true)" "${data_sw}" \
		"The following switchers will be selected as an alternative to rejected switchers" \
		"$(awk -F ':' -v sws="$(paste -sd ',' <<< ${sws})" '{ if ($1 != "" && $2 != "") !a[$1 ":" $2]++ } END {
			split(sws, sws_array, ",")
			for (i in a) {
				split(i, i_array, ":")
				for (j in sws_array)
					if (sws_array[j] ~ i_array[1] ":")
						print "  " sws_array[j] " -> " i
			}
		}' <<< "${sw_select}")"

	_ps_commit "Removing associations"
	_ps_action_association "remove" ${data_sw}

	if ${_ps_reject_disable}; then
		_ps_commit "Disabling associations"
		_ps_action_association "disable" ${data_sw}
	fi

	if [ -n "${sw_select}" ]; then
		_ps_commit "Installing alternative associations"
		_ps_action_association "install" ${sw_select}
	fi
}

_ps_query() {
	_ps_query_print_result() {
		eval "if [ -n \"\${${1}}\" ]; then
			echo \"  ${2}:\"
			for sw in \${${1}[@]}; do
				echo \"    ${3}\"
			done
		fi"
	}

	local data_sw
	if [[ -z "${@}" ]]; then
		data_sw="$(tr ' ' '\n' <<< ${_ps_enabled_sw[@]})"
	else
		data_sw=$(_ps_nomessage=true _ps_noerror=${_ps_query_switchers} _ps_get_enabled_switcher ${@})
	fi

	if [ -z "${data_sw}" ]; then
		if ${_ps_guery_check}; then
			_ps_warning "there is nothing to check because there are no enabled switchers"
			_ps_nothing_to_do
		fi
		return
	fi

	local sws sw group name
	if ${_ps_query_switchers}; then
		awk -F ':' '!a[$1 ":" $2]++ {print (($1 == "") ? "[unknown]" : $1) ":" (($2 == "") ? "[unknown]" : $2)}' <<< "${data_sw}"
	elif ${_ps_query_switcherfiles}; then
		find ${_ps_switcher_files_path} -maxdepth 1 -mindepth 1 | grep -E "/($(awk -F ':' '!a[$2]++ {if ($2 != "") print $2}' <<< "${data_sw}" | paste -sd '|')).sw$"
	elif ${_ps_query_global_list}; then
		echo "${data_sw}"
	elif ${_ps_query_list}; then
		awk -F ':' -v bold="${_ps_bold}" -v nostyle="${_ps_nostyle}" '{
			group = ($1 == "") ? "[unknown]" : $1
			name = ($2 == "") ? "[unknown]" : $2
			link_path = ($4 == "") ? "[unknown]" : $4
			print bold group ":" name nostyle " " link_path
		}' <<< "${data_sw}"
	elif ${_ps_query_info}; then
		awk -F ':' -v prefix="${_ps_prefix}/" -v sw_files_path="${_ps_switcher_files_path}/" -v bold="${_ps_bold}" -v nostyle="${_ps_nostyle}" '{
			if (sw != $1 ":" $2) {
				if (sw != "")
					print ""
				sw = $1 ":" $2
				print bold "Switcher" nostyle "      : " (($2 == "") ? "[unknown]" : $2)
				print bold "Group" nostyle "         : " (($1 == "") ? "[unknown]" : $1)
				print bold "Priority" nostyle "      : " (($3 == "") ? "[unknown]" : $3)
				printf bold "Ghost" nostyle "         : "
				if (system("test -f " sw_files_path $2 ".sw"))
					print "Yes"
				else
					print "No"
				printf bold "Associations" nostyle "  : "
			} else {
				printf "                "
			}
			gsub(prefix, "", $4)
			gsub(prefix, "", $5)
			print (($4 == "") ? "[unknown]" : $4) " -> " (($5 == "") ? "[unknown]" : $5)
		}
		END {
			print ""
		}' <<< "${data_sw}"
	elif ${_ps_guery_check}; then
		_ps_commit "Checking switcher data integrity"
		data_sw=(${data_sw})
		for sw in $(_ps_nomessage=true _ps_check_switcher_data_integrity ${_ps_enabled_sw[@]}); do
			_ps_error_message "switcher data has an integrity problem: ${_ps_enabled_sw[${sw}]}"
			_ps_non_integrity_sw+=("${_ps_enabled_sw[${sw}]}")
			data_sw=($(sed "s| ${_ps_enabled_sw[${sw}]} | |" <<< " ${data_sw[@]} "))
		done
		if [[ "${#data_sw[@]}" = "0" ]]; then
			_ps_error "all switcher data have integrity problems"
		fi

		_ps_commit "Comparing switcher data with data from switcher files"
		sws=($(awk -F ':' -v RS=' ' '!a[$1 ":" $2]++ {print $1 ":" $2}' <<< "${data_sw[@]}"))
		local data_file fail_checksum fail_diff issue_data=()
		for sw in ${sws[@]}; do
			if [ -f "${_ps_switcher_files_path}/${sw#*:}.sw" ]; then
				data_file=$(_ps_nomessage=true _ps_noerror=true _ps_read_switcher_file "${sw}")
				if [ -z "${data_file}" ]; then
					_ps_error_message "failed to read switcher file ${sw} correctly: switcher file is corrupted"
					issue_data+=("${sw}")
				else
					fail_checksum=false
					fail_diff=false
					if ! _ps_check_checksum_switcher "${sw}"; then
						_ps_warning "switcher sum check ${sw} failed"
						fail_checksum=true
					fi
					if ! diff <(tr ' ' '\n' <<< "${data_sw[@]}" | grep "^${sw}:" | sort) <(sort <<< "${data_file}") > /dev/null 2>&1; then
						_ps_warning "there are differences in data with switcher file ${sw}"
						fail_diff=true
					fi
					if ! ${fail_checksum} && ${fail_diff}; then
						_ps_error_message "switcher data ${sw} has changes that are not committed by checksum"
						issue_data+=("${sw}")
					fi
				fi
			else
				_ps_error_message "switcher ${sw} is ghost: switcher file not found"
				issue_data+=("${sw}")
			fi
		done

		_ps_commit "Checking for switcher associations"
		local issue_env=($(_ps_check_sw "query" ${data_sw[@]}))

		_ps_commit "Checking selected switchers"
		local issue_select=($(_ps_selfmode=true _ps_action_association "query" $(tr ' ' '\n' <<< ${data_sw[@]} | _ps_get_selected_switchers) | sort -u))

		_ps_info "Check result:"
		if [[ -z "${_ps_non_integrity_sw}" && -z "${issue_data}" && -z "${issue_env}" && -z "${issue_select}" ]]; then
			_ps_nothing_to_do
		fi
		_ps_query_print_result "_ps_non_integrity_sw" "found switcher data that have integrity problems, such data skips checking" '${sw}'
		_ps_query_print_result "issue_data" "found problems with verification of switcher data" '${sw}'
		_ps_query_print_result "issue_env" "found switchers that have environmental problems" '${data_sw[${sw}]}'
		_ps_query_print_result "issue_select" "found switchers that have problems with selected associations" '${sw}'
	else
		sws=($(awk -F ':' '!a[$1 ":" $2]++ {print $1 ":" $2 ":" $3}' <<< "${data_sw}"))
		for sw in $(tr ' ' '\n' <<< ${sws[@]%%:*} | sort -u); do
			echo -e "${_ps_bold}${sw}${_ps_nostyle}"
			if ! ${_ps_query_groups}; then
				for name in $(awk -F ':' -v RS=' ' -v sw="${sw}" '{if (sw == $1) print (($2 == "") ? "[unknown]" : $2) ":" $3}' <<< "${sws[@]}"); do
					echo -n "  ${name:=[unknown]}"
					if [[ " ${_ps_selected_sw[@]%:*} " =~ " ${sw}:${name%%:*} " ]]; then
						echo -n " [selected:$(_ps_get_mode_by_selected_sw ${sw})]"
					fi
					echo
				done
			fi
		done
	fi
}

_ps_install() {
	local file_sw=(${@})

	_ps_commit "Checking switchers status for installing"
	local sw swf swf swf_modified=()
	for sw in ${!file_sw[@]}; do
		swf="${_ps_switcher_files_path}/${file_sw[${sw}]##*/}"
		if [ -f "${swf}" ]; then
			if [[ "$(_ps_get_checksum_switcher "${file_sw[${sw}]}")" = "$(_ps_get_checksum_switcher "${swf}")" ]]; then
				_ps_warning "switcher file ${file_sw[${sw}]##*/} is already installed"
				if ${_ps_needed}; then
					unset file_sw[${sw}]
				fi
			else
				swf_modified+=("${file_sw[${sw}]##*/}")
			fi
		fi
	done
	if [[ -z "${file_sw[@]}" ]]; then
		_ps_nothing_to_do
	fi

	local data_sw
	_ps_commit "Reading switcher files"
	data_sw=$(_ps_read_switcher_file ${@})

	_ps_commit "Checking switchers for installing"
	_ps_check_sw "install" ${data_sw}

	if [ -n "${swf_modified}" ]; then
		_ps_notify_about_sw_and_get_confirm "installed with modified associations" \
			"$(grep -E ":($(tr ' ' '|' <<< ${swf_modified[@]%.*})):" <<< "${data_sw}")"
	fi

	_ps_commit "Installing switchers"
	for sw in ${!file_sw[@]}; do
		_ps_progress_noret=true _ps_progress "$((sw+1))" "${#file_sw[@]}" "installing ${file_sw[${sw}]##*/} file switcher"
		cp -r ${file_sw[${sw}]} ${_ps_switcher_files_path}
	done
}

_ps_uninstall() {
	local file_sw=() sw swf
	for sw in ${@#*:}; do
		swf="${_ps_switcher_files_path}/${sw}.sw"
		if [ ! -f "${swf}" ]; then
			_ps_init_error "switcher file ${sw}.sw not found"
		else
			file_sw+=("${swf}")
		fi
	done
	if ${_ps_haserror}; then
		exit 1
	fi

	local data_sw
	_ps_commit "Reading switcher files"
	data_sw=$(_ps_read_switcher_file ${@})

	_ps_commit "Checking switchers for uninstalling"
	_ps_check_sw "uninstall" ${data_sw}

	_ps_notify_about_sw_and_get_confirm "uninstalled" "${data_sw}"

	_ps_commit "Uninstalling switchers"
	for sw in ${!file_sw[@]}; do
		_ps_progress_noret=true _ps_progress "$((sw+1))" "${#file_sw[@]}" "removing ${file_sw[${sw}]##*/} file switcher"
		rm ${file_sw[${sw}]}
	done
}

_ps_help_main() {
	_ps_message "usage:  pacman-switch <operation> [...]
operations:
    pacman-switch {-h --help}
    pacman-switch {-V --version}
    pacman-switch {-E --enable}     [options] [switcher(s)]
    pacman-switch {-D --disable}    [options] [switcher(s)]
    pacman-switch {-S --select}     [options] [switcher(s)]
    pacman-switch {-R --reject}     [options] [switcher(s)]
    pacman-switch {-Q --query}      [options] [switcher(s)]
    pacman-switch {-I --install}    [options] [file(s)]
    pacman-switch {-U --uninstall}  [options] [switcher(s)]

use 'pacman-switch <operation> {-h --help}' with an operation for available options\n"
}

_ps_help_enable() {
	_ps_message "usage:  pacman-switch {-E --enable} [options] [switcher(s)]
options:
  -a, --auto
  -s, --select
      --needed
      --noconfirm
      --noghost\n"
}

_ps_help_disable() {
	_ps_message "usage:  pacman-switch {-D --disable} [options] [switcher(s)]
options:
  -a, --auto
  -g, --ghost
  -r, --reject
      --noconfirm\n"
}

_ps_help_select() {
	_ps_message "usage:  pacman-switch {-S --select} [options] [switcher(s)]
options:
  -a, --auto
  -u, --update
      --needed
      --noconfirm
      --noghost
      --overwrite\n"
}

_ps_help_reject() {
	_ps_message "usage:  pacman-switch {-U --reject} [options] [switcher(s)]
options:
  -a, --auto
  -d, --disable
  -r, --replace
      --noconfirm
      --noghost\n"
}

_ps_help_query() {
	_ps_message "usage:  pacman-switch {-Q --query} [options] [switcher(s)]
options:
  -c, --check
  -f, --switcherfiles
  -g, --groups
  -i, --info
  -l, --list (-ll)
  -s, --switchers\n"
}

_ps_help_install() {
	_ps_message "usage:  pacman-switch {-I --install} [options] [switcher(s)]
options:
  --needed
  --noconfirm\n"
}

_ps_help_uninstall() {
	_ps_message "usage:  pacman-switch {-U --uninstall} [options] [switcher(s)]
options:
  --noconfirm\n"
}

_ps_version_info() {
	_ps_message "version: ${_ps_version}\n"
}

_ps_run_operation() {
	_ps_run_operation_add_switcher() {
		if ! [[ " ${switchers[@]} " =~ " ${1} " ]]; then
			switchers+=("${1}")
		fi
	}

	local operation="${1}" arg_switchers=()
	shift 1

	case "${operation}" in
		"enable"|"disable"|"select"|"reject"|"query"|"install"|"uninstall");;
		*) _ps_error "internal error: unknown operation '${operation}' for _ps_run_operation";;
	esac

	eval "$(awk -F ':' -v ps_args="$(tr ' ' ',' <<< ${_ps_args[@]})" -v RS=" " 'BEGIN {
		split(ps_args, args_array, ",")
	}
	{
		len=0
		for (i in args_array)
			if (args_array[i] == $1)
				len++
		if (len >= $2) {
			split($3, funcs, ",")
			for (i in funcs) {
				gsub(/\n/, "", funcs[i])
				print "_ps_" funcs[i] "=true"
			}
			for (i in args_array)
				if (args_array[i] == $1)
					delete args_array[i]
		}
	}
	function print_array(name, array) {
		printf name "=("
		for (i in array)
			printf array[i] " "
		print ")"
	}
	END {
		i=1
		for (j in args_array) {
			arg = args_array[j]
			if (substr(arg, 1, 1) == "-")
				args[i] = arg
			else
				sws[i] = arg
			i++
		}
		print_array("_ps_args", args)
		print_array("arg_switchers", sws)
	}' <<< "${@}")"

	if [ -n "${_ps_args}" ]; then
		_ps_error "invalid option '$(tr ' ' '\n' <<< "${_ps_args[@]}" | sort -u | paste -sd ' ')'"
	fi

	if ${_ps_helpmode}; then
		_ps_help_${operation}
		return
	fi

	eval "$(awk -v RS=' ' 'BEGIN {
		i=1
	}
	{
		gsub(/\n/, "", $1)
		syn[i] = $1
		i++
	}
	END {
		len = i-1
		for (i in syn) {
			for (j in syn) {
				if (i == j)
					continue
				x=(i+len**(i%2+1))*(j+len**(j%2+1))
				if (!(x in sort))
					sort[x] = syn[i] ":" syn[j]
			}
		}
		for (i in sort) {
			split(sort[i], sort_array, ":")
			print "${_ps_" sort_array[1] "} && ${_ps_" sort_array[3] "} && _ps_error \"invalid option: '"'"'--" sort_array[2] "'"'"' and '"'"'--" sort_array[4] "'"'"' may not be used together\" || true"
		}
	}' <<< "${_ps_conflicting_args}")"

	if [ ! -d "${_ps_switcher_files_path}" ]; then
		_ps_init_error "path to switcher files not found: ${_ps_switcher_files_path}"
	fi
	if [ ! -d "${_ps_enabled_switchers_path}" ]; then
		_ps_init_error "path to switchers not found: ${_ps_enabled_switchers_path}"
	fi
	if ${_ps_haserror}; then
		exit 1
	fi

	_ps_read_enabled_switchers

	local switchers=() switcher group name
	for switcher in ${arg_switchers[@]}; do
		if ${_ps_arg_is_swfile}; then
			if [[ "${switcher::1}" != "/" && "${switcher::1}" != "." ]]; then
				switcher="./${switcher}"
			fi
			switcher="$(realpath ${switcher})"
			if [ -f "${switcher}" ]; then
				if [ "${switcher##*.}" != "sw" ]; then
					_ps_init_error "specified file is not switcher file"
				else
					_ps_run_operation_add_switcher "${switcher}"
				fi
				continue
			fi
		else
			if ! [[ "${switcher}" =~ ":" ]]; then
				switcher=$(${_ps_onlygroup} && echo "${switcher}:" || echo ":${switcher}")
			fi
			group="${switcher%%:*}"
			name="${switcher##*:}"
			: "${group:="*"}"
			: "${name:="*"}"
			if [[ "${group}" = "*" && "${name}" = "*" ]]; then
				_ps_error "syntax error: switcher unassigned"
			fi
			switcher="${group}:${name}"
			if grep -Eqs "(^| )switcher_group_${group//\*/\.*}( |\()" "${_ps_switcher_files_path}/"${name}".sw" || \
				grep -q " ${switcher//\*/\.*}:" <<< " ${_ps_enabled_sw[@]}"; then
				if (${_ps_onlygroup} && [ "${name}" != "*" ]) || (${_ps_onlyswitcher} && [ "${group}" != "*" ]); then
					_ps_warning "switcher ${switcher} will be ignored (need to specify $(${_ps_onlygroup} && echo "group" || echo "switcher"))"
				else
					_ps_run_operation_add_switcher "${switcher}"
				fi
				continue
			fi
		fi
		_ps_init_error "switcher not found: ${switcher}"
	done
	if ${_ps_haserror}; then
		exit 1
	fi

	if ! ${_ps_norequire_sw} && ((${#switchers} == 0)); then
		_ps_error "no targets specified"
	fi

	_ps_read_selected_switchers
	_ps_static_selected_sw=(${_ps_selected_sw[@]})

	_ps_chmod_switchers +w
	_ps_${operation} "${switchers[@]}"
}

trap '_ps_chmod_switchers -w' EXIT

_ps_title_error="error:"
_ps_title_warning="warning:"
if ${_PS_RUN_IN_ALPM_HOOKS}; then
	_ps_title_error="==> ERROR:"
	_ps_title_warning="==> WARNING:"
fi

if [ "$(type -t pacman-conf)" != "file" ]; then
	_ps_error "pacman-conf not found"
fi

_ps_pacman_dbpath="$(pacman-conf DBPath)"
if [ -z "${_ps_pacman_dbpath}" ]; then
	_ps_error "failed to define DBPath in pacman-conf"
fi

_ps_style="$(pacman-conf Color)"
if [ -z "${_ps_style}" ]; then
	_ps_style=false
else
	_ps_style=true
fi
if ${_ps_style}; then
	_ps_bold="\033[0;1m"
	_ps_nostyle="\033[0m"
	_ps_blue="\033[1;34m"
	_ps_green="\033[1;32m"
	_ps_yellow="\033[1;33m"
	_ps_red="\033[1;31m"
fi

_ps_title_header="${_ps_blue}::"
_ps_title_progress=""
if ${_PS_RUN_IN_ALPM_HOOKS}; then
	_ps_title_header="${_ps_green}==>"
	_ps_title_progress="  ${_ps_blue}->${_ps_bold} "
fi

_ps_args=($(awk -v RS=' ' '{
	gsub(/\x1B\[[0-9;]*[A-Za-z]/, "", $1)
	if (substr($1, 1, 1) == "-") {
		count = gsub("-", "", $1)
		if (count == 1)
			gsub(/./, " -&", $1)
		else if (count >= 2)
			printf "--"
	}
	print $1
}' <<< "${@}"))
_ps_conflicting_args=""

_ps_root_arg="${_ps_args[0]}"
unset _ps_args[0]

if [ -z "${_ps_root_arg}" ]; then
	_ps_error "no operation specified (use -h for help)"
fi

case "${_ps_root_arg}" in
	-E|--enable)
	_ps_run_operation enable \
		-{s,-select}:1:enable_select \
		-{a,-auto}:1:automode,enable_select \
		-{h,-help}:1:helpmode \
		--needed:1:needed \
		--noconfirm:1:noconfirm \
		--noghost:1:noghost
	;;
	-D|--disable)
	_ps_conflicting_args="disable_ghost:ghost automode:auto"
	_ps_run_operation disable \
		-{a,-auto}:1:automode,disable_reject \
		-{g,-ghost}:1:disable_ghost,disable_reject,norequire_sw \
		-{u,-reject}:1:disable_reject \
		-{h,-help}:1:helpmode \
		--noconfirm:1:noconfirm
	;;
	-S|--select)
	_ps_conflicting_args="automode:auto updatemode:update"
	_ps_run_operation select \
		-{a,-auto}:1:automode,onlygroup \
		-{u,-update}:1:updatemode,norequire_sw \
		-{h,-help}:1:helpmode \
		--needed:1:needed \
		--noconfirm:1:noconfirm \
		--noghost:1:noghost \
		--overwrite:1:overwrite
	;;
	-R|--reject)
	_ps_run_operation reject \
		-{r,-replace}:1:reject_replace \
		-{d,-disable}:1:reject_disable \
		-{a,-auto}:1:automode,reject_replace,reject_disable \
		-{h,-help}:1:helpmode \
		--noconfirm:1:noconfirm \
		--noghost:1:noghost
	;;
	-Q|--query)
	_ps_norequire_sw=true
	_ps_conflicting_args="guery_check:check query_groups:groups query_info:info query_list:list query_switchers:switchers query_switcherfiles:switcherfiles"
	_ps_run_operation query \
		-{h,-help}:1:helpmode \
		-{c,-check}:1:guery_check \
		-{g,-groups}:1:query_groups \
		-{i,-info}:1:query_info \
		-{l,-list}:2:query_list,query_global_list \
		-{l,-list}:1:query_list \
		-{s,-switchers}:1:query_switchers \
		-{f,-switcherfiles}:1:query_switcherfiles
	;;
	-I|--install)
	_ps_arg_is_swfile=true
	_ps_run_operation install \
		-{h,-help}:1:helpmode \
		--needed:1:needed \
		--noconfirm:1:noconfirm
	;;
	-U|--uninstall)
	_ps_onlyswitcher=true
	_ps_run_operation uninstall \
		-{h,-help}:1:helpmode \
		--noconfirm:1:noconfirm
	;;
	-V|--version)
	_ps_version_info
	;;
	-h|--help)
	_ps_help_main
	;;
	*)
	_ps_error "invalid option ${_ps_root_arg}"
	;;
esac

exit 0
