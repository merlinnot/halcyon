function detect_app_package () {
	local source_dir
	expect_args source_dir -- "$@"
	expect_existing "${source_dir}"

	local package_file
	package_file=$(
		find "${source_dir}" -maxdepth 1 -type f -name '*.cabal' |
		match_exactly_one
	) || return 1

	cat "${package_file}"
}


function detect_app_label () {
	local source_dir
	expect_args source_dir -- "$@"

	local app_package
	app_package=$( detect_app_package "${source_dir}" ) || return 1

	local app_name
	app_name=$(
		awk '/^ *[Nn]ame:/ { print $2 }' <<<"${app_package}" |
		tr -d '\r' |
		match_exactly_one
	) || return 1

	local app_version
	app_version=$(
		awk '/^ *[Vv]ersion:/ { print $2 }' <<<"${app_package}" |
		tr -d '\r' |
		match_exactly_one
	) || return 1

	echo "${app_name}-${app_version}"
}


function detect_app_executable () {
	local source_dir
	expect_args source_dir -- "$@"

	local app_executable
	app_executable=$(
		detect_app_package "${source_dir}" |
		awk '/^ *[Ee]xecutable / { print $2 }' |
		tr -d '\r' |
		match_exactly_one
	) || return 1

	echo "${app_executable}"
}


function determine_ghc_version () {
	local constraints
	expect_args constraints -- "$@"

	local ghc_version
	if [ -n "${HALCYON_GHC_VERSION:+_}" ]; then
		ghc_version="${HALCYON_GHC_VERSION}"
	elif [ -n "${constraints}" ]; then
		ghc_version=$( map_constraints_to_ghc_version "${constraints}" ) || die
	else
		ghc_version=$( get_default_ghc_version ) || die
	fi

	echo "${ghc_version}"
}


function determine_ghc_magic_hash () {
	local source_dir
	expect_args source_dir -- "$@"

	local ghc_magic_hash
	if [ -n "${HALCYON_GHC_MAGIC_HASH:+_}" ]; then
		ghc_magic_hash="${HALCYON_GHC_MAGIC_HASH}"
	else
		ghc_magic_hash=$( hash_ghc_magic "${source_dir}" ) || die
	fi

	echo "${ghc_magic_hash}"
}


function determine_cabal_version () {
	local cabal_version
	if [ -n "${HALCYON_CABAL_VERSION:+_}" ]; then
		cabal_version="${HALCYON_CABAL_VERSION}"
	else
		cabal_version=$( get_default_cabal_version ) || die
	fi

	echo "${cabal_version}"
}


function determine_cabal_magic_hash () {
	local source_dir
	expect_args source_dir -- "$@"

	local cabal_magic_hash
	if [ -n "${HALCYON_CABAL_MAGIC_HASH:+_}" ]; then
		cabal_magic_hash="${HALCYON_CABAL_MAGIC_HASH}"
	else
		cabal_magic_hash=$( hash_cabal_magic "${source_dir}" ) || die
	fi

	echo "${cabal_magic_hash}"
}


function determine_cabal_repo () {
	local cabal_repo
	if [ -n "${HALCYON_CABAL_REPO:+_}" ]; then
		cabal_repo="${HALCYON_CABAL_REPO}"
	else
		cabal_repo=$( get_default_cabal_repo ) || die
	fi

	echo "${cabal_repo}"
}


function finish_deploy () {
	expect_vars HOME HALCYON_DIR HALCYON_DEPLOY_ONLY_ENV HALCYON_NO_ANNOUNCE_DEPLOY

	local tag
	expect_args tag -- "$@"

	if ! (( HALCYON_NO_ANNOUNCE_DEPLOY )); then
		if (( HALCYON_DEPLOY_ONLY_ENV )); then
			log_pad 'Environment deployed'
		else
			local description
			description=$( format_app_description "${tag}" ) || die

			log
			log_pad 'App deployed:' "${description}"
		fi
	fi

	# NOTE: Creating config links is necessary to allow the user to easily run Cabal commands,
	# without having to use cabal_do or sandboxed_cabal_do.

	if [ -d "${HALCYON_DIR}/cabal" ]; then
		if [ -e "${HOME}/.cabal/config" ] && ! [ -h "${HOME}/.cabal/config" ]; then
			log_warning "Expected no foreign ${HOME}/.cabal/config"
		else
			rm -f "${HOME}/.cabal/config" || die
			mkdir -p "${HOME}/.cabal" || die
			ln -s "${HALCYON_DIR}/cabal/.halcyon-cabal.config" "${HOME}/.cabal/config" || die
		fi
	fi

	if [ -d "${HALCYON_DIR}/sandbox" ] && [ -d "${HALCYON_DIR}/app" ]; then
		rm -f "${HALCYON_DIR}/app/cabal.sandbox.config" || die
		ln -s "${HALCYON_DIR}/sandbox/.halcyon-sandbox.config" "${HALCYON_DIR}/app/cabal.sandbox.config" || die
	fi
}


