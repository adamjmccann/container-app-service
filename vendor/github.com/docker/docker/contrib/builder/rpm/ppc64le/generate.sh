#!/usr/bin/env bash
set -e

# usage: ./generate.sh [versions]
#    ie: ./generate.sh
#        to update all Dockerfiles in this directory
#    or: ./generate.sh centos-7
#        to only update centos-7/Dockerfile
#    or: ./generate.sh fedora-newversion
#        to create a new folder and a Dockerfile within it

cd "$(dirname "$(readlink -f "$BASH_SOURCE")")"

versions=( "$@" )
if [ ${#versions[@]} -eq 0 ]; then
	versions=( */ )
fi
versions=( "${versions[@]%/}" )

for version in "${versions[@]}"; do
	distro="${version%-*}"
	suite="${version##*-}"
	from="ppc64le/${distro}:${suite}"
	installer=yum

	if [[ "$distro" == "fedora" ]]; then
		installer=dnf
	fi

	mkdir -p "$version"
	echo "$version -> FROM $from"
	cat > "$version/Dockerfile" <<-EOF
		#
		# THIS FILE IS AUTOGENERATED; SEE "contrib/builder/rpm/ppc64le/generate.sh"!
		#

		FROM $from
	EOF

	echo >> "$version/Dockerfile"

	extraBuildTags=
	runcBuildTags=

	case "$from" in
		ppc64le/fedora:*)
			echo "RUN ${installer} -y upgrade" >> "$version/Dockerfile"
			;;
		*) ;;
	esac

	case "$from" in
		ppc64le/centos:*)
			# get "Development Tools" packages dependencies
			echo 'RUN yum groupinstall -y "Development Tools"' >> "$version/Dockerfile"

			if [[ "$version" == "centos-7" ]]; then
				echo 'RUN yum -y swap -- remove systemd-container systemd-container-libs -- install systemd systemd-libs' >> "$version/Dockerfile"
			fi
			;;
		ppc64le/opensuse:*)
			# Add the ppc64le repo (hopefully the image is updated soon)
			# get rpm-build and curl packages and dependencies
			echo "RUN zypper addrepo -n ppc64le-oss -f https://download.opensuse.org/ports/ppc/distribution/leap/${suite}/repo/oss/ ppc64le-oss"  >> "$version/Dockerfile"
			echo "RUN zypper addrepo -n ppc64le-updates -f https://download.opensuse.org/ports/update/${suite}/ ppc64le-updates" >> "$version/Dockerfile"
			echo 'RUN zypper --non-interactive install ca-certificates* curl gzip rpm-build' >> "$version/Dockerfile"
			;;
		*)
			echo "RUN ${installer} install -y @development-tools fedora-packager" >> "$version/Dockerfile"
			;;
	esac

	packages=(
		btrfs-progs-devel # for "btrfs/ioctl.h" (and "version.h" if possible)
		device-mapper-devel # for "libdevmapper.h"
		glibc-static
		libseccomp-devel # for "seccomp.h" & "libseccomp.so"
		libselinux-devel # for "libselinux.so"
		pkgconfig # for the pkg-config command
		selinux-policy
		selinux-policy-devel
		sqlite-devel # for "sqlite3.h"
		systemd-devel # for "sd-journal.h" and libraries
		tar # older versions of dev-tools do not have tar
		git # required for containerd and runc clone
		cmake # tini build
		vim-common # tini build
	)

	# opensuse does not have the right libseccomp libs
	case "$from" in
		ppc64le/opensuse:*)
			packages=( "${packages[@]/libseccomp-devel}" )
			runcBuildTags="selinux"
			;;
		*)
			extraBuildTags+=' seccomp'
			runcBuildTags="seccomp selinux"
			;;
	esac

	case "$from" in
		ppc64le/opensuse:*)
			packages=( "${packages[@]/btrfs-progs-devel/libbtrfs-devel}" )
			packages=( "${packages[@]/pkgconfig/pkg-config}" )
			packages=( "${packages[@]/vim-common/vim}" )
			if [[ "$from" == "ppc64le/opensuse:13."* ]]; then
				packages+=( systemd-rpm-macros )
			fi

			# use zypper
			echo "RUN zypper --non-interactive install ${packages[*]}" >> "$version/Dockerfile"
			;;
		*)
			echo "RUN ${installer} install -y ${packages[*]}" >> "$version/Dockerfile"
			;;
	esac

	echo >> "$version/Dockerfile"


	awk '$1 == "ENV" && $2 == "GO_VERSION" { print; exit }' ../../../../Dockerfile.ppc64le >> "$version/Dockerfile"
	echo 'RUN curl -fsSL "https://golang.org/dl/go${GO_VERSION}.linux-ppc64le.tar.gz" | tar xzC /usr/local' >> "$version/Dockerfile"
	echo 'ENV PATH $PATH:/usr/local/go/bin' >> "$version/Dockerfile"

	echo >> "$version/Dockerfile"

	echo 'ENV AUTO_GOPATH 1' >> "$version/Dockerfile"

	echo >> "$version/Dockerfile"

	# print build tags in alphabetical order
	buildTags=$( echo "selinux $extraBuildTags" | xargs -n1 | sort -n | tr '\n' ' ' | sed -e 's/[[:space:]]*$//' )

	echo "ENV DOCKER_BUILDTAGS $buildTags" >> "$version/Dockerfile"
	echo "ENV RUNC_BUILDTAGS $runcBuildTags" >> "$version/Dockerfile"
	echo >> "$version/Dockerfile"

done
