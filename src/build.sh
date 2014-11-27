create_build_tag () {
	local prefix label source_hash constraints_hash magic_hash \
		ghc_version ghc_magic_hash \
		sandbox_magic_hash
	expect_args prefix label source_hash constraints_hash magic_hash \
		ghc_version ghc_magic_hash \
		sandbox_magic_hash -- "$@"

	create_tag "${prefix}" "${label}" "${source_hash}" "${constraints_hash}" "${magic_hash}" \
		"${ghc_version}" "${ghc_magic_hash}" \
		'' '' '' ''  \
		"${sandbox_magic_hash}" || die
}


detect_build_tag () {
	local tag_file
	expect_args tag_file -- "$@"

	local tag_pattern
	tag_pattern=$( create_build_tag '.*' '.*' '.*' '.*' '.*' '.*' '.*' '.*' ) || die

	local tag
	if ! tag=$( detect_tag "${tag_file}" "${tag_pattern}" ); then
		die 'Cannot detect build tag'
	fi

	echo "${tag}"
}


derive_build_tag () {
	local tag
	expect_args tag -- "$@"

	local prefix label source_hash constraints_hash magic_hash \
		ghc_version ghc_magic_hash \
		sandbox_magic_hash
	prefix=$( get_tag_prefix "${tag}" ) || die
	label=$( get_tag_label "${tag}" ) || die
	source_hash=$( get_tag_source_hash "${tag}" ) || die
	constraints_hash=$( get_tag_constraints_hash "${tag}" ) || die
	magic_hash=$( get_tag_magic_hash "${tag}" ) || die
	ghc_version=$( get_tag_ghc_version "${tag}" ) || die
	ghc_magic_hash=$( get_tag_ghc_magic_hash "${tag}" ) || die
	sandbox_magic_hash=$( get_tag_sandbox_magic_hash "${tag}" ) || die

	create_build_tag "${prefix}" "${label}" "${source_hash}" "${constraints_hash}" "${magic_hash}" \
		"${ghc_version}" "${ghc_magic_hash}" \
		"${sandbox_magic_hash}" || die
}


derive_configured_build_tag_pattern () {
	local tag
	expect_args tag -- "$@"

	local prefix label constraints_hash magic_hash \
		ghc_version ghc_magic_hash \
		sandbox_magic_hash
	prefix=$( get_tag_prefix "${tag}" ) || die
	label=$( get_tag_label "${tag}" ) || die
	constraints_hash=$( get_tag_constraints_hash "${tag}" ) || die
	magic_hash=$( get_tag_magic_hash "${tag}" ) || die
	ghc_version=$( get_tag_ghc_version "${tag}" ) || die
	ghc_magic_hash=$( get_tag_ghc_magic_hash "${tag}" ) || die
	sandbox_magic_hash=$( get_tag_sandbox_magic_hash "${tag}" ) || die

	create_build_tag "${prefix}" "${label//./\.}" '.*' "${constraints_hash}" "${magic_hash}" \
		"${ghc_version//./\.}" "${ghc_magic_hash}" \
		"${sandbox_magic_hash}" || die
}


derive_potential_build_tag_pattern () {
	local tag
	expect_args tag -- "$@"

	local label
	label=$( get_tag_label "${tag}" ) || die

	create_build_tag '.*' "${label}" '.*' '.*' '.*' \
		'.*' '.*' \
		'.*' || die
}


format_build_archive_name () {
	local tag
	expect_args tag -- "$@"

	local label
	label=$( get_tag_label "${tag}" ) || die

	echo "halcyon-app-build-${label}.tar.gz"
}


