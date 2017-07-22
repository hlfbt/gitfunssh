#!/bin/bash
#
# .gitfuns.sh
#
# Contains helpful shell functions and aliases for git
# Source this script in your shells rc file
#
# Author: Alexander Schulz (alex@nope.bz)


function gitlog {
  local STATS=1
  local AUTHOR_LENGTH=16
  local AUTHOR_FORMAT="%<(${AUTHOR_LENGTH},trunc)%an"
  local MESSAGE_LENGTH=80
  local MESSAGE_FORMAT="%<(${MESSAGE_LENGTH},trunc)%s"

  local from to dots
  [ -n "$1" ] && from="$1" || from="origin/$(_git_getbranch)"
  [ -n "$2" ] && to="$2"   || to=""
  dots=".."

  if grep -q "^.\+\.\..\+$" <<< "$1"; then
    if [ -z "$2" ]; then
      from="$(sed 's/\.\..*//' <<< "$1")"
      to="$(sed 's/.*\.\.//' <<< "$1")"
    fi
  elif [ "x$1" = "xall" ]; then
    from="$(git rev-list --max-parents=0 HEAD)"
  elif grep -q "^-\?[0-9]\+$" <<< "$1"; then
    if [ -z "$2" ]; then
      from="-${1#-}"
      dots=""
    fi
  fi

  if [ $STATS -eq 1 ]; then
    git --no-pager log --color=always --pretty=format:" %x1b[95m%ad%x1b[0m %x1b[33m%h%x1b[0m %x1b[36m${AUTHOR_FORMAT}%x1b[0m  ${MESSAGE_FORMAT}" --shortstat --date=short "${from}${dots}${to}" | perl -0777 -pe 's/\n ([0-9]+ files? changed.+)\n+/   \x1b[2m\1\x1b[0m\n/gm; s/([0-9]+) file(s?) changed/\1 file\2/g; s/([0-9]+) insertions?\(\+\)/\x1b[32m+\1\x1b[39m/g; s/([0-9]+) deletions?\(-\)/\x1b[31m-\1\x1b[39m/g'
  else
    git --no-pager log --color=always --pretty=format:" %x1b[95m%ad%x1b[0m %x1b[33m%h%x1b[0m %x1b[36m${AUTHOR_FORMAT}%x1b[0m  ${MESSAGE_FORMAT}" --date=short "${from}${dots}${to}"
  fi
}

function _git_get_refs {
  git show-ref | sed -n '/^.*refs\/[^\/]\+\// { s/^.*refs\/[^\/]\+\///; p; }'
}

function _git_getbranch {
  git rev-parse --abbrev-ref HEAD
}

