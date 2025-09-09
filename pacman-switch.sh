#!/usr/bin/bash

set -e

# pacman-switch system info
_ps_version="1.0.0-BETA"
_ps_prefix="${PWD}/usr"
_ps_switcher_files_path="${_ps_prefix}/share/pacman-switch"
_ps_enabled_switchers_path="${_ps_prefix}/var/lib/pacman/switch"

# database
_ps_enabled_sw=()
_ps_setted_sw=()
_ps_static_setted_sw=()

# system variable settings for internal work
_ps_nomessage=false
_ps_select_setted_sw=false
_ps_selfmode=false
_ps_nowarning=false
_ps_noerror=false
_ps_onlygroup=false
_ps_norequire_sw=false
_ps_haserror=false

# user variable settings / user options
_ps_needed=false
_ps_noconfirm=false
_ps_noghost=false
_ps_enable_set=false
_ps_unset_disable=false
_ps_unset_replace=false
_ps_disable_unset=false
_ps_disable_ghost=false
_ps_query_groups=false
_ps_query_global_list=false
_ps_query_list=false
_ps_query_info=false
_ps_helpmode=false
_ps_automode=false
_ps_updatemode=false

_ps_message() {
	! ${_ps_nomessage} && echo -ne "$1" >&2 || true
}

_ps_progress() {
	local now="$1" goal="$2"
	_ps_message "(${now}/${goal}) $3$(((now < goal)) && echo '\r' || echo '\n')"
}

_ps_header_standard() {
	echo -e "\e[1;34m::\e[0;1m $1\e[0m"
}

_ps_info() {
	_ps_message "$(_ps_header_standard "$1")\n"
}

_ps_commit() {
	_ps_info "$1..."
}

_ps_warning() {
	! ${_ps_nowarning} && _ps_message "\e[1;33mwarning:\e[0m $1\n" || true
}

_ps_error_message() {
	_ps_nomessage=false _ps_message "\e[1;31merror:\e[0m $1\n"
}

_ps_init_error() {
	_ps_error_message "$1"
	_ps_haserror=true
}

_ps_error() {
	_ps_error_message "$1"
	exit 1
}