function do_deploy_env () {
	local tag source_dir
	expect_args tag source_dir -- "$@"

	if (( HALCYON_RECURSIVE )); then
		if ! validate_ghc_layer "${tag}" >'/dev/null' ||
			! validate_updated_cabal_layer "${tag}" >'/dev/null'
		then
			die 'Cannot use existing environment'
		fi
		return 0
	fi

	install_ghc_layer "${tag}" "${source_dir}" || return 1
	log

	install_cabal_layer "${tag}" "${source_dir}" || return 1
	log
}


function deploy_env () {
	expect_vars HALCYON_RECURSIVE HALCYON_DEPLOY_ONLY_ENV

	local source_dir
	expect_args source_dir -- "$@"

	local ghc_version ghc_magic_hash
	ghc_version=$( determine_ghc_version '' ) || die
	ghc_magic_hash=$( determine_ghc_magic_hash "${source_dir}" ) || die

	local cabal_version cabal_magic_hash cabal_repo
	cabal_version=$( determine_cabal_version ) || die
	cabal_magic_hash=$( determine_cabal_magic_hash "${source_dir}" ) || die
	cabal_repo=$( determine_cabal_repo ) || die

	if ! (( HALCYON_RECURSIVE )); then
		log 'Deploying environment'

		log_indent_pad 'GHC version:' "${ghc_version}"
		[ -n "${ghc_magic_hash}" ] && log_indent_pad 'GHC magic hash:' "${ghc_magic_hash:0:7}"

		log_indent_pad 'Cabal version:' "${cabal_version}"
		[ -n "${cabal_magic_hash}" ] && log_indent_pad 'Cabal magic hash:' "${cabal_magic_hash:0:7}"
		log_indent_pad 'Cabal repository:' "${cabal_repo%%:*}"

		describe_storage || die
		log
	fi

	local tag
	tag=$(
		create_tag '' ''                                                    \
			'' ''                                                       \
			"${ghc_version}" "${ghc_magic_hash}"                        \
			"${cabal_version}" "${cabal_magic_hash}" "${cabal_repo}" '' \
			'' ''
	) || die

	if ! do_deploy_env "${tag}" "${source_dir}"; then
		log_warning 'Cannot deploy environment'
		return 1
	fi

	finish_deploy "${tag}" || die
}


function do_deploy_app_from_slug () {
	local tag
	expect_args tag -- "$@"

	local slug_dir
	slug_dir=$( get_tmp_dir 'halcyon-slug' ) || die

	restore_slug "${tag}" "${slug_dir}" || return 1

	apply_slug "${tag}" "${slug_dir}" || die

	rm -rf "${slug_dir}"
}


function deploy_app_from_slug () {
	expect_vars HALCYON_TARGET \
		HALCYON_FORCE_BUILD_GHC \
		HALCYON_FORCE_BUILD_CABAL HALCYON_FORCE_UPDATE_CABAL \
		HALCYON_FORCE_BUILD_SANDBOX \
		HALCYON_FORCE_BUILD_APP \
		HALCYON_FORCE_BUILD_SLUG

	local app_label source_hash source_dir
	expect_args app_label source_hash source_dir -- "$@"
	expect_existing "${source_dir}"

	if (( HALCYON_FORCE_BUILD_GHC )) ||
		(( HALCYON_FORCE_BUILD_CABAL )) ||
		(( HALCYON_FORCE_UPDATE_CABAL )) ||
		(( HALCYON_FORCE_BUILD_SANDBOX )) ||
		(( HALCYON_FORCE_BUILD_APP )) ||
		(( HALCYON_FORCE_BUILD_SLUG )) ||
		! [ -f "${source_dir}/cabal.config" ]
	then
		return 1
	fi

	log 'Deploying app from slug'

	log_indent_pad 'App label:' "${app_label}"
	[ "${HALCYON_TARGET}" != 'slug' ] && log_indent_pad 'Target:' "${HALCYON_TARGET}"
	log_indent_pad 'Source hash:' "${source_hash:0:7}"

	describe_storage || die
	log

	local tag
	tag=$(
		create_tag "${app_label}" "${HALCYON_TARGET}" \
			"${source_hash}" ''                   \
			'' ''                                 \
			'' '' '' ''                           \
			'' ''                                 \
	) || die

	if ! do_deploy_app_from_slug "${tag}"; then
		log
		return 1
	fi

	if ! (( HALCYON_RECURSIVE )); then
		finish_deploy "${tag}" || die
	fi
}


