#!/bin/zsh
# Rebases feat/ad-skipping onto Automattic's trunk, builds "Casts AI", installs it
# on the iPhone and pushes the rebased branch to the fork.
#
# Run by launchd (config/Personal/com.donovanmontoya.casts-ai-sync.plist) on Mondays
# and Thursdays. It runs a few times each of those days and does nothing once a run
# has installed the current branch, so a Mac that was asleep or a phone that was
# away gets picked up later the same day.
#
# Work happens in its own detached worktree, so the main checkout is never touched
# except to move its feat/ad-skipping forward when it's clean and was up to date.
#
# Usage: config/Personal/sync-and-deploy.sh [--force]   (--force: build and install even if already done)
set -uo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

branch=feat/ad-skipping
device=${CASTS_AI_DEVICE:-00008160-000A3D4601E00036}   # Donovans iPhone
main_checkout=${CASTS_AI_REPO:-$HOME/Documents/Github/pocket-casts-ios}
state=$HOME/Library/Application\ Support/casts-ai-sync
work=$state/worktree
derived=$HOME/Library/Caches/casts-ai-sync/DerivedData
log=$state/sync.log
force=${1:-}

mkdir -p "$state" "${derived:h}"
exec >>"$log" 2>&1

say() { print -r -- "$(date '+%Y-%m-%d %H:%M:%S') $*"; }
notify() {
  say "$1"
  osascript -e "display notification \"${1//\"/\\\"}\" with title \"Casts AI sync\"" >/dev/null 2>&1 || true
}
fail() { notify "Stopped: $1"; exit 1; }

# One run at a time.
lock=$state/lock
if ! mkdir "$lock" 2>/dev/null; then
  say "Another run is in progress, skipping."
  exit 0
fi
trap 'rmdir "$lock"' EXIT

say "---- run started"
cd "$main_checkout" || fail "main checkout not found at $main_checkout"

git fetch --quiet upstream trunk && git fetch --quiet origin "$branch" || fail "git fetch failed"

old=$(git rev-parse "origin/$branch")
local_sha=$(git rev-parse "$branch")
if [[ $local_sha != $old ]]; then
  fail "local $branch ($local_sha) differs from origin. Push or reset it, then run again."
fi

# Dedicated worktree, detached so it never holds the branch.
if [[ ! -d $work/.git && ! -f $work/.git ]]; then
  git worktree add --detach "$work" "$old" || fail "could not create worktree"
fi
cd "$work" || fail "worktree missing"
git rebase --abort >/dev/null 2>&1
git reset --quiet --hard && git clean -fdq -e build || fail "could not clean worktree"
git checkout --quiet --detach "$old" || fail "checkout failed"

# Gitignored credentials the build needs.
cp "$main_checkout/podcasts/Credentials/LocalApiCredentials.swift" podcasts/Credentials/ 2>/dev/null \
  || make external_contributor >/dev/null || fail "could not set up LocalApiCredentials.swift"

if git merge-base --is-ancestor upstream/trunk HEAD; then
  say "Already on top of upstream trunk ($(git rev-parse --short upstream/trunk))."
else
  behind=$(git rev-list --count HEAD..upstream/trunk)
  say "Rebasing onto upstream trunk ($behind new commits)."
  if ! git rebase upstream/trunk; then
    conflicts=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
    git rebase --abort
    fail "rebase onto trunk hit conflicts in: $conflicts. Nothing was pushed or installed."
  fi
fi
new=$(git rev-parse HEAD)

if [[ $force != --force && -f $state/installed && $(<"$state/installed") == $new ]]; then
  say "$(git rev-parse --short "$new") is already installed. Nothing to do."
  exit 0
fi

if ! xcrun devicectl list devices 2>/dev/null | grep "$device" | grep -q available; then
  # Keep the rebase local for now; a later run today retries.
  say "iPhone not available. Will try again on the next run."
  exit 0
fi

say "Building $(git rev-parse --short "$new")."
key_id=6NCMFJ4H4J
if ! nice -n 10 xcodebuild -project podcasts.xcodeproj -scheme pocketcasts -configuration Debug \
    -destination "id=$device" -derivedDataPath "$derived" \
    -xcconfig config/Personal/Personal.xcconfig \
    -allowProvisioningUpdates \
    -authenticationKeyPath "$HOME/.appstoreconnect/private_keys/AuthKey_$key_id.p8" \
    -authenticationKeyID "$key_id" \
    -authenticationKeyIssuerID bc532328-887d-4ed4-b42e-89dac5904636 \
    -quiet build; then
  fail "build failed for $(git rev-parse --short "$new") (see $log). Nothing was pushed or installed."
fi

if ! xcrun devicectl device install app --device "$device" "$derived/Build/Products/Debug-iphoneos/podcasts.app"; then
  fail "install on the iPhone failed (see $log). Nothing was pushed."
fi
print -r -- "$new" >"$state/installed"

if [[ $new != $old ]]; then
  git push --quiet --force-with-lease="$branch:$old" origin "HEAD:refs/heads/$branch" \
    || fail "installed, but pushing the rebased $branch failed."

  # Move the main checkout's branch too, but only if it's safe.
  cd "$main_checkout"
  if [[ $(git rev-parse "$branch") == $old ]]; then
    if [[ $(git symbolic-ref --quiet --short HEAD) == $branch ]]; then
      if [[ -z $(git status --porcelain --untracked-files=no) ]]; then
        git reset --quiet --keep "$new" && say "Main checkout moved to $(git rev-parse --short "$new")."
      else
        say "Main checkout has uncommitted changes; left $branch at $(git rev-parse --short "$old")."
      fi
    else
      git branch --quiet -f "$branch" "$new"
    fi
  fi
fi

notify "Installed Casts AI $(git -C "$work" log -1 --format='%h %s' "$new" | cut -c1-80)"