build_app () {
	expect_vars HALCYON_BASE

	local tag must_copy must_configure source_dir build_dir
	expect_args tag must_copy must_configure source_dir build_dir -- "$@"
	expect_existing "${source_dir}"
	if (( must_copy )); then
		copy_source_dir_over "${source_dir}" "${build_dir}" || die
	else
		expect_existing "${build_dir}/.halcyon-tag"
	fi

	local prefix
	prefix=$( get_tag_prefix "${tag}" ) || die

	if (( must_copy )) || (( must_configure )); then
		log 'Configuring app'

		local -a opts
		if [[ -f "${source_dir}/.halcyon-magic/app-extra-configure-flags" ]]; then
			local -a raw_opts
			raw_opts=( $( <"${source_dir}/.halcyon-magic/app-extra-configure-flags" ) ) || die
			opts=( $( IFS=$'\n' && echo "${raw_opts[*]:-}" | filter_not_matching '^--prefix' ) )
		fi
		opts+=( --prefix="${prefix}" )
		opts+=( --verbose )

		local stdout
		stdout=$( get_tmp_file 'halcyon-cabal-configure-stdout' ) || die

		if ! sandboxed_cabal_do "${build_dir}" configure "${opts[@]}" >"${stdout}" |& quote; then
			die 'Failed to configure app'
		fi

		# NOTE: This helps implement HALCYON_APP_EXTRA_DATA_FILES, which
		# works around unusual Cabal globbing for the data-files
		# package description entry.
		# https://github.com/haskell/cabal/issues/713
		# https://github.com/haskell/cabal/issues/784

		local data_dir
		data_dir=$(
			filter_matching '^Data files installed in: ' <"${stdout}" |
			sed 's/^Data files installed in: //'
		) || die

		echo "${data_dir}" >"${build_dir}/dist/.halcyon-cabal-data-dir"

		rm -f "${stdout}" || die
	fi

	if [[ -f "${source_dir}/.halcyon-magic/app-pre-build-hook" ]]; then
		log 'Executing app pre-build hook'
		if ! (
			HALCYON_INTERNAL_RECURSIVE=1 \
				"${source_dir}/.halcyon-magic/app-pre-build-hook" \
					"${tag}" "${source_dir}" "${build_dir}" |& quote
		); then
			die 'Failed to execute app pre-build hook'
		fi
		log 'App pre-build hook executed'
	fi

	log 'Building app'

	if ! sandboxed_cabal_do "${build_dir}" build |& quote; then
		die 'Failed to build app'
	fi

	local built_size
	built_size=$( get_size "${build_dir}" ) || die

	log "Built app, ${built_size}"

	if [[ -f "${source_dir}/.halcyon-magic/app-post-build-hook" ]]; then
		log 'Executing app post-build hook'
		if ! (
			HALCYON_INTERNAL_RECURSIVE=1 \
				"${source_dir}/.halcyon-magic/app-post-build-hook" \
					"${tag}" "${source_dir}" "${build_dir}" |& quote
		); then
			die 'Failed to execute app post-build hook'
		fi
		log 'App post-build hook executed'
	fi

	if [[ -d "${build_dir}/share/doc" ]]; then
		log_indent_begin 'Removing documentation from app...'

		rm -rf "${build_dir}/share/doc" || die

		local trimmed_size
		trimmed_size=$( get_size "${build_dir}" ) || die
		log_end "done, ${trimmed_size}"
	fi

	log_indent_begin 'Stripping app...'

	strip_tree "${build_dir}" || die

	local stripped_size
	stripped_size=$( get_size "${build_dir}" ) || die
	log_end "done, ${stripped_size}"

	derive_build_tag "${tag}" >"${build_dir}/.halcyon-tag" || die
}


archive_build_dir () {
	expect_vars HALCYON_NO_ARCHIVE

	local build_dir
	expect_args build_dir -- "$@"
	expect_existing "${build_dir}/.halcyon-tag" "${build_dir}/cabal.config"

	if (( HALCYON_NO_ARCHIVE )); then
		return 0
	fi

	local build_tag platform ghc_version archive_name
	build_tag=$( detect_build_tag "${build_dir}/.halcyon-tag" ) || die
	platform=$( get_tag_platform "${build_tag}" ) || die
	ghc_version=$( get_tag_ghc_version "${build_tag}" ) || die
	archive_name=$( format_build_archive_name "${build_tag}" ) || die

	log 'Archiving build'

	create_cached_archive "${build_dir}" "${archive_name}" || die
	upload_cached_file "${platform}/ghc-${ghc_version}" "${archive_name}" || true
}


validate_potential_build_dir () {
	local tag build_dir
	expect_args tag build_dir -- "$@"

	local recognized_pattern
	recognized_pattern=$( derive_potential_build_tag_pattern "${tag}" ) || die
	detect_tag "${build_dir}/.halcyon-tag" "${recognized_pattern}" || return 1
}


validate_configured_build_dir () {
	local tag build_dir
	expect_args tag build_dir -- "$@"

	local configured_pattern
	configured_pattern=$( derive_configured_build_tag_pattern "${tag}" ) || die
	detect_tag "${build_dir}/.halcyon-tag" "${configured_pattern}" || return 1
}


validate_build_dir () {
	local tag build_dir
	expect_args tag build_dir -- "$@"

	local build_tag
	build_tag=$( derive_build_tag "${tag}" ) || die
	detect_tag "${build_dir}/.halcyon-tag" "${build_tag//./\.}" || return 1
}