function prepare_source_dir () {
	local source_dir
	expect_args source_dir -- "$@"
	expect_existing "${source_dir}"

	if [ -n "${HALCYON_CONSTRAINTS_FILE:+_}" ]; then
		copy_file "${HALCYON_CONSTRAINTS_FILE}" "${source_dir}/cabal.config" || die
	fi

	if [ -n "${HALCYON_GHC_PRE_BUILD_HOOK:+_}" ]; then
		copy_file "${HALCYON_GHC_PRE_BUILD_HOOK}" "${source_dir}/.halcyon-magic/ghc-pre-build-hook" || die
	fi
	if [ -n "${HALCYON_GHC_POST_BUILD_HOOK:+_}" ]; then
		copy_file "${HALCYON_GHC_POST_BUILD_HOOK}" "${source_dir}/.halcyon-magic/ghc-post-build-hook" || die
	fi

	if [ -n "${HALCYON_CABAL_PRE_BUILD_HOOK:+_}" ]; then
		copy_file "${HALCYON_CABAL_PRE_BUILD_HOOK}" "${source_dir}/.halcyon-magic/cabal-pre-build-hook" || die
	fi
	if [ -n "${HALCYON_CABAL_POST_BUILD_HOOK:+_}" ]; then
		copy_file "${HALCYON_CABAL_POST_BUILD_HOOK}" "${source_dir}/.halcyon-magic/cabal-post-build-hook" || die
	fi

	if [ -n "${HALCYON_SANDBOX_EXTRA_LIBS:+_}" ]; then
		local -a sandbox_libs
		sandbox_libs=( ${HALCYON_SANDBOX_EXTRA_LIBS} )

		copy_file <( IFS=$'\n' && echo "${sandbox_libs[*]}" ) "${source_dir}/.halcyon-magic/sandbox-extra-libs" || die
	fi
	if [ -n "${HALCYON_SANDBOX_EXTRA_APPS:+_}" ]; then
		local -a sandbox_apps
		sandbox_apps=( ${HALCYON_SANDBOX_EXTRA_APPS} )

		copy_file <( IFS=$'\n' && echo "${sandbox_apps[*]}" ) "${source_dir}/.halcyon-magic/sandbox-extra-apps" || die
	fi
	if [ -n "${HALCYON_SANDBOX_EXTRA_APPS_CONSTRAINTS_DIR:+_}" ]; then
		local sandbox_dir
		sandbox_dir="${source_dir}/.halcyon-magic/sandbox-extra-apps-constraints"

		copy_dir_over "${HALCYON_SANDBOX_EXTRA_APPS_CONSTRAINTS_DIR}" "${sandbox_dir}" || die
	fi
	if [ -n "${HALCYON_SANDBOX_PRE_BUILD_HOOK:+_}" ]; then
		copy_file "${HALCYON_SANDBOX_PRE_BUILD_HOOK}" "${source_dir}/.halcyon-magic/sandbox-pre-build-hook" || die
	fi
	if [ -n "${HALCYON_SANDBOX_POST_BUILD_HOOK:+_}" ]; then
		copy_file "${HALCYON_SANDBOX_POST_BUILD_HOOK}" "${source_dir}/.halcyon-magic/sandbox-post-build-hook" || die
	fi

	if [ -n "${HALCYON_APP_PRE_BUILD_HOOK:+_}" ]; then
		copy_file "${HALCYON_APP_PRE_BUILD_HOOK}" "${source_dir}/.halcyon-magic/app-pre-build-hook" || die
	fi
	if [ -n "${HALCYON_APP_POST_BUILD_HOOK:+_}" ]; then
		copy_file "${HALCYON_APP_POST_BUILD_HOOK}" "${source_dir}/.halcyon-magic/app-post-build-hook" || die
	fi

	if [ -n "${HALCYON_SLUG_EXTRA_APPS:+_}" ]; then
		local -a slug_apps
		slug_apps=( ${HALCYON_SLUG_EXTRA_APPS} )

		copy_file <( IFS=$'\n' && echo "${slug_apps[*]}" ) "${source_dir}/.halcyon-magic/slug-extra-apps" || die
	fi
	if [ -n "${HALCYON_SLUG_EXTRA_APPS_CONSTRAINTS_DIR:+_}" ]; then
		local slug_dir
		slug_dir="${source_dir}/.halcyon-magic/slug-extra-apps-constraints"

		copy_dir_over "${HALCYON_SLUG_EXTRA_APPS_CONSTRAINTS_DIR}" "${slug_dir}" || die
	fi
	if [ -n "${HALCYON_SLUG_PRE_BUILD_HOOK:+_}" ]; then
		copy_file "${HALCYON_SLUG_PRE_BUILD_HOOK}" "${source_dir}/.halcyon-magic/slug-pre-build-hook" || die
	fi
	if [ -n "${HALCYON_SLUG_POST_BUILD_HOOK:+_}" ]; then
		copy_file "${HALCYON_SLUG_POST_BUILD_HOOK}" "${source_dir}/.halcyon-magic/slug-post-build-hook" || die
	fi
}