function gitmerge {
  [ -d .git ] || { echo "No git repository found"; return 1 2>&1 >/dev/null || exit 1; }

  # Initialize all variables
  local HELPMSG funname delete_old GITMERGE uncommitted_changes curbranch mergebranch unpushed unpushed_count yesno mergeables mergeables_count
  funname="$([ -n "$FUNCNAME" ] && echo "$FUNCNAME" || ( [ "$(basename "$0")" = "sh" ] && echo "gitmerge" || basename "$0"))"
  delete_old=0
  GITMERGE="merge"
  curbranch="$(_git_getbranch)"
  mergebranch="master"
  uncommitted_changes=$(git diff-index --quiet HEAD -- && echo 0 || echo 1)

  read -r -d "" HELPMSG <<HELPMSGEOF
Usage: $funname [-h] [-d] [-r] [<branch>]

Shell options:
    <branch>    An optional branch name which specifies the branch into which the current branch should be merge or rebased. (Default: master)
    -h          Show this help message.
    -d          Delete the current branch after successfully merging or rebasing it.
    -r          User \`git rebase\` instead of \`git merge\`.

HELPMSGEOF

  # Parse parameters
  while [ -n "$1" ]; do
    case "$1" in
      -d) delete_old=1;;
      -r) GITMERGE="rebase";;
      -h) echo "$HELPMSG"; return 0 2>&1 > /dev/null || exit 0;;
      *)  mergebranch="$1";;
    esac
    shift
  done

  # Check for unpushed commits
  unpushed="$(gitlog "origin/${curbranch}" "$curbranch")"
  unpushed_count=$(grep -vc '^$' <<< "$unpushed")
  if [ $unpushed_count -gt 0 ]
  then
    echo "You currently have ${unpushed_count} unpushed commits on the branch ${curbranch}:"
    echo "$unpushed"
    echo
    echo -n "Push commits before ${GITMERGE%?}ing? [Y/n] "
    read yesno
    [[ " $yesno" =~ ^\ [n|N][o|O]?$ ]] || git push > /dev/null
  fi

  # Check if there even are any mergeable commits
  mergeables="$(gitlog "origin/${mergebranch}" "origin/${curbranch}")"
  mergeables_count=$(grep -vc '^$' <<< "$mergeables")
  if [ $mergeables_count -eq 0 ]
  then
    echo "Nothing to $GITMERGE from $curbranch to origin/$mergebranch"
    return 0 2>&1 > /dev/null || exit 0
  fi

  # Stash uncommitted changes
  if [ $uncommitted_changes -eq 1 ]; then
    echo "You currently have uncommited changes:"
    git --no-pager diff --stat
    echo
    echo -e "I've \x1b[1mstashed\x1b[0m these changes for you, and will unstash them again if nothing goes awry!"
    echo -e "You can also unstash them manually with \`\x1b[1mgit stash pop\x1b[0m\` if something goes wrong."
    echo
    git stash > /dev/null
  fi

  # Show mergeable commits and prompt for confirmation
  echo "Commits to be ${GITMERGE}d:"
  echo "$mergeables"
  echo
  echo -n "Really $GITMERGE $curbranch into $mergebranch? [Y/n] "
  read yesno
  if [[ " $yesno" =~ ^\ [n|N][o|O]?$ ]]; then
    echo "Going back to previous working state..."
    [ $uncommitted_changes -eq 1 ] && git stash pop > /dev/null
    return 0 2>&1 > /dev/null || exit 0
  fi

  # Finally, merge everything
  echo "Preparing to $GITMERGE $curbranch into $mergebranch..."
  if git checkout "$mergebranch" > /dev/null && git pull > /dev/null && git $GITMERGE "$curbranch" && git push $([ "x$GITMERGE" = "xrebase" ] && echo '-f') > /dev/null
  then
    echo
    echo -e "\x1b[32mSuccessfully ${GITMERGE}d $curbranch into $mergebranch.\x1b[0m Going back to previous working state..."
    [ $uncommitted_changes -eq 1 ] && git stash pop > /dev/null

    # Change to mergebranch and delete old branch if -d was specified
    if [ $delete_old -eq 1 ]; then
      if git checkout "$mergebranch" > /dev/null && git branch -d "$curbranch" > /dev/null && git push origin -d "$curbranch" > /dev/null; then
        echo -e "\x1b[32mChanged to $mergebranch and deleted branch $curbranch.\x1b[0m"
      else
        echo -e "\x1b[1m\x1b[31mError deleting branch ${curbranch}.\x1b[0m"
      fi
    else
      git checkout "$curbranch" > /dev/null
    fi
  else
    echo
    echo -e "\x1b[1m\x1b[31mError ${GITMERGE%?}ing $curbranch into $mergebranch.\x1b[21m Staying in $mergebranch for manual conflict resolving.\x1b[0m"
    echo -e "\x1b[33mYour working state has been \x1b[1mSTASHED\x1b[21m. Use '\x1b[1mgit stash pop\x1b[21m' to unstash it!\x1b[0m"
  fi
}

function _git_refs_complete {
  local cur

  cur="${COMP_WORDS[COMP_CWORD]}"
  COMPREPLY=( $(_git_get_refs | grep "^$cur" 2>/dev/null) )

  return 0
}

complete -F _git_refs_complete gitlog
complete -F _git_refs_complete gitmerge
