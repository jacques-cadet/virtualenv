#!/bin/bash
#
# Script to package a virtualenv containing a python application and
# its dependencies into a .deb file for distribution and installation.
#
# Arguments:
#
#   pkg_root -- The path to the virtualenv.
#
# Preconditions:
#
#  1. This script assumes it is being run from the directory
#     containing the checked-out source code for the application (tox
#     normally does this, but you can also run the script by hand
#     under the same conditions).
#
# Postconditions:
#
#  1. The output file is a .deb with the prefix taken from the name of
#     the python app as configured in setup.py.
#
#  2. If a file with a similar name exists in the directory when the
#     script starts, it is removed so a new file can be created.
#
#  3. The .deb is configured to be installed to /opt/$name and the
#     scripts in the bin directory of the virtualenv are modified so
#     the path to the python interpreter is /opt/$name/bin instead of
#     the path to the virtualenv on the build system.
#
#  4. A post install script will run if one exists for the repo we are
#     packaging. The post install script should reside in a folder named
#     as the package we are building inside the tools/packaging/script
#     folder. (e.g. tools/packaging/script/glance/post_install)
#
# Example tox.ini block:
#
# [testenv:packaging]
# commands =
#     {envbindir}/nosetests
#     /path/to/ndn-tools/packaging/make_deb_from_virtualenv.sh {envdir}
#

# Uncomment to see more output from fpm
#VERBOSE="--verbose --debug"
#set -x

# TODO(dhellmann): Add proper argument/option handling.

_myname="$0"

function usage() {
    echo "Usage: $_myname pkg_root [name]"
    echo "   pkg_root -- The root directory to package"
    echo "   name -- The optional name of the package to create."
    echo "           Defaults to python project name."
    echo "From tox, use {envdir}"
}

# The root of the thing we are going to package.
pkg_root="$1"
shift

if [ -z "$pkg_root" ]
then
    echo "ERROR: No package root specified." 1>&2
    usage
    exit 1
fi

if [ ! -d "$pkg_root" ]
then
    echo "ERROR: Package root \"$pkg_root\" not found." 1>&2
    usage
    exit 1
fi

# Normalize the pkg_root path to a full directory name
pkg_root=$(cd "$pkg_root" && pwd)

# Use the python interpreter inside the virtualenv
python="$pkg_root/bin/python"

# The name of the app being packaged
name="$1"
if [ -z "$name" ]
then
    name=$($python setup.py --name)
else
    shift
fi

# The installation prefix (files under $pkg_root are installed to this
# directory).
prefix="/opt/$name"

# The location of the git repository
git_url="$(git remote -v | grep origin | cut -f2 | cut -f1 -d' ' | head -1)"

# Which commit are we packaging?
git_hash=$(git log -1 --pretty=format:%H)

# The version of this package (YYYYMMDD.HHMMSS-hash)
version=$(date +%Y%m%d.%H%M%S)
iteration=$(git log -1 --pretty=format:%h)

# A description to go into the .deb file
description="$($python setup.py --description)

$($python setup.py --long-description)

Commit: $(git log -1 --pretty=oneline)
Branch: $(git branch | grep '^*' | cut -f2 -d' ')
"

# Write a metadata file to be included in the package
cat - >$pkg_root/metadata.txt <<EOF
Name: $name
Version: $version [ $($python setup.py --version) ]
Packaged on: $(date)
Repository: $git_url
Description: $description
EOF

# Clean up any existing output
rm -f ${name}*.deb

# TODO(dhellmann): Build a list of the .deb dependencies
# for system-level packages from a file in the source
# tree (system_requirements.txt?) and pass to fpm with
# the --depends option.

# TODO(dhellmann): Figure out who should own the files after they are
# installed and set --deb-user and --deb-group.

# Function to modify the paths in the virtualenv that refer to its
# location.
function change_virtualenv_paths() {
  typeset old="$1"
  typeset new="$2"
  echo "Updating paths from $old to $new"
  # Console scripts
  sed -i "s|$old|$new|g" $pkg_root/bin/*
  # Configuration files that affect the import path for modules
  sed -i "s|$old|$new|g" $pkg_root/lib/python*/site-packages/*.pth
}

# Fix paths inside the virtualenv to refer to its final destination
# rather than its current location.
full_path="$pkg_root"
change_virtualenv_paths "$full_path" "$prefix"

# On exit, restore the path in the files we just modified so we can
# test and repackage this directory without rebuilding it.
function restore_paths() {
    change_virtualenv_paths "$prefix" "$full_path"
}
trap restore_paths SIGINT SIGTERM EXIT

# Function to check if a post install script exists for the
# repo we are packaging
function get_after_install_arg() {
    local path=$1/$2/post_install
    if [ -f "$path" ]
    then
        echo "--after-install $path"
    fi
}

# Any failed commands below this point should abort the script.x
set -e

# Unpack the source dist for this project inside a directory that will
# be included in the package, so the tests are present on the deployed
# system.
echo "Adding source to ${pkg_root}/test"
test_dir="${pkg_root}/test"
rm -rf ${test_dir}
mkdir -p ${test_dir}

dist_dir=${pkg_root}/../dist
mkdir -p ${dist_dir}

zip_file=${dist_dir}/*.zip
if [ ! -f "$zip_file" ]
then
    # Need to create the source archive, since tox didn't do it for
    # us.
    python setup.py sdist --formats=zip --dist-dir=${dist_dir}
fi
(cd "${pkg_root}/test" && unzip -q ../../dist/*.zip)

# Create the appropriate option string to pass to the fpm call
after_install=$(get_after_install_arg $(dirname $0)/scripts $name)

# Build the new package
echo "Packaging $name version ${version}-${iteration} from $pkg_root to $prefix"
fpm \
    $VERBOSE \
    -s dir \
    -t deb \
    -n "$name" \
    -v "$version" \
    --iteration "$iteration" \
    --license "Copyright $(date +%Y) VanillaStack" \
    --vendor "VanillaStack" \
    --maintainer "$($python setup.py --maintainer)" \
    --url "${git_url}" \
    --deb-field "Vcs-Git: ${git_url}?${git_hash}" \
    --description "$description" \
    --directories "$prefix" \
    --prefix "$prefix" \
    $after_install \
    -C "$pkg_root" \
    $@ \
    bin lib test metadata.txt
