#!/bin/bash
#
# Script to publish a deb file created by make_deb_from_virtualenv.sh
# to our internal deployment repository.
#
# Arguments:
#
#   filename -- The .deb file to publish.
#   release -- The release under which to publish the package
#   component -- The component name for the .deb within the repo
#
# Preconditions:
#
#  1. This script assumes it is being run as a user with ssh access to
#     the debian@deploy.newdream.net account.
#
# Postconditions:
#
#  1. The .deb file is copied to the repositories on the packaging server.
#  2. The repositories are rebuilt with prm.rb.
#

#set -x

# Configurable settings
REPO_ACCOUNT="username"
REPO_HOST="hostname"
REPO_BASE_PATH="/home/${REPO_ACCOUNT}/repository"
REPO_DEST="${REPO_ACCOUNT}@${REPO_HOST}:${REPO_BASE_PATH}"
REPO_ARCHITECTURES="i386,amd64"

_myname="$0"

function usage() {
  echo "Usage: $_myname filename release component"
}

# The file to be publishing, using echo to expand wildcard
# because tox does not do that before invoking us.
package_filename=$(echo $1)

# The release to publish to
release_name="$2"
if [ -z "$release_name" ]
then
    echo "ERROR: Missing required release argument"
    usage
    exit 1
fi

# The component to release under
component_name="$3"
if [ -z "$component_name" ]
then
    echo "ERROR: Missing required component argument"
    usage
    exit 1
fi

# Any errors beyond this point are fatal, so turn on automatic checking.
set -e

# Build command string for running rpm tool on the remote server
prm_cmd="./prm.rb -t deb -p pool -c ${component_name} -r precise -a ${REPO_ARCHITECTURES} --gpg"

# Run prm to make sure the target directories exist
ssh "${REPO_ACCOUNT}@${REPO_HOST}" "cd ${REPO_BASE_PATH} && $prm_cmd"

# Copy the file to the repo(s)
for arch in $(echo $REPO_ARCHITECTURES | sed 's/,/ /g')
do
    dest_dir="${REPO_BASE_PATH}/pool/dists/${release_name}/${component_name}/binary-${arch}/"
    echo "Uploading deb file to $dest_dir"
    rsync -av "$package_filename" "${REPO_ACCOUNT}@${REPO_HOST}:${dest_dir}"
    echo
done

# Run prm again to sign .deb and rebuild repository metadata
ssh "${REPO_ACCOUNT}@${REPO_HOST}" "cd ${REPO_BASE_PATH} && $prm_cmd"
