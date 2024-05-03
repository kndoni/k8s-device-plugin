#!/usr/bin/env bash

# Copyright (c) 2024, NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -o pipefail

this=`basename $0`

usage () {
cat << EOF
Usage: $this [-h] [-a] RELEASE_VERSION

Options:
  --previous-version    specify the previous version (default: latest tag)      
  --help/-h             show this help and exit

Example:

  $this v0.15.0

EOF
}

validate_semver() {
    local version=$1
    local semver_regex="^v([0-9]+)\.([0-9]+)\.([0-9]+)(-([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*))?$"

    if [[ $version =~ $semver_regex ]]; then
        major=${BASH_REMATCH[1]}
        minor=${BASH_REMATCH[2]}
        patch=${BASH_REMATCH[3]}

        # Check if major, minor, and patch are numeric
        if ! [[ $major =~ ^[0-9]+$ ]] || ! [[ $minor =~ ^[0-9]+$ ]] || ! [[ $patch =~ ^[0-9]+$ ]]; then
            echo "Invalid SemVer format: $version"
            return 1
        fi

        # Validate prerelease if present
        if [[ ! -z "${BASH_REMATCH[5]}" ]]; then
            prerelease=${BASH_REMATCH[5]}
            prerelease_regex="^([0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)$"
            if ! [[ $prerelease =~ $prerelease_regex ]]; then
                echo "Invalid SemVer format: $version"
                return 1
            fi
        fi

        echo "Valid SemVer format: $version"
        return 0
    else
        echo "Invalid SemVer format: $version"
        return 1
    fi
}

#
# Parse command line
#
no_patching=
previous_version=$(git describe --tags $(git rev-list --tags --max-count=1))
# Parse command line options
while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        --previous-version)
            previous_version="$2"
            shift 2
            ;;
        --help/-h)  usage
            exit 0
            ;;
        *) break
            ;;
    esac
done

# Check that no extra args were provided
if [ $# -ne 1 ]; then
    if [ $# -lt 1 ]; then
        echo -e "ERROR: too few arguments\n"
    else
        echo -e "ERROR: unknown arguments: ${@:3}\n"
    fi
    usage
    exit 1
fi

release=$1
shift 1

container_image=nvcr.io/nvidia/k8s-device-plugin:$release

#
# Check/parse release number
#
if [ -z "$release" ]; then
    echo -e "ERROR: missing RELEASE_VERSION\n"
    usage
    exit 1
fi

# validate the release version
if ! validate_semver $release; then
    echo -e "ERROR: invalid RELEASE_VERSION\n"
    exit 1
fi
semver=${release:1}

# validate the previous version
if ! validate_semver $previous_version; then
    echo -e "ERROR: invalid PREVIOUS_VERSION\n"
    exit 1
fi
pre_semver=${previous_version:1}

#
# Modify files in the repo to point to new release
#
# Darwin or Linux
DOCKER="docker"
if [[ "$(uname)" == "Darwin" ]]; then
    SED="$DOCKER run -i --rm -v $(PWD):$(PWD) -w $(PWD) alpine:latest sed"
else
    SED="sed"
fi

# Patch versions.mk
echo Patching versions.mk to refer to $release
$SED -i "s/^VERSION.*$/VERSION ?= $release/" versions.mk

# Patch deployments/static
echo Patching deployments to refer to $semver
find deployments/static -type f \( -name "*.yaml" -o -name "*.yml" -o -name "*.template" \) -type f ! -name "nfd.yaml" \
    -exec $SED -E -i \
    -e s",^([[:space:]]+)app.kubernetes.io\/version:.+$,\1app.kubernetes.io\/version: $semver," \
    -e s",^([[:space:]]+)- image:.+$,\1- image: $container_image," \
    {} +

# Patch deployments/helm/Chart.yaml
echo Patching deployments/helm/Chart.yaml to refer to $semver
$SED -i "s/^version: .*/version: \"$semver\"/" deployments/helm/nvidia-device-plugin/Chart.yaml
$SED -i "s/^appVersion: .*/appVersion: \"$semver\"/" deployments/helm/nvidia-device-plugin/Chart.yaml

# Patch README.md
echo Patching README.md to refer to $release
$SED -E -i -e "s/([^[:space:]])$previous_version([^[:alnum:]]|$)/\1$release\2/g" README.md
$SED -E -i -e "s/$pre_semver/$semver/g" README.md
