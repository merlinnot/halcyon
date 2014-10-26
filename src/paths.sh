export HALCYON_TOP_DIR
HALCYON_TOP_DIR=$( cd "$( dirname "${BASH_SOURCE[0]}" )/.." && pwd -P )

function set_halcyon_paths () {
	if ! (( ${HALCYON_INTERNAL_PATHS:-0} )); then
		export HALCYON_INTERNAL_PATHS=1

		export HALCYON_DIR="${HALCYON_DIR:-/app/.halcyon}"
		export HALCYON_CACHE_DIR="${HALCYON_CACHE_DIR:-/var/cache/halcyon}"

		export PATH="${HALCYON_DIR}/ghc/bin:${PATH}"
		export PATH="${HALCYON_DIR}/cabal/bin:${PATH}"
		export PATH="${HALCYON_DIR}/sandbox/bin:${PATH}"
		export PATH="${HALCYON_DIR}/app/bin:${PATH}"
		export PATH="${HALCYON_DIR}/slug/bin:${PATH}"
		export PATH="${HALCYON_TOP_DIR}/bin:${PATH}"

		export LIBRARY_PATH="${HALCYON_DIR}/ghc/lib:${LIBRARY_PATH:-}"
		export LD_LIBRARY_PATH="${HALCYON_DIR}/ghc/lib:${LD_LIBRARY_PATH:-}"

		export LANG="${LANG:-en_US.UTF-8}"
	fi
}
