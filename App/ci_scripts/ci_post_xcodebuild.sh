#!/bin/sh

# After a successful App Store-signed archive (a build headed to TestFlight):
# 1. write TestFlight "What to Test" notes from the commits since the previous build;
# 2. tag the commit build/<CI_BUILD_NUMBER> on GitHub.
# Adapted from GuessWho's ci_post_xcodebuild.sh. Needs GITHUB_USERNAME and GITHUB_TOKEN
# (Secret) in the Xcode Cloud workflow environment.

set -e

# Build a tokenized push URL for origin from input username and token.
# Handles both HTTPS (https://github.com/owner/repo.git) and SSH
# (git@github.com:owner/repo.git) origins: remove the scheme or "git@" prefix,
# then take everything after the FIRST github.com separator (colon OR slash),
# so the rebuilt URL always has exactly one slash between github.com and the
# owner.
github_authed_url() {
    original_url=$(git remote get-url origin)
    rest_url=${original_url#*://}
    rest_url=${rest_url#git@}
    github_path=${rest_url#github.com[:/]}
    echo "https://${1}:${2}@github.com/${github_path}"
}

if [ "$CI_XCODEBUILD_EXIT_CODE" -ne 0 ]; then
    echo "Build failed"
    exit 0
fi
echo "Build succeeded"

# Only App Store-signed archives (TestFlight builds) get notes and a tag; a plain
# build or test action is skipped, so build/N always means "uploaded to TestFlight".
if [ -z "$CI_APP_STORE_SIGNED_APP_PATH" ] || [ ! -d "$CI_APP_STORE_SIGNED_APP_PATH" ]; then
    echo "Not an App Store-signed archive; skipping notes and tag."
    exit 0
fi

tag="build/$CI_BUILD_NUMBER"

# GITHUB_TOKEN: GitHub -> Settings -> Developer settings -> Personal access tokens ->
# Fine-grained tokens, limited to this repo, Repository permissions -> Contents: Read and write.
remote_url=$(github_authed_url $GITHUB_USERNAME $GITHUB_TOKEN)

# --- Generate TestFlight "What to Test" notes -------------------------
# Xcode Cloud auto-uploads App/TestFlight/WhatToTest.<locale>.txt as the
# tester-facing "What to Test" notes. We generate it here from the commit
# range since the last build, so nothing is committed to the repo; the
# file lives only in this ephemeral clone.

# Xcode Cloud clones shallow and without tags; deepen so the tag range
# and commit history are reachable for git describe / git log. Try the
# configured origin first; fall back to the tokenized URL with an explicit
# refspec. Keep stderr suppressed on the tokenized fetch: git echoes the
# failing URL, which carries the token.
if [ "$(git rev-parse --is-shallow-repository)" = "true" ]; then
    git fetch --deepen 100 2>/dev/null \
        || git fetch --deepen 100 "$remote_url" '+refs/heads/*:refs/remotes/origin/*' 2>/dev/null \
        || true
fi
git fetch "$remote_url" 'refs/tags/*:refs/tags/*' 2>/dev/null || true

# Previous build's tag = lower bound. build/* numbers can skip (failed or
# manual runs), so use the most recent reachable tag, not N-1. A build/* tag
# can already sit ON the commit being built: this script runs once per
# xcodebuild action (we archive iOS and macOS), so a sibling action can tag
# this very commit first, and a rebuild re-runs against a tagged commit.
# Stepping back to HEAD^ skips every tag on HEAD at once.
head_sha=$(git rev-parse HEAD)
prev_tag=$(git describe --tags --match 'build/*' --abbrev=0 HEAD 2>/dev/null || echo "")
if [ -n "$prev_tag" ] && [ "$(git rev-list -n 1 "$prev_tag")" = "$head_sha" ]; then
    prev_tag=$(git describe --tags --match 'build/*' --abbrev=0 'HEAD^' 2>/dev/null || echo "")
fi
if [ -n "$prev_tag" ]; then
    notes=$(git log --no-merges --pretty=format:'- %s' "${prev_tag}..HEAD")
else
    # First build ever: no prior tag. Cap to the last 20 commits.
    notes=$(git log --no-merges -20 --pretty=format:'- %s' HEAD)
fi

if [ -z "$notes" ]; then
    notes="- Maintenance build (no source changes since last build)"
    echo "warning: What-to-Test found no commits; falling back to the placeholder"
fi

notes_dir="$CI_PRIMARY_REPOSITORY_PATH/App/TestFlight"
mkdir -p "$notes_dir"
printf '%s\n' "$notes" > "$notes_dir/WhatToTest.en-US.txt"
echo "Wrote What-to-Test notes (previous tag: ${prev_tag:-none}, shallow: $(git rev-parse --is-shallow-repository))"
# ---------------------------------------------------------------------

# Runs once per xcodebuild action, so the same build can reach here more than
# once. Skip if the tag is already on the remote; never force-push, so an
# existing build/N tag can't be moved to a new commit. $remote_url embeds the
# token and git echoes failing URLs to stderr, so stderr stays suppressed on
# every command that uses it.
if git ls-remote --tags "$remote_url" "refs/tags/$tag" 2>/dev/null | grep -q "refs/tags/$tag"; then
    echo "Tag $tag already exists on remote, skipping."
else
    echo "Tagging $tag"
    git tag -a -m "Build $CI_BUILD_NUMBER" "$tag"
    # Push only the new tag ref, never every local tag.
    if git push "$remote_url" "refs/tags/$tag" 2>/dev/null; then
        echo "Successfully pushed tag to remote repo."
    else
        echo "error: failed to push tag $tag (git output withheld to keep the token out of the build log)"
        exit 1
    fi
fi