function do_deploy_app () {
	expect_vars HALCYON_DIR HALCYON_RECURSIVE HALCYON_FORCE_RESTORE_ALL

	local tag source_dir constraints
	expect_args tag source_dir constraints -- "$@"

	local saved_sandbox saved_app slug_dir
	saved_sandbox=
	saved_app=
	slug_dir=$( get_tmp_dir 'halcyon-slug' ) || die

	do_deploy_env "${tag}" "${source_dir}" || return 1

	if (( HALCYON_RECURSIVE )); then
		if [ -d "${HALCYON_DIR}/sandbox" ]; then
			saved_sandbox=$( get_tmp_dir 'halcyon-saved-sandbox' ) || die
			mv "${HALCYON_DIR}/sandbox" "${saved_sandbox}" || die
		fi

		if [ -d "${HALCYON_DIR}/app" ]; then
			saved_app=$( get_tmp_dir 'halcyon-saved-app' ) || die
			mv "${HALCYON_DIR}/app" "${saved_app}" || die
		fi
	else
		rm -rf "${HALCYON_DIR}/sandbox" "${HALCYON_DIR}/app" "${HALCYON_DIR}/slug" || die
	fi

	install_sandbox_layer "${tag}" "${source_dir}" "${constraints}" || return 1
	log

	install_app_layer "${tag}" "${source_dir}" || return 1
	log

	local must_build
	must_build=1
	if (( HALCYON_FORCE_RESTORE_ALL )) &&
		restore_slug "${tag}" "${slug_dir}"
	then
		must_build=0
	fi
	if (( must_build )); then
		if ! build_slug "${tag}" "${source_dir}" "${slug_dir}"; then
			log_warning 'Cannot build slug'
			return 1
		fi
		archive_slug "${slug_dir}" || die
		announce_slug "${tag}" "${slug_dir}" || die
	fi

	if (( HALCYON_RECURSIVE )); then
		if [ -n "${saved_sandbox}" ]; then
			rm -rf "${HALCYON_DIR}/sandbox" || die
			mv "${saved_sandbox}" "${HALCYON_DIR}/sandbox" || die
		fi

		if [ -n "${saved_app}" ]; then
			rm -rf "${HALCYON_DIR}/app" || die
			mv "${saved_app}" "${HALCYON_DIR}/app" || die
		fi
	fi

	apply_slug "${tag}" "${slug_dir}" || die

	rm -rf "${slug_dir}" || die
}


