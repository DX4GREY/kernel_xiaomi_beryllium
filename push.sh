#!/usr/bin/env bash
set -e

REMOTE_BRANCH="main"
DUMMY_REF="batch_chunk"
COMMITS=$(git rev-list --first-parent --reverse $REMOTE_BRANCH)
TOTAL=$(echo "$COMMITS" | wc -l)
STEP=15000
COUNT=0

echo "Total checkpoints: $TOTAL commits"

for HASH in $COMMITS; do
    COUNT=$((COUNT + 1))
    if [ $((COUNT % STEP)) -eq 0 ]; then
        echo "Pushing batch $COUNT of $TOTAL ($HASH)..."
        # Force push ke dummy branch agar tidak kena tolak fast-forward
        git push -f origin "$HASH:refs/heads/$DUMMY_REF"
    fi
done

# Push branch main asli (force push untuk menimpa commit lama yang nyangkut di remote)
echo "Pushing final branch $REMOTE_BRANCH..."
git push -f -u origin "$REMOTE_BRANCH"

# Hapus branch dummy di remote
echo "Cleaning up temporary remote branch..."
git push origin --delete "$DUMMY_REF"

echo "Selesai! Repo kernel berhasil terdorong penuh."
