#!/bin/zsh
#
#  rename-to-rescriva.sh
#
#  Renames the app from Folio to Rescriva in the current checkout: file and folder names, type
#  names, on-screen text, build settings and docs. Internal identifiers become reverse-DNS under
#  rescriva.com ("folio.capture.session" → "com.rescriva.capture.session"). Running it twice
#  changes nothing the second time.
#
#  Run it on a branch cut before the rename, before merging main into it, so the merge doesn't
#  conflict on every renamed line. Then build: Xcode picks the renamed files up from the project.
#
#  Left alone: lines marked rename:keep (names already written into people's files) and the git
#  branch names `folio`, `folio-rebuild-quality`, `folio-diagram-editor` and `folio-diagram-ir`
#  when written in backticks, since those branches keep their names.
#

set -euo pipefail
cd "$(git rev-parse --show-toplevel)"
script="Tools/rename-to-rescriva.sh"

# File and folder names. Reverse order moves a folder's contents before the folder itself.
find . -path ./.git -prune -o -name '*Folio*' -print | sort -r | while IFS= read -r old; do
	new="${old:h}/${${old:t}//Folio/Rescriva}"
	if git ls-files --error-unmatch -- "$old" >/dev/null 2>&1; then
		git mv -- "$old" "$new"
	else
		mv -- "$old" "$new"
	fi
	print "renamed ${old#./} → ${new#./}"
done

# Contents of every tracked or untracked (not ignored) text file.
rules='
next if /rename:keep/;
my @kept;
s{`(folio(?:-rebuild-quality|-diagram-editor|-diagram-ir)?)`}{push @kept, $1; "`\x00" . $#kept . "\x00`"}ge;
s/"folio\./"com.rescriva./g;
s/"Folio\.(?=[A-Z])/"com.rescriva./g;
s/FOLIO/RESCRIVA/g;
s/Folio/Rescriva/g;
s/(?<![A-Za-z])folio/rescriva/g;
s/\x00(\d+)\x00/$kept[$1]/g;
'
changed=0
git ls-files -z -co --exclude-standard | while IFS= read -r -d '' file; do
	[[ $file == $script || ! -f $file ]] && continue
	grep -qIi folio -- "$file" || continue
	before=$(shasum < "$file")
	perl -pi -e "$rules" -- "$file"
	[[ $(shasum < "$file") == $before ]] || (( changed += 1 ))
done
print "updated $changed files"