function deploy_app () {
	expect_vars HALCYON_RECURSIVE HALCYON_TARGET HALCYON_FORCE_RESTORE_ALL

	local app_label source_dir
	expect_args app_label source_dir -- "$@"
	expect_existing "${source_dir}"

	# NOTE: This is the first out of the two moments when source_dir is modified.

	prepare_source_dir "${source_dir}" || die

	local source_hash
	if [ -f "${source_dir}/cabal.config" ]; then
		source_hash=$( hash_tree "${source_dir}" ) || die

		if ! (( HALCYON_FORCE_RESTORE_ALL )) &&
			deploy_app_from_slug "${app_label}" "${source_hash}" "${source_dir}"
		then
			return 0
		fi
	fi

	local constraints warn_implicit
	warn_implicit=0
	if ! [ -f "${source_dir}/cabal.config" ]; then
		HALCYON_NO_ANNOUNCE_DEPLOY=1 deploy_env "${source_dir}" || return 1

		log 'Deploying app'

		# NOTE: This is the second out of the two moments when source_dir is modified.

		constraints=$( cabal_freeze_implicit_constraints "${app_label}" "${source_dir}" ) || die
		warn_implicit=1

		format_constraints <<<"${constraints}" >"${source_dir}/cabal.config" || die
		source_hash=$( hash_tree "${source_dir}" ) || die
	else
		log 'Deploying app'

		constraints=$( detect_constraints "${app_label}" "${source_dir}" ) || die
	fi

	local constraints_hash
	constraints_hash=$( hash_constraints "${constraints}" ) || die

	local ghc_version ghc_magic_hash
	ghc_version=$( determine_ghc_version "${constraints}" ) || die
	ghc_magic_hash=$( determine_ghc_magic_hash "${source_dir}" ) || die

	local cabal_version cabal_magic_hash cabal_repo
	cabal_version=$( determine_cabal_version ) || die
	cabal_magic_hash=$( determine_cabal_magic_hash "${source_dir}" ) || die
	cabal_repo=$( determine_cabal_repo ) || die

	local sandbox_magic_hash app_magic_hash
	sandbox_magic_hash=$( hash_sandbox_magic "${source_dir}" ) || die
	app_magic_hash=$( hash_app_magic "${source_dir}" ) || die

	log_indent_pad 'App label:' "${app_label}"
	[ "${HALCYON_TARGET}" != 'slug' ] && log_indent_pad 'Target:' "${HALCYON_TARGET}"
	log_indent_pad 'Source hash:' "${source_hash:0:7}"
	log_indent_pad 'Constraints hash:' "${constraints_hash:0:7}"

	log_indent_pad 'GHC version:' "${ghc_version}"
	[ -n "${ghc_magic_hash}" ] && log_indent_pad 'GHC magic hash:' "${ghc_magic_hash:0:7}"

	log_indent_pad 'Cabal version:' "${cabal_version}"
	[ -n "${cabal_magic_hash}" ] && log_indent_pad 'Cabal magic hash:' "${cabal_magic_hash:0:7}"
	log_indent_pad 'Cabal repository:' "${cabal_repo%%:*}"

	[ -n "${sandbox_magic_hash}" ] && log_indent_pad 'Sandbox magic hash:' "${sandbox_magic_hash:0:7}"
	if [ -f "${source_dir}/.halcyon-magic/sandbox-extra-libs" ]; then
		local -a sandbox_libs
		sandbox_libs=( $( <"${source_dir}/.halcyon-magic/sandbox-extra-libs" ) ) || die

		log_indent_pad 'Sandbox extra libs:' "${sandbox_libs[*]:-}"
	fi
	if [ -f "${source_dir}/.halcyon-magic/sandbox-extra-apps" ]; then
		local -a sandbox_apps
		sandbox_apps=( $( <"${source_dir}/.halcyon-magic/sandbox-extra-apps" ) ) || die

		log_indent_pad 'Sandbox extra apps:' "${sandbox_apps[*]:-}"
	fi

	[ -n "${app_magic_hash}" ] && log_indent_pad 'App magic hash:' "${app_magic_hash:0:7}"

	if [ -f "${source_dir}/.halcyon-magic/slug-extra-apps" ]; then
		local -a slug_apps
		slug_apps=( $( <"${source_dir}/.halcyon-magic/slug-extra-apps" ) ) || die

		log_indent_pad 'Slug extra apps:' "${slug_apps[*]:-}"
	fi

	describe_storage || die

	if (( warn_implicit )); then
		if (( HALCYON_RECURSIVE )); then
			log_error 'Cannot use implicit constraints'
			log_error 'Expected cabal.config with explicit constraints'
			log
			help_add_explicit_constraints "${constraints}"
			die
		fi
		log_warning 'Using implicit constraints'
		log_warning 'Expected cabal.config with explicit constraints'
		log
		help_add_explicit_constraints "${constraints}"
	fi

	local tag
	tag=$(
		create_tag "${app_label}" "${HALCYON_TARGET}"                       \
			"${source_hash}" "${constraints_hash}"                      \
			"${ghc_version}" "${ghc_magic_hash}"                        \
			"${cabal_version}" "${cabal_magic_hash}" "${cabal_repo}" '' \
			"${sandbox_magic_hash}" "${app_magic_hash}" || die
	) || die

	log
	if ! do_deploy_app "${tag}" "${source_dir}" "${constraints}"; then
		log_warning 'Cannot deploy app'
		return 1
	fi

	if ! (( HALCYON_RECURSIVE )); then
		finish_deploy "${tag}" || die
	fi
}


