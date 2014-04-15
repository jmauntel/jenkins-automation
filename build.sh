#!/bin/bash

source /etc/profile.d/rvm.sh

NORMAL='\033[0m'
RED='\033[1;31m'
GREEN='\033[1;32m'

printMsg () {
  printf "${GREEN}%s %s\n${NORMAL}" "$(date '+[%Y%m%d-%H:%M:%S]' | awk '{printf "%s", $1}')" "$@"
}

die () { 
  printf "\n${RED}%s\n\n${NORMAL}" "$@"
  printf "\n${RED}%s\n\n${NORMAL}" "Complete process listing"
  ps aux
  exit 1
}

printMsg "--- Kill VirtualBox zombie processes ---"
vBoxPids=$(pgrep VBox)
[[ -n $vBoxPids ]] && {
  for lamePid in $vBoxPids ; do
    printMsg "Found lame VirtualBox process: $lamePid, killing it"
    kill -9 $lamePid || die "Failed to kill VirtualBox zombie process: $lamePid"
  done
}

printMsg "--- Switching to the working directory ---"
cd $WORKSPACE/$JOB_NAME || die "could not go to $WORKSPACE/$JOB_NAME"

printMsg "--- Verifying upstream opscode cookbook repo is not referenced ---"
grep -q 'site :opscode' $WORKSPACE/$JOB_NAME/Berksfile && {
  die "upstream opscode reference is not permitted"
}

printMsg "--- Verifying that all metadata.rb files explicitly declare their version requirements for required cookbooks ---"
grep 'depends' $WORKSPACE/$JOB_NAME/metadata.rb | grep -v '=' && {
  die "failed to find explicit version requirements for required cookbooks"
}

printMsg "--- Verifying README.md file includes correct Jenkins URLs ---"
grep -q "https://jenkins.acme.com/jenkins/buildStatus/icon?job=$JOB_NAME" $WORKSPACE/$JOB_NAME/README.md || {
  die "README.md has incorrect or missing Jenkins URL"
}
grep -q "https://jenkins.acme.com/jenkins/job/$JOB_NAME" $WORKSPACE/$JOB_NAME/README.md || {
  die "README.md has incorrect or missing Jenkins URL"
}

printMsg "--- Purge berkshelf cookbook cache ---"
rm -rf /home/jenkins/.berkshelf/cookbooks/* || {
  die "Failed to remove the berkshelf cookbook cache"
}

printMsg "--- Using ruby version \"$(ruby --version | awk '{print $2}')\" ---"
printMsg "--- Gemset list $(rvm gemset list) ---"
printMsg "--- Removing cookbook gemset $(rvm gemset name) ---"
rvm gemset delete $JOB_NAME --force
cd ..
cd -
printMsg "--- Using gemset \"$(rvm gemset name)\" ---"

printMsg "--- Install required Gems ---"
bundle install || die "unable to install required gems"

printMsg "--- Build berkshelf cookbook cache, check for opscode connections ---"
berks | egrep '^Installing .* from site:.*opscode' && {
  die "One or more of the cookbooks were pulled from the Internet, this is bad"
}

printMsg "--- Show cookbook versions in use by Berkshelf ---"
berks || {
  die "Failed to execute berks"
}

printMsg "--- List current gems ---"
gem list || die "failed to list installed gems"

printMsg "--- Verifying core files do not have leading tabs in $(pwd) ---"
TAB_FILES=$(find . -type f  -name '*.rb' | egrep -v '.git')
for targetFile in $TAB_FILES ; do 
  printMsg "   --- Checking $targetFile for leading tabs ---"
  grep -P '^\t' $targetFile && die "found leading tab in $targetFile"
done

printMsg "--- Linting cookbook with foodcritic ---"
foodcritic -f any . || die "foodcritic linting failed"

printMsg "--- Purging old VirtualBox instances ---"
for virtualMachine in $(vboxmanage list vms | awk '{print $2}' | sed -r s'/[{}]+//g') ; do 
  printMsg "   --- Removing instance $virtualMachine ---"
  vboxmanage unregistervm --delete $virtualMachine
done || die "could not destroy all of the VirtualBox instances"

printMsg "--- Cleanup kitchen environment ---"
kitchen destroy all || die "could not destroy the kitchen instances"

printMsg "--- Execute kitchen tests ---"
kitchen test -d always || die "The kitchen test failed. Look at the results above"

printMsg "--- Get version number from metadata ---"
TAG_VERSION=$(grep version metadata.rb|egrep -o '[0-9]+\.[0-9]+\.[0-9]+')

if [[ -z $TAG_VERSION ]] ; then 
  die "The tag version variable is empty"
fi

printMsg "--- Testing if the tag exists ---"
git tag -l | egrep -q "^${TAG_VERSION}$" || {
  printMsg "  --- Creating tag ${TAG_VERSION}, committing, uploading code to Chef server ---"
  git tag $TAG_VERSION || die "Tagging version failed"
  git push origin $TAG_VERSION || die "Could not tag this build"
  berks upload || die "Failed to upload cookbooks to Chef server"
}
