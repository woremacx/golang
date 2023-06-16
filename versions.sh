#!/usr/bin/env bash
set -Eeuo pipefail

# see https://golang.org/dl/
potentiallySupportedArches=(
	amd64

	# special case (fallback)
	src
)
potentiallySupportedArches="$(jq -sRc <<<"${potentiallySupportedArches[*]}" 'rtrimstr("\n") | split(" ")')"

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
	json='{}'
else
	json="$(< versions.json)"
fi
versions=( "${versions[@]%/}" )

# https://pkg.go.dev/golang.org/x/website/internal/dl
# https://github.com/golang/go/issues/23746
# https://github.com/golang/go/issues/34864
# https://github.com/golang/website/blob/41e922072f17ab2826d9479338314c025602a3a1/internal/dl/server.go#L174-L182 ... (the only way to get "unstable" releases is via "all", so we get to sort through "archive" releases too)
goVersions="$(
	wget -qO- 'https://golang.org/dl/?mode=json&include=all' | jq -c --argjson potentiallySupportedArches "$potentiallySupportedArches" '
		[
			.[]
			| ( .version | ltrimstr("go") ) as $version
			| ( $version | sub("^(?<m>[0-9]+[.][0-9]+).*$"; "\(.m)") ) as $major
			| {
				version: $version,
				major: ( $major + if .stable then "" else "-rc" end ),
				arches: ([
					.files[]
					| select(.kind == "archive" or .kind == "source")
					| (
						if .kind == "source" then
							"src"
						else
							if .os != "linux" then
								.os + "-"
							else "" end
							+ (
								.arch
								| sub("^386$"; "i386")
								| sub("^arm64$"; "arm64v8")
								| sub("^armv(?<v>[0-9]+)l?$"; "arm32v\(.v)")
							)
						end
					) as $bashbrewArch
					| {
						( $bashbrewArch ): (
							{
								sha256: .sha256,
								url: ("https://dl.google.com/go/" + .filename),
								supported: ($potentiallySupportedArches | index($bashbrewArch) != null),
							} + if $bashbrewArch == "src" then {} else {
								env: (
									{ GOOS: .os, GOARCH: .arch }
									+ if .arch == "386" and .os == "linux" then
										# i386 in Debian is non-SSE2, Alpine appears to be similar (but interesting, not FreeBSD?)
										{ GO386: "softfloat" }
									elif .arch == "amd64" and .os == "linux" then
										# https://tip.golang.org/doc/go1.18#amd64
										{ GOAMD64: "v1" }
									elif $bashbrewArch | startswith("arm32v") then
										{ GOARCH: "arm", GOARM: ($bashbrewArch | ltrimstr("arm32v")) }
									else {} end
								),
							} end
						),
					}
				] | add)
			}

			# the published binaries only support glibc, which translates to Debian, so the "correct" binary for v7 is v6 (TODO find some way to reasonably benchmark the compiler on a proper v7 chip and determine whether recompiling for GOARM=7 is worthwhile)
			| if (.arches | has("arm32v7") | not) and (.arches | has("arm32v6")) then
				.arches["arm32v7"] = (.arches["arm32v6"] | .env.GOARM = "7")
			else . end

			| ( $potentiallySupportedArches - (.arches | keys) ) as $missingArches
			| .arches = ([
				.arches, (
					$missingArches[]
					| {
						(.): {
							supported: true,
							env: (
								{
									GOOS: "linux",
									GOARCH: .,
								}
								+ if startswith("arm32v") then
									{ GOARCH: "arm", GOARM: ltrimstr("arm32v") }
								else {} end
							)
						},
					}
				)
			] | add)
		]
	'
)"

for version in "${versions[@]}"; do
	export version

	if \
		! goJson="$(jq <<<"$goVersions" -c '
			[ .[] | select(.major == env.version) ] | sort_by(
				.version
				| split(".")
				| map(
					if test("^[0-9]+$") then
						tonumber
					else . end
				)
			)[-1]
		')" \
		|| ! fullVersion="$(jq <<<"$goJson" -r '.version')" \
		|| [ -z "$fullVersion" ] \
	; then
		echo >&2 "warning: cannot find full version for $version"
		continue
	fi

	echo "$version: $fullVersion"

	doc="$(jq <<<"$goJson" -c '{
		version: .version,
		arches: .arches,
		variants: [
			"lunar"
		],
	}')"

	json="$(jq <<<"$json" -c --argjson doc "$doc" '.[env.version] = $doc')"
done

jq <<<"$json" -S . > versions.json