_ps_merge_datas() {
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
	local i=1 goal=$# error=() result=()
	while (($# >= 1)); do
		_ps_progress "${i}" "${goal}" "reading switcher files"
		local switcher="${1}"
		i=$((i+1))
		shift 1

		local name="${switcher##*:}" group="${switcher%%:*}"
		if [ "${group}" = "*" ]; then
			group=".*"
		fi
		local points=() switcher_path="${_ps_switcher_files_path}/${name}.sw"
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
				if [ -z "${group}" ] || \
					grep -Eq "(^|/|:| )(/|:| |$)" <<< "${points[@]}" || \
					(($(grep -o ':' <<< "${points[@]}" | wc -l) != ${#points[@]})); then
					exit 1
				fi
				awk -v RS=" " \
					-v group="${group}" \
					-v switcher="${name}" \
					-v priority="${priority:=0}" \
					-v prefix="${_ps_prefix}" \
					'{split($1,path,":"); print group ":" switcher ":" priority ":" prefix "/" path[1] ":" prefix "/" path[2]}' \
					<<< "${points[@]}"
			)) || error+=("${group:=[unknown]}:${name}:syntax")
		done
	done
	tr ' ' '\n' <<< "${result[@]}"
	if [ -n "${error}" ]; then
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
	_ps_enabled_sw=($(for point in $(find "${_ps_enabled_switchers_path}" -mindepth 1 -type f); do
		point="${point//${_ps_enabled_switchers_path}\//}"
		awk -v point="${point//\//:}" -F "=" '{if ($1 == "point") print point ":" $2}' "${_ps_enabled_switchers_path}/${point}"
	done))
}

_ps_read_setted_switchers() {
	_ps_setted_sw=($(find "${_ps_enabled_switchers_path}" -type l -exec readlink -fn {} \; -printf ':%f\n' | sed "s|${_ps_enabled_switchers_path}/||g; s|:.*:set:|:|g; s|/|:|g"))
}

_ps_get_enabled_switcher() {
	local i=1 goal=$# notfound=() list=$(tr ' ' '\n' <<< "${_ps_enabled_sw[@]}") result=() type="enabled"
	if ${_ps_select_setted_sw}; then
		list=$(grep -E "^($(tr ' ' '|' <<< "${_ps_setted_sw[@]%:*}")):" <<< "${list}")
		type="setted"
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

_ps_check_checksum_switcher() {
	awk -F '=' -v sw_file="${_ps_switcher_files_path}/${1##*:}.sw" '{ if ($1 == "checksum") { print $2, sw_file } else {exit} }' "${_ps_enabled_switchers_path}/${1//://}:"* | sha256sum -c --status 2>/dev/null
	return $?
}

_ps_check_existence_root_path() {
	local i=0 goal=$((${#}/2+1)) list="${@}"
	if [ "${operation:-}" = "enable" ]; then
		list+=" $(awk -v RS=" " -F ':' '{printf $4 " "}' <<< "${_ps_enabled_sw[@]}")"
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

_ps_check_conflict_link_path() {
	local i=0 goal=$((${#}/2+1))
	local d_points="$(_ps_merge_datas 2 ${@} | sort -u)"
	local e_points="$(awk -v RS=' ' -F ':' '!a[$1 ":" $4]++ {print $1 ":" $4}' <<< "${_ps_enabled_sw[@]}" | grep -Ev "^($(awk -F ':' '!a[$1]++ {print $1}' <<< "${d_points}" | paste -sd '|')):")"
	while (($# >= ${goal})); do
		_ps_progress "$((i+1))" "$((goal-1))" "checking link paths for conflicts"
		if (($(grep -c ":${!goal}$" <<< "${d_points}") > 1)) || grep -q ":${!goal}$" <<< "${e_points}"; then
			echo $i
		fi
		i=$((i+1))
		shift 1
	done
}

_ps_check_conflict_enabled_switcher() {
	local i=0 goal=$((${#}/2+1)) list="$(_ps_merge_datas 2 ${@} | sort -u)" old=""
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
		_ps_progress "$((i+1))" "${goal}" "checking link paths for valid"
		if [ ! -d "${1%/*}" ]; then
			echo $i
		fi
		i=$((i+1))
		shift 1
	done
}

_ps_check_setted_switcher() {
	local i=0 goal=$((${#}/2+1)) old_switcher="" switcher
	while (($# >= ${goal})); do
		_ps_progress "$((i+1))" "$((goal-1))" "checking for setted switchers"
		switcher="${1}:${!goal}"
		if [ "${switcher}" != "${old_switcher}" ]; then
			if [[ " ${_ps_setted_sw[@]%:*} " =~ " ${switcher} " ]]; then
				echo $i
			fi
			old_switcher="${switcher}"
		fi
		i=$((i+1))
		shift 1
	done
}

_ps_check_dependent_switcher() {
	local i=0 goal="$#" list="$(tr ' ' '\n' <<< "${_ps_enabled_sw[@]}")"
	if [ "${operation:-}" = "unset" ]; then
		list="$(grep -E "^($(tr ' ' '|' <<< "${_ps_setted_sw[@]%:*}")):" <<< "${list}")"
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

_ps_check_sw() {
	local operation="$1"
	shift 1
	case "${operation}" in
		"enable"|"set"|"disable"|"unset");;
		*) _ps_error "internal error: unknown operation '${operation}' for _ps_check_sw"
	esac

	local list_group=() list_name=() list_priority=() list_link_path=() list_root_path=()
	while (($# >= 1)); do
		local split_arg=(${1//:/ })
		list_group+=("${split_arg[0]}")
		list_name+=("${split_arg[1]}")
		list_priority+=("${split_arg[2]}")
		list_link_path+=("${split_arg[3]}")
		list_root_path+=("${split_arg[4]}")
		shift 1
	done
	local i

	if [[ "${operation}" = "enable" || "${operation}" = "set" ]]; then
		local result_check_existence_root_path=$(_ps_check_existence_root_path ${list_link_path[@]} ${list_root_path[@]})
		if [ -n "${result_check_existence_root_path}" ]; then
			_ps_error_message "invalid root paths"
			for i in ${result_check_existence_root_path}; do
				echo "${list_group[$i]}:${list_name[$i]}: ${list_root_path[$i]} not found for ${list_link_path[$i]##*/}"
			done
			exit 1
		fi
		local result_check_valid_link_path=$(_ps_check_valid_link_path ${list_link_path[@]})
		if [ -n "${result_check_valid_link_path}" ]; then
			_ps_error_message "not valid link paths"
			for i in ${result_check_valid_link_path}; do
				echo "${list_group[$i]}:${list_name[$i]}: ${list_link_path[$i]%/*} not valid"
			done
			exit 1
		fi
	fi

	case "${operation}" in
		"enable")
		local result_check_conflict_link_path=$(_ps_check_conflict_link_path ${list_group[@]} ${list_link_path[@]})
		if [ -n "${result_check_conflict_link_path}" ]; then
			_ps_error_message "switcher conflicts"
			for i in ${result_check_conflict_link_path}; do
				echo "${list_group[$i]}:${list_name[$i]}: ${list_link_path[$i]} conflicts"
			done
			exit 1
		fi
		;;

		"set")
		local result_check_conflict_enabled_switcher=$(_ps_check_conflict_enabled_switcher ${list_group[@]} ${list_name[@]})
		if [ -n "${result_check_conflict_enabled_switcher}" ]; then
			_ps_error_message "enabled switcher conflicts"
			for i in ${result_check_conflict_enabled_switcher}; do
				echo "${list_group[$i]}:${list_name[$i]}: conflicts"
			done
			exit 1
		fi
		;;

		"disable")
		if ! ${_ps_disable_unset}; then
			local result_check_setted_switcher=$(_ps_check_setted_switcher ${list_group[@]} ${list_name[@]})
			if [ -n "${result_check_setted_switcher}" ]; then
				_ps_error_message "impossible disable setted switcher"
				for i in ${result_check_setted_switcher}; do
					echo "${list_group[$i]}:${list_name[$i]}: setted"
				done
				exit 1
			fi
		fi
		;;
	esac

	if [[ "${operation}" = "disable" || "${operation}" = "unset" ]]; then
		local result_check_dependent_switcher=$(_ps_check_dependent_switcher ${list_link_path[@]})
		if [ -n "${result_check_dependent_switcher}" ]; then
			_ps_error_message "switcher presents dependency"
			for i in ${result_check_dependent_switcher}; do
				echo "${list_group[$i]}:${list_name[$i]}: needed"
			done
			exit 1
		fi
	fi
}

_ps_get_mode_by_setted_sw() {
	local len="${#_ps_static_setted_sw[@]}"
	[ "${len}" = "0" ] && return 1
	awk -F ':' -v RS=" " -v gr="${1}" -v len="${len}" '{if ($1 == gr) {print $3; exit 0} else if (NR == len) {exit 1} }' <<< "${_ps_static_setted_sw[@]}"
}

_ps_action_sw_point() {
	local operation="$1"
	shift 1
	case "${operation}" in
		"enable"|"set"|"disable"|"unset");;
		*) _ps_error "internal error: unknown operation '${operation}' for _ps_action_sw_point"
	esac

	local old_sw_point i goal args=$(tr ' ' '\n' <<< "$@") mode=$(${_ps_automode} && echo "auto" || echo "manual")

	while (($# >= 1)); do
		local split_arg=(${1//:/ })
		local group="${split_arg[0]}" name="${split_arg[1]}" priority="${split_arg[2]}" link_path="${split_arg[3]}" root_path="${split_arg[4]}"

		local switcher="${group}:${name}"
		local sw_point="${group}/${name}:${priority}"
		local group_path="${_ps_enabled_switchers_path}/${group}"
		local point_path="${_ps_enabled_switchers_path}/${sw_point}"

		if [ "${old_sw_point}" != "${sw_point}" ]; then
			i=1
			goal=$(grep -c "^${switcher}:" <<< "${args}")
			if ${_ps_selfmode}; then
				mode=$(_ps_get_mode_by_setted_sw "${group}" || echo "${mode}")
			fi
		fi

		case "${operation}" in
			"enable")
			_ps_progress "${i}" "${goal}" "writing points ${switcher}"
			if [ "${old_sw_point}" != "${sw_point}" ]; then
				if [ ! -d "${group_path}" ]; then
					mkdir -p "${group_path}"
				else
					find "${group_path}" -type f -name "${name}:*" -delete
				fi
				sha256sum "${_ps_switcher_files_path}/${name}.sw" | awk '{print "checksum=" $1}' > "${point_path}"
			fi
			echo "point=${link_path}:${root_path}" >> "${point_path}"
			;;

			"set")
			_ps_progress "${i}" "${goal}" "setting points ${switcher}"
			if [ "${old_sw_point}" != "${sw_point}" ]; then
				local setted=$(tr ' ' '\n' <<< "${_ps_setted_sw[@]%:*}" | grep "^${group}:")
				if [ -n "${setted}" ]; then
					_ps_nomessage=true _ps_action_sw_point "unset" $(_ps_nomessage=true _ps_get_enabled_switcher ${setted})
				fi
				ln -sr "${point_path}" "${group_path}/set:${mode}"
			fi
			ln -sf "${root_path}" "${link_path}"
			;;

			"disable")
			_ps_progress "${i}" "${goal}" "removing points ${switcher}"
			if [ "${old_sw_point}" != "${sw_point}" ]; then
				rm "${point_path}"
			fi
			;;

			"unset")
			_ps_progress "${i}" "${goal}" "unsetting points ${switcher}"
			if [ "${old_sw_point}" != "${sw_point}" ]; then
				rm "${group_path}/set:"*
			fi
			rm "${link_path}"
			;;
		esac

		old_sw_point="${sw_point}"
		i=$((i+1))
		shift 1
	done

	case "${operation}" in
		"set"|"unset") _ps_read_setted_switchers;;
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

_ps_choose_sw_to_set() {
	local list="$(tr ' ' '\n' <<< "${@}" | sort -u)" sw sws swi swi_s mode=$(${_ps_automode} && echo "auto" || echo "manual") ghost_sw
	for sw in $(awk -F ':' '!a[$1]++ {print $1}' <<< "${list}"); do
		sws=($(grep "^${sw}:" <<< "${list}" | awk -F ':' '!a[$2 ":" $3]++ {print $2 ":" $3}'))
		ghost_sw=()
		for swi in ${!sws[@]}; do
			swi_s="${sw}:${sws[${swi}]%:*}"
			if [ ! -f "${_ps_switcher_files_path}/${swi_s#*:}.sw" ]; then
				_ps_warning "switcher ${swi_s} is ghost"
				if ${_ps_noghost}; then
					ghost_sw+=("${swi_s#*:}")
					list=$(sed "/^${swi_s}:/d" <<< "${list}")
					unset sws[${swi}]
				fi
			fi
		done
		sws=(${sws[@]})
		if (("${#sws[@]}" > 1)); then
			swi_s=""
			if ${_ps_selfmode}; then
				mode=$(_ps_get_mode_by_setted_sw "${sw}" || echo "${mode}")
			fi
			if [ "${mode}" = "manual" ]; then
				_ps_info "There are ${#sws[@]} enabled switchers in group \033[1;34m${sw}\033[0;1m:"
				for swi in ${!sws[@]}; do
					_ps_message "   $((${swi}+1))) ${sws[${swi}]%%:*}\n"
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
					_ps_progress "$((swi+1))" "${#sws[@]}" "Auto-choosing switchers from group ${sw} by priority"
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

	ghost_sw=()
	for sw in $(grep -Eo "^($(tr ' ' '|' <<< "${_ps_setted_sw[@]%:*}")):" <<< "${list}" | sort -u); do
		sw="${sw::-1}"
		if _ps_check_checksum_switcher "${sw}"; then
			_ps_warning "switcher ${sw} is already setted"
			if ${_ps_needed}; then
				list=$(sed "/^${sw}:/d" <<< "${list}")
				continue
			fi
		fi
		if [ ! -f "${_ps_switcher_files_path}/${sw#*:}.sw" ]; then
			ghost_sw+=("${sw}")
		fi
	done
	if [ -n "${ghost_sw}" ]; then
		_ps_info "Ghost switchers are going to be setted:"
		for sw in ${ghost_sw[@]}; do
			_ps_message "  \033[1m${sw}\033[0m\n"
		done
		_ps_question_to_continue
	fi

	echo "${list}"
}

_ps_sw_analog_by_group() {
	local sws=(${@})
	tr ' ' '\n' <<< "${_ps_enabled_sw[@]}" | \
		grep -E "^($(tr ' ' '\n' <<< "${sws[@]%:*}" | sort -u | paste -sd '|')):" | \
		grep -Ev "^($(tr ' ' '|' <<< "${sws[@]}")):" || true
}

_ps_nothing_to_do() {
	_ps_message " there is nothing to do\n"
	exit 0
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
	_ps_info "The following switcher points will be ${1}:"
	awk -F ':' '{ if (sw != $1 ":" $2) {sw = $1 ":" $2; print "  \033[1m" sw "\033[0m"}; print "    " $4}' <<< "${2}"
	_ps_message "\n"

	if [ -n "${4}" ]; then
		_ps_info "${3}:"
		_ps_message "${4}\n"
	fi

	_ps_question_to_continue
}

_ps_enable() {
	_ps_selfmode=true

	_ps_commit "Reading switcher files"
	local data_sw
	data_sw=$(_ps_read_switcher_file ${@})

	_ps_commit "Checking switchers status for enabling"
	local sw sw_set=() sw_reset=()
	if ${_ps_enable_set}; then
		sw_set+=(${data_sw})
	fi
	local sws=$(awk -F ':' '!a[$1 ":" $2]++ {print $1 ":" $2}' <<< "${data_sw}")
	for sw in ${sws}; do
		if ! ${_ps_enable_set} && ! [[ " ${sw_set[@]}" =~ " ${sw%%:*}:" ]]; then
			if [ "$(_ps_get_mode_by_setted_sw "${sw%%:*}")" = "auto" ]; then
				_ps_warning "switcher group ${sw%%:*} is on auto mode, resetting needed"
				sw_set+=($(grep "^${sw%%:*}:" <<< "${data_sw}"))
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
			elif ! ${_ps_enable_set} && [[ " ${_ps_setted_sw[@]%:*} " =~ " ${sw} " ]]; then
				_ps_warning "switcher ${sw} requires resetting"
				sw_reset+=($(grep "^${sw}:" <<< "${data_sw}"))
			fi
		fi
	done
	if [ -n "${sw_set}" ]; then
		_ps_commit "Checking switchers status for setting"
		if ${_ps_automode}; then
			for sw in $(awk -F ':' '!a[$1]++ {print $1}' <<< "${sws}"); do
				if [ "$(_ps_get_mode_by_setted_sw "${sw}")" = "manual" ]; then
					_ps_warning "switcher group ${sw} is on manual mode, setting canceled"
					sws=$(sed "/^${sw}:/d" <<< "${sws}")
				fi
			done
			sw_set=($(tr ' ' '\n' <<< "${sw_set[@]}" | grep -E "^($(paste -sd '|' <<< ${sws})):" || true))
		fi
		if [ -n "${sws}" ]; then
			sw_set=($(_ps_needed=true _ps_choose_sw_to_set ${sw_set[@]} $(_ps_sw_analog_by_group ${sws})))
		else
			sw_set=()
		fi
	fi
	sw_set+=(${sw_reset[@]})
	if ${_ps_needed} && [[ -z "${data_sw}" && -z "${sw_set}" ]]; then
		_ps_nothing_to_do
	fi
	if [[ -n "${data_sw}" && -n "${sw_set}" ]]; then
		data_sw="$(tr ' ' '\n' <<< "${sw_set[@]}"; grep -Ev "^($(tr ' ' '|' <<< "${sw_set[@]}"))$" <<< "${data_sw}")"
	fi

	if [ -n "${data_sw}" ]; then
		_ps_commit "Checking switchers for enabling"
		_ps_check_sw "enable" ${data_sw}
	fi

	if [ -n "${sw_set}" ]; then
		_ps_commit "Checking switchers for setting"
		_ps_check_sw "set" ${sw_set[@]}
	fi

	if [ -n "${data_sw}" ]; then
		_ps_commit "Writing points"
		_ps_action_sw_point "enable" ${data_sw}
	fi

	if [ -n "${sw_set}" ]; then
		_ps_commit "Setting points"
		_ps_action_sw_point "set" ${sw_set[@]}
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

	local unset_sw
	if ${_ps_disable_unset} || ${_ps_disable_ghost}; then
		unset_sw=$(_ps_select_setted_sw=true _ps_noerror=true _ps_nomessage=true _ps_get_enabled_switcher ${sws[@]} || true)
		if ! ${_ps_disable_ghost} && [ -z "${unset_sw}" ]; then
			_ps_warning "no switchers found that need unset"
		fi
	fi

	_ps_notify_about_sw_and_get_confirm "removed" "${data_sw}" \
		"The following switchers will be unsetted" \
		"$([ -n "${unset_sw}" ] && awk -F ':' '{ if (sw != $1 ":" $2) {sw = $1 ":" $2; print "  " sw}}' <<< "${unset_sw}" || true)"

	if [ -n "${unset_sw}" ]; then
		_ps_commit "Unsetting points"
		_ps_action_sw_point "unset" ${unset_sw}
	fi

	_ps_commit "Removing points"
	_ps_action_sw_point "disable" ${data_sw}
}

_ps_set() {
	_ps_commit "Getting enabled switchers"
	local data_sw
	if [[ -z "${@}" ]]; then
		data_sw="$(tr ' ' '\n' <<< ${_ps_enabled_sw[@]})"
	else
		data_sw=$(_ps_get_enabled_switcher ${@})
	fi

	_ps_commit "Checking switchers status for $(${_ps_updatemode} && echo "updating" || echo "setting")"
	local sws=() sw_set=() sw
	if ${_ps_updatemode}; then
		sws=($(awk -F ':' '!a[$1 ":" $2]++ {print $1 ":" $2}' <<< "${data_sw}"))
		for sw in ${!sws[@]}; do
			if _ps_check_checksum_switcher "${sws[${sw}]}" || \
			([ ! -f "${_ps_switcher_files_path}/${sws[${sw}]##*:}.sw" ] && _ps_warning "switcher ${sws[${sw}]} is ghost, skip updating"); then
				unset sws[${sw}]
			fi
		done
	else
		sw_set=($(_ps_choose_sw_to_set ${data_sw}))
	fi
	if (${_ps_updatemode} && [[ -z "${sws[@]}" ]]) || (${_ps_needed} && [ -z "${sw_set}" ]); then
		_ps_nothing_to_do
	fi
	if ${_ps_updatemode}; then
		data_sw=$(_ps_read_switcher_file ${sws[@]})
		sw_set=$(_ps_select_setted_sw=true _ps_noerror=true _ps_get_enabled_switcher ${sws[@]})
	fi

	if ${_ps_updatemode} && [ -n "${data_sw}" ]; then
		_ps_commit "Checking switchers for enabling"
		_ps_check_sw "enable" ${data_sw}
	fi

	if [ -n "${sw_set}" ]; then
		_ps_commit "Checking switchers for setting"
		_ps_check_sw "set" ${sw_set[@]}
	fi

	if ${_ps_updatemode} && [ -n "${data_sw}" ]; then
		_ps_commit "Writing points"
		_ps_action_sw_point "enable" ${data_sw}
	fi

	if [ -n "${sw_set}" ]; then
		_ps_commit "Setting points"
		_ps_action_sw_point "set" ${sw_set[@]}
	fi
}

_ps_unset() {
	if ! ${_ps_automode} && ${_ps_unset_disable}; then
		_ps_selfmode=true
	fi

	_ps_commit "Getting setted switchers"
	local data_sw
	data_sw=$(_ps_select_setted_sw=true _ps_get_enabled_switcher ${@})

	_ps_commit "Checking switchers for unsetting"
        _ps_check_sw "unset" ${data_sw}

	local sws sw_set sw
	if ${_ps_unset_replace}; then
		_ps_commit "Searching for alternatives for switchers"
		sws=$(awk -F ':' '!a[$1 ":" $2]++ {print $1 ":" $2}' <<< "${data_sw}")
		sw_set=$(_ps_choose_sw_to_set $(_ps_sw_analog_by_group ${sws}))
		for sw in $(grep -Ev "^$(awk -F ':' '!a[$1]++ {print $1}' <<< "${sw_set}" | paste -sd '|'):" <<< "${sws}"); do
			_ps_warning "could not find alternative to ${sw} switcher"
		done
	fi

	_ps_notify_about_sw_and_get_confirm "unsetted$(${_ps_unset_disable} && echo " and removed" || true)" "${data_sw}" \
		"The following switchers will be setted as an alternative to unsetted switchers" \
		"$(if [ -n "${sw_set}" ]; then
			for sw in $(awk -F ':' '!a[$1 ":" $2]++ {print $1 ":" $2}' <<< "${sw_set}"); do
				echo "  $(grep "^${sw%%:*}:" <<< "${sws}") -> ${sw}"
			done
		fi)"

	_ps_commit "Unsetting points"
	_ps_action_sw_point "unset" ${data_sw}

	if ${_ps_unset_disable}; then
		_ps_commit "Removing points"
		_ps_action_sw_point "disable" ${data_sw}
	fi

	if [ -n "${sw_set}" ]; then
		_ps_commit "Setting alternative points"
		_ps_action_sw_point "set" ${sw_set}
	fi
}

_ps_query() {
	local data_sw
	if [[ -z "${@}" ]]; then
		data_sw="$(tr ' ' '\n' <<< ${_ps_enabled_sw[@]})"
	else
		data_sw=$(_ps_nomessage=true _ps_get_enabled_switcher ${@})
	fi

	if ${_ps_query_global_list}; then
		echo "${data_sw}"
	elif ${_ps_query_list}; then
		awk -F ':' '{print "\033[1m" $1 ":" $2 "\033[0m " $4}' <<< "${data_sw}"
	elif ${_ps_query_info}; then
		awk -F ':' -v prefix="${_ps_prefix}/" -v sw_files_path="${_ps_switcher_files_path}/" '{
			if (sw != $1 ":" $2) {
				if (sw != "")
					print ""
				sw = $1 ":" $2
				print "\033[1mSwitcher\033[0m  : " $2
				print "\033[1mGroup\033[0m     : " $1
				print "\033[1mPriority\033[0m  : " $3
				printf "\033[1mGhost\033[0m     : "
				if (system("test -f " sw_files_path $2 ".sw"))
					print "Yes"
				else
					print "No"
				printf "\033[1mPoints\033[0m    : "
			} else {
				printf "            "
			}
			gsub(prefix, "", $4)
			gsub(prefix, "", $5)
			print $4 " -> " $5
		}
		END {
			print ""
		}' <<< "${data_sw}"
	else
		local sws=($(awk -F ':' '!a[$1 ":" $2]++ {print $1 ":" $2 ":" $3}' <<< "${data_sw}")) sw name
		for sw in $(tr ' ' '\n' <<< ${sws[@]%%:*} | sort -u); do
			echo -e "\033[1m${sw}\033[0m"
			if ! ${_ps_query_groups}; then
				for name in $(awk -F ':' -v RS=' ' -v sw="${sw}" '{if (sw == $1) print $2 ":" $3}' <<< "${sws[@]}"); do
					echo -n "  ${name}"
					if [[ " ${_ps_setted_sw[@]%:*} " =~ " ${sw}:${name%%:*} " ]]; then
						echo -n " [setted:$(_ps_get_mode_by_setted_sw ${sw})]"
					fi
					echo
				done
			fi
		done
	fi
}

_ps_help_main() {
	_ps_message "usage:  pacman-switch <operation> [...]
operations:
    pacman-switch {-h --help}
    pacman-switch {-V --version}
    pacman-switch {-E --enable}  [options] [switcher(s)]
    pacman-switch {-D --disable} [options] [switcher(s)]
    pacman-switch {-S --set}     [options] [switcher(s)]
    pacman-swicth {-U --unset}   [options] [switcher(s)]
    pacman-switch {-Q --query}   [options] [switcher(s)]

use 'pacman-switch <operation> {-h --help}' with an operation for available options\n"
}

_ps_help_enable() {
	_ps_message "usage:  pacman-switch {-E --enable} [options] [switcher(s)]
options:
  -a, --auto
  -s, --set
      --needed
      --noconfirm
      --noghost\n"
}

_ps_help_disable() {
	_ps_message "usage:  pacman-switch {-D --disable} [options] [switcher(s)]
options:
  -g, --ghost
  -u, --unset
      --noconfirm\n"
}

_ps_help_set() {
	_ps_message "usage:  pacman-switch {-S --set} [options] [switcher(s)]
options:
  -a, --auto
  -u, --update
      --needed
      --noconfirm
      --noghost\n"
}

_ps_help_unset() {
	_ps_message "usage:  pacman-switch {-U --unset} [options] [switcher(s)]
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
  -g, --groups
  -i, --info
  -l, --list (-ll)\n"
}

_ps_version_info() {
	_ps_message "version: ${_ps_version}\n"
}

_ps_run_operation() {
	local operation="${1}" arg_switchers=()
	shift 1

	case "${operation}" in
		"enable"|"disable"|"set"|"unset"|"query");;
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
			if ${_ps_onlygroup} && [ "${group}" = "*" ]; then
				_ps_warning "switcher ${switcher} will be ignored (need to specify group)"
			elif ! [[ " ${switchers[@]} " =~ " ${switcher} " ]]; then
				switchers+=("${switcher}")
			fi
			continue
		fi
		_ps_init_error "switcher not found: ${switcher}"
	done
	if ${_ps_haserror}; then
		exit 1
	fi

	if ! ${_ps_norequire_sw} && ((${#switchers} == 0)); then
		_ps_error "no targets specified"
	fi

	_ps_read_setted_switchers
	_ps_static_setted_sw=(${_ps_setted_sw[@]})

	_ps_${operation} "${switchers[@]}"
}

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
		-{s,-set}:1:enable_set \
		-{a,-auto}:1:automode,enable_set \
		-{h,-help}:1:helpmode \
		--needed:1:needed \
		--noconfirm:1:noconfirm \
		--noghost:1:noghost
	;;
	-D|--disable)
	_ps_conflicting_args="disable_ghost:ghost disable_unset:unset"
	_ps_run_operation disable \
		-{g,-ghost}:1:disable_ghost,norequire_sw \
		-{u,-unset}:1:disable_unset,onlygroup \
		-{h,-help}:1:helpmode \
		--noconfirm:1:noconfirm
	;;
	-S|--set)
	_ps_conflicting_args="automode:auto updatemode:update"
	_ps_run_operation set \
		-{a,-auto}:1:automode,onlygroup \
		-{u,-update}:1:updatemode,norequire_sw \
		-{h,-help}:1:helpmode \
		--needed:1:needed \
		--noconfirm:1:noconfirm \
		--noghost:1:noghost
	;;
	-U|--unset)
	_ps_run_operation unset \
		-{r,-replace}:1:unset_replace \
		-{d,-disable}:1:unset_disable \
		-{a,-auto}:1:automode,unset_replace,unset_disable \
		-{h,-help}:1:helpmode \
		--noconfirm:1:noconfirm \
		--noghost:1:noghost
	;;
	-Q|--query)
	_ps_norequire_sw=true
	_ps_conflicting_args="query_groups:groups query_info:info query_list:list"
	_ps_run_operation query \
		-{h,-help}:1:helpmode \
		-{g,-groups}:1:query_groups \
		-{i,-info}:1:query_info \
		-{l,-list}:2:query_list,query_global_list \
		-{l,-list}:1:query_list
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
