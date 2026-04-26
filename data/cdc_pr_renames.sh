#!/usr/bin/env bash
# Apply trait-layer filename fixes for the NoMoreLabs/Comrades repo.
#
# Run from the root of a cloned Comrades fork:
#
#   git clone git@github.com:<your-fork>/Comrades.git
#   cd Comrades
#   bash /Users/jef/unipeg/data/cdc_pr_renames.sh
#   git checkout -b fix/trait-filename-mismatches
#   git add -A
#   git commit -m "Add trait-layer filename aliases for metadata mismatches"
#   git push -u origin fix/trait-filename-mismatches
#   gh pr create --base main --head fix/trait-filename-mismatches \
#                --title "Add trait-layer filename aliases for metadata mismatches" \
#                --body-file /Users/jef/unipeg/data/cdc_pr_body.md
#
# Strategy: COPY files (not rename) so existing references keep working.
# Each fix adds a new alias that matches the on-chain metadata string.

set -euo pipefail

ROOT="art/call-data-comrades/cdc_trait_layers"

cp_alias() {
    local src="$1"
    local dst="$2"
    if [[ -f "$src" && ! -f "$dst" ]]; then
        cp "$src" "$dst"
        echo "  + $dst"
    elif [[ ! -f "$src" ]]; then
        echo "  ! source missing: $src" >&2
    else
        echo "  · already exists: $dst"
    fi
}

echo "Adding trait-layer aliases ..."

# 02_Eyes — repo file is misspelled "Quadrupel"; metadata says "Quadruple"
cp_alias "$ROOT/02_Eyes/Quadrupel Block Vision.png" \
         "$ROOT/02_Eyes/Quadruple Block Vision.png"

# 08_Type — files have a comma after "Human" that the metadata strings don't have
cp_alias "$ROOT/08_Type/Human, Melanin Level 30.png" \
         "$ROOT/08_Type/Human Melanin Level 30.png"
cp_alias "$ROOT/08_Type/Human, Melanin Level 80.png" \
         "$ROOT/08_Type/Human Melanin Level 80.png"
cp_alias "$ROOT/08_Type/Human, Melanin Level Goth.png" \
         "$ROOT/08_Type/Human Melanin Level Goth.png"

# 08_Type — capitalization: file is "We The People", metadata is "We the people"
cp_alias "$ROOT/08_Type/We The People.png" \
         "$ROOT/08_Type/We the people.png"

# 10_Backgrounds — metadata typo "Pork" missing "y"
cp_alias "$ROOT/10_Backgrounds/Perky Porky Pink.png" \
         "$ROOT/10_Backgrounds/Perky Pork Pink.png"

# 10_Backgrounds — metadata calls it "Giga Green" but file is just "Green"
cp_alias "$ROOT/10_Backgrounds/Green.png" \
         "$ROOT/10_Backgrounds/Giga Green.png"

# 10_Backgrounds — metadata "Block City during Rollback(Chainrunners)" missing space
cp_alias "$ROOT/10_Backgrounds/Block City during Rollback (Chainrunners).png" \
         "$ROOT/10_Backgrounds/Block City during Rollback(Chainrunners).png"

echo
echo "Done. Review with: git status"