restore_build_dir () {
	local tag build_dir
	expect_args tag build_dir -- "$@"

	local platform ghc_version archive_name
	platform=$( get_tag_platform "${tag}" ) || die
	ghc_version=$( get_tag_ghc_version "${tag}" ) || die
	archive_name=$( format_build_archive_name "${tag}" ) || die

	log 'Restoring build'

	if ! extract_cached_archive_over "${archive_name}" "${build_dir}" ||
		! validate_potential_build_dir "${tag}" "${build_dir}" >'/dev/null'
	then
		if ! cache_stored_file "${platform}/ghc-${ghc_version}" "${archive_name}" ||
			! extract_cached_archive_over "${archive_name}" "${build_dir}" ||
			! validate_potential_build_dir "${tag}" "${build_dir}" >'/dev/null'
		then
			return 1
		fi
	else
		touch_cached_file "${archive_name}" || die
	fi

	log 'Build restored'
}


prepare_build_dir () {
	local source_dir build_dir
	expect_args source_dir build_dir -- "$@"
	expect_existing "${source_dir}" "${build_dir}/.halcyon-tag"

	local prepare_dir
	prepare_dir=$( get_tmp_dir 'halcyon-prepare' ) || die

	copy_source_dir_over "${source_dir}" "${prepare_dir}" || die

	local all_files
	all_files=$(
		compare_tree "${build_dir}" "${prepare_dir}" |
		filter_not_matching '^. (\.halcyon-tag$|dist/)'
	) || true

	local changed_files
	if ! changed_files=$(
		filter_not_matching '^= ' <<<"${all_files}" |
		match_at_least_one
	); then
		return 0
	fi

	log 'Examining source changes'

	quote <<<"${changed_files}"

	# NOTE: Restoring file modification times of unchanged files is necessary to avoid
	# needless recompilation.

	local file
	filter_matching '^= ' <<<"${all_files}" |
		while read -r file; do
			cp -p "${build_dir}/${file#= }" "${prepare_dir}/${file#= }" || die
		done

	# NOTE: Any build products outside dist will have to be rebuilt.  See alex or happy for
	# an example.

	rm -rf "${prepare_dir}/dist" || die
	mv "${build_dir}/dist" "${prepare_dir}/dist" || die
	mv "${build_dir}/.halcyon-tag" "${prepare_dir}/.halcyon-tag" || die

	rm -rf "${build_dir}" || die
	mv "${prepare_dir}" "${build_dir}" || die

	# NOTE: With build-type: Custom, changing Setup.hs requires manually re-running
	# configure, as Cabal fails to detect the change.
	# https://github.com/mietek/haskell-on-heroku/issues/29

	local must_configure
	must_configure=0
	if filter_matching "^. (.halcyon-magic/app-extra-configure-flags|cabal.config|Setup.hs|.*\.cabal)$" <<<"${changed_files}" |
		match_at_least_one >'/dev/null'
	then
		must_configure=1
	fi

	return "${must_configure}"
}


link_sandbox_config () {
	expect_vars HALCYON_BASE

	local build_dir
	expect_args build_dir -- "$@"
	expect_existing "${build_dir}/.halcyon-tag"

	# NOTE: Copying the sandbox config is necessary to allow the user to easily run Cabal commands,
	# without having to use cabal_do or sandboxed_cabal_do.

	rm -f "${build_dir}/cabal.sandbox.config" || die
	copy_file "${HALCYON_BASE}/sandbox/.halcyon-sandbox.config" \
		"${build_dir}/cabal.sandbox.config" || die
}


install_build_dir () {
	expect_vars HALCYON_NO_BUILD HALCYON_APP_REBUILD HALCYON_APP_RECONFIGURE

	local tag source_dir build_dir
	expect_args tag source_dir build_dir -- "$@"

	if (( HALCYON_NO_BUILD )); then
		log_warning 'Cannot build app'
		return 1
	fi

	if ! (( HALCYON_APP_REBUILD )) && restore_build_dir "${tag}" "${build_dir}"; then
		if ! (( HALCYON_APP_RECONFIGURE )) && validate_build_dir "${tag}" "${build_dir}" >'/dev/null'; then
			link_sandbox_config "${build_dir}" || die
			return 0
		fi

		local must_copy must_configure
		must_copy=0
		must_configure="${HALCYON_APP_RECONFIGURE}"
		if ! prepare_build_dir "${source_dir}" "${build_dir}" ||
			! validate_configured_build_dir "${tag}" "${build_dir}" >'/dev/null'
		then
			must_configure=1
		fi
		build_app "${tag}" "${must_copy}" "${must_configure}" "${source_dir}" "${build_dir}" || die
		archive_build_dir "${build_dir}" || die
		link_sandbox_config "${build_dir}" || die
		return 0
	fi

	local must_copy must_configure
	must_copy=1
	must_configure=1
	build_app "${tag}" "${must_copy}" "${must_configure}" "${source_dir}" "${build_dir}" || die
	archive_build_dir "${build_dir}" || die
	link_sandbox_config "${build_dir}" || die
}