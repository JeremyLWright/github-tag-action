#!/bin/bash

set -o pipefail

# config
default_semvar_bump=${DEFAULT_BUMP:-minor}
with_v=${WITH_V:-false}
release_branches=${RELEASE_BRANCHES:-master,main}
custom_tag=${CUSTOM_TAG}
source=${SOURCE:-.}
dryrun=${DRY_RUN:-false}
initial_version=${INITIAL_VERSION:-0.0.0}
tag_context=${TAG_CONTEXT:-repo}
suffix=${PRERELEASE_SUFFIX:-beta}
verbose=${VERBOSE:-true}
build_number=${GITHUB_RUN_NUMBER:-100}

cd ${GITHUB_WORKSPACE}/${source}

echo "*** CONFIGURATION ***"
echo -e "\tDEFAULT_BUMP: ${default_semvar_bump}"
echo -e "\tWITH_V: ${with_v}"
echo -e "\tRELEASE_BRANCHES: ${release_branches}"
echo -e "\tCUSTOM_TAG: ${custom_tag}"
echo -e "\tSOURCE: ${source}"
echo -e "\tDRY_RUN: ${dryrun}"
echo -e "\tINITIAL_VERSION: ${initial_version}"
echo -e "\tTAG_CONTEXT: ${tag_context}"
echo -e "\tPRERELEASE_SUFFIX: ${suffix}"
echo -e "\tVERBOSE: ${verbose}"
echo -e "\tINITIAL_BUILD_NUMBER: ${INITIAL_BUILD_NUMBER}"
echo -e "\tGITHUB_RUN_NUMBER: ${GITHUB_RUN_NUMBER}"
echo -e "\tBUILD_NUMBER: ${BUILD_NUMBER}"

current_branch=$(git rev-parse --abbrev-ref HEAD)

pre_release="true"
IFS=',' read -ra branch <<< "$release_branches"
for b in "${branch[@]}"; do
    echo "Is $b a match for ${current_branch}"
    if [[ "${current_branch}" =~ $b ]]
    then
        pre_release="false"
    fi
done
echo "pre_release = $pre_release"

# fetch tags
git fetch --tags

# get latest tag that looks like a semver (with or without v)
case "$tag_context" in
    *repo*) 
        tag=$(git for-each-ref --sort=-v:refname --format '%(refname)' | cut -d / -f 3- | grep -E "^v?[0-9]+.[0-9]+.[0-9]+\+[0-9]+$" | head -n1)
		version=$(echo $tag | awk '{split($0,a,"+"); print a[1]; print a[2]}' | head -n1 | sed 's/v//')
		build_number=$(echo $tag | awk '{split($0,a,"+"); print a[1]; print a[2]}' | tail -n1)
        pre_tag=$(git for-each-ref --sort=-v:refname --format '%(refname)' | cut -d / -f 3- | grep -E "^v?[0-9]+.[0-9]+.[0-9]+\+[0-9]+(-$suffix.[0-9]+)?$" | head -n1)
        ;;
    *branch*) 
        tag=$(git tag --list --merged HEAD --sort=-v:refname | grep -E "^v?[0-9]+.[0-9]+.[0-9]+$" | head -n1)
		version=$($tag | awk '{split($0,a,"+"); print a[1]; print a[2]}' | head -n1 | sed 's/v//')
		build_number=$($tag | awk '{split($0,a,"+"); print a[1]; print a[2]}' | tail -n1)
        pre_tag=$(git tag --list --merged HEAD --sort=-v:refname | grep -E "^v?[0-9]+.[0-9]+.[0-9]+(-$suffix.[0-9]+)?$" | head -n1)
        ;;
    * ) echo "Unrecognized context"; exit 1;;
esac

# if there are none, start tags at INITIAL_VERSION which defaults to 0.0.0
if [ -z "$tag" ]
then
    log=$(git log --pretty='%B')
    tag="$initial_version"
    pre_tag="$initial_version"
else
    log=$(git log $tag..HEAD --pretty='%B')
fi

# get current commit hash for tag
tag_commit=$(git rev-list -n 1 $tag)

# get current commit hash
commit=$(git rev-parse HEAD)

if [ "$tag_commit" == "$commit" ]; then
    echo "No new commits since previous tag. Skipping..."
    echo ::set-output name=tag::$tag
    exit 0
fi

# echo log if verbose is wanted
if $verbose
then
  echo $log
fi

echo $build_number
next_build_number=$((build_number + 1))
echo $next_build_number

case "$log" in
    *#major* ) new=$(semver -i major $version)'+'$next_build_number; part="major";;
    *#minor* ) new=$(semver -i minor $version)'+'$next_build_number; part="minor";;
    *#patch* ) new=$(semver -i patch $version)'+'$next_build_number; part="patch";;
    *#none* ) 
        echo "Default bump was set to none. Skipping..."; exit 0;;
    * ) 
        if [ "$default_semvar_bump" == "none" ]; then
            echo "Default bump was set to none. Just bumping build number...";
            new=$version'+'$next_build_number; part=$default_semvar_bump 
        else 
            new=$(semver -i "${default_semvar_bump}" $tag)'+'$next_build_number; part=$default_semvar_bump 
        fi 
        ;;
esac

if $pre_release
then
    # Already a prerelease available, bump it
    if [[ "$pre_tag" == *"$new"* ]]; then
        new=$(semver -i prerelease $pre_tag --preid $suffix); part="pre-$part"
    else
        new="$new-$suffix.1"; part="pre-$part"
    fi
fi

echo $part

# did we get a new tag?
if [ ! -z "$new" ]
then
	# prefix with 'v'
	if $with_v
	then
		new="v$new"
	fi
fi

if [ ! -z $custom_tag ]
then
    new="$custom_tag"
fi

if $pre_release
then
    echo -e "Bumping tag ${pre_tag}. \n\tNew tag ${new}"
else
    echo -e "Bumping tag ${tag}. \n\tNew tag ${new}"
fi

# set outputs
echo ::set-output name=new_tag::$new
echo ::set-output name=part::$part

# use dry run to determine the next tag
if $dryrun
then
    echo ::set-output name=tag::$tag
    exit 0
fi 

echo ::set-output name=tag::$new

# create local git tag
git tag $new

# push new tag ref to github
dt=$(date '+%Y-%m-%dT%H:%M:%SZ')
full_name=$GITHUB_REPOSITORY
git_refs_url=$(jq .repository.git_refs_url $GITHUB_EVENT_PATH | tr -d '"' | sed 's/{\/sha}//g')

echo "$dt: **pushing tag $new to repo $full_name"

git_refs_response=$(
curl -s -X POST $git_refs_url \
-H "Authorization: token $GITHUB_TOKEN" \
-d @- << EOF

{
  "ref": "refs/tags/$new",
  "sha": "$commit"
}
EOF
)

git_ref_posted=$( echo "${git_refs_response}" | jq .ref | tr -d '"' )

echo "::debug::${git_refs_response}"
if [ "${git_ref_posted}" = "refs/tags/${new}" ]; then
  exit 0
else
  echo "::error::Tag was not created properly."
  exit 1
fi