function deploy_local_app () {
	expect_vars HALCYON_NO_COPY_LOCAL_SOURCE

	local local_dir
	expect_args local_dir -- "$@"

	local source_dir
	if ! (( HALCYON_NO_COPY_LOCAL_SOURCE )); then
		source_dir=$( get_tmp_dir 'halcyon-copied-source' ) || die

		copy_app_source_over "${local_dir}" "${source_dir}" || die
	else
		source_dir="${local_dir}"
	fi

	local app_label
	if ! app_label=$( detect_app_label "${source_dir}" ); then
		die 'Cannot detect app label'
	fi

	deploy_app "${app_label}" "${source_dir}" || return 1

	if ! (( HALCYON_NO_COPY_LOCAL_SOURCE )); then
		rm -rf "${source_dir}" || die
	fi
}


function deploy_cloned_app () {
	local url_oid
	expect_args url_oid -- "$@"

	log 'Cloning app'

	local source_dir
	source_dir=$( get_tmp_dir 'halcyon-cloned-source' ) || die

	local url
	url="${url_oid%#*}"
	if ! git clone "${url}" "${source_dir}" |& quote; then
		die 'Cannot clone app'
	fi

	local branch_oid
	branch_oid="${url_oid#*#}"
	if [ "${branch_oid}" = "${url_oid}" ]; then
		branch_oid=
	fi
	if [ -n "${branch_oid}" ]; then
		if ! git -C "${source_dir}" checkout "${branch_oid}" |& quote; then
			die 'Cannot checkout app'
		fi
	fi

	local app_label
	if ! app_label=$( detect_app_label "${source_dir}" ); then
		die 'Cannot detect app label'
	fi

	log
	deploy_app "${app_label}" "${source_dir}" || return 1

	rm -rf "${source_dir}" || die
}


function deploy_unpacked_app () {
	expect_vars HALCYON_RECURSIVE

	local app_oid
	expect_args app_oid -- "$@"

	local work_dir
	work_dir=$( get_tmp_dir 'halcyon-unpacked-source' ) || die

	HALCYON_DEPLOY_ONLY_ENV=1 HALCYON_NO_ANNOUNCE_DEPLOY=1 deploy_env '/dev/null' || return 1

	log 'Unpacking app'

	local app_label
	if ! app_label=$( cabal_unpack_app "${app_oid}" "${work_dir}" ); then
		die 'Cannot unpack app'
	fi

	if [ "${app_label}" != "${app_oid}" ]; then
		if (( HALCYON_RECURSIVE )); then
			log_error "Cannot use implicit version of ${app_oid}"
			die 'Expected app label with explicit version'
		fi
		log_warning "Using implicit version of ${app_oid}"
		log_warning 'Expected app label with explicit version'
	fi

	log
	deploy_app "${app_label}" "${work_dir}/${app_label}" || return 1

	rm -rf "${work_dir}" || die
}


function deploy_app_oid () {
	local app_oid
	expect_args app_oid -- "$@"

	case "${app_oid}" in
	'https://'*);&
	'ssh://'*);&
	'git@'*);&
	'file://'*);&
	'http://'*);&
	'git://'*)
		deploy_cloned_app "${app_oid}" || return 1
		;;
	*)
		if [ -d "${app_oid}" ]; then
			deploy_local_app "${app_oid%/}" || return 1
		else
			deploy_unpacked_app "${app_oid}" || return 1
		fi
	esac
}
