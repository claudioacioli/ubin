#!/bin/bash
# rm-rf.sh - flatu System Installer
# chmod +x rm-rf.sh && ./rm-rf.sh

set -e

RMRF_DIR="$HOME/.rm-rf"

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " FLATULENCE-IN-FLOUR. Vanilla."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

echo "[Criando estrutura...]"
mkdir -p "$RMRF_DIR"/{.trash,.blobs,meta}

# ============================================================
# 1. Configuração
# ============================================================
cat > "$RMRF_DIR/.rmrfrc" << 'EOF'
# === GitHub Backup ===
GITHUB_SYNC=false
GITHUB_REPO=""

# === Limites ===
SIZE_LIMIT_MB=20
TRASH_DAYS=30
BLOBS_DAYS=180

# === Criptografia ===
CRYPTO_ENABLED=true
EOF

# ============================================================
# 2. Core system
# ============================================================
cat > "$RMRF_DIR/flatu.sh" << 'EOF'
#!/bin/bash

RMRF_DIR="$HOME/.rm-rf"
RMRF_RC="$RMRF_DIR/.rmrfrc"
META_DIR="$RMRF_DIR/meta"

[[ -f "$RMRF_RC" ]] && source "$RMRF_RC"

today=$(date +%Y%m%d)
deleted_log="$META_DIR/deleted-$today.log"

mkdir -p "$META_DIR"
touch "$deleted_log"

_flatu_sync() {
    [[ "$GITHUB_SYNC" != "true" ]] && return 0
    cd "$RMRF_DIR/.trash" 2>/dev/null || return 0
    [[ ! -d .git ]] && return 0
    git add "$today/" 2>/dev/null
    if ! git diff --cached --quiet 2>/dev/null; then
        git commit -m "🗑️ $today $(date +%H:%M:%S)" --quiet
        (git push origin main --quiet &) 2>/dev/null
    fi
}

rm() {
    mkdir -p "$RMRF_DIR"/{.trash,.blobs}

    local path
    for path in "$@"; do
        [[ "$path" == -* ]] && continue
        [[ ! -e "$path" ]] && continue

        local fullpath
        fullpath=$(realpath "$path") || continue

        echo "🗑️  $fullpath"
        echo "$(date '+%F %T') | DELETE | $fullpath" >> "$deleted_log"

        local chave
        chave=$(echo -n "$fullpath" | sha256sum | cut -d' ' -f1)

        tmptar=$(mktemp /tmp/flatu_content.XXXXXX.tar)
        tmpgpg=$(mktemp /tmp/flatu_content.XXXXXX.tar.gpg)
        tmpfinal=$(mktemp /tmp/flatu.XXXXXX.tar)

        trap 'rm -f "$tmptar" "$tmpgpg" "$tmpfinal"' RETURN

        tar -C / -cf "$tmptar" "${fullpath:1}" 2>/dev/null || continue

        gpg --batch --yes --passphrase "$chave" \
            --symmetric --cipher-algo AES256 \
            -o "$tmpgpg" "$tmptar" 2>/dev/null || continue

        local pathkey
        pathkey=$(echo "$fullpath" | tr '/' ':')

        tar -C /tmp -cf "$tmpfinal" \
            --transform="s|$(basename "$tmpgpg")|$pathkey.tar.gpg|" \
            "$(basename "$tmpgpg")" 2>/dev/null

        bzip2 "$tmpfinal"
        finalbz2="$tmpfinal.bz2"

        local size_mb
        size_mb=$(du -m "$finalbz2" | cut -f1)

        if (( size_mb <= SIZE_LIMIT_MB )); then
            dest="$RMRF_DIR/.trash/$today"
        else
            dest="$RMRF_DIR/.blobs/$today"
        fi

        mkdir -p "$dest"
        mv "$finalbz2" "$dest/$(date +%s).tar.bz2"

        command rm -rf "$path"

        (( size_mb <= SIZE_LIMIT_MB )) && _flatu_sync
    done
}

restore() {
    local file="$1"
    local target="${2:-.}"

    [[ -z "$file" ]] && { echo "Uso: restore <arquivo> [destino]"; return 1; }

    found=$(find "$RMRF_DIR"/{.trash,.blobs} -name "$file" 2>/dev/null | head -1)
    [[ -z "$found" ]] && { echo "❌ Não encontrado"; return 1; }

    tmpdir=$(mktemp -d /tmp/flatu_restore.XXXXXX)
    trap 'rm -rf "$tmpdir"' RETURN

    tar -xjf "$found" -C "$tmpdir"
    gpgfile=$(find "$tmpdir" -name "*.tar.gpg" | head -1)

    pathkey=$(basename "$gpgfile" .tar.gpg)
    fullpath=$(echo "$pathkey" | tr ':' '/')
    chave=$(echo -n "$fullpath" | sha256sum | cut -d' ' -f1)

    tmptar="$tmpdir/content.tar"
    gpg --batch --yes --passphrase "$chave" \
        --decrypt -o "$tmptar" "$gpgfile" || return 1

    tar -xf "$tmptar" -C "$target"
    echo "✅ Restaurado: $fullpath"
}

alias rm-force='command rm'
alias lixeira='ls -lh ~/.rm-rf/.trash/*/ 2>/dev/null | tail -20'
EOF

chmod +x "$RMRF_DIR/flatu.sh"

# ============================================================
# 3. Cleanup + purge log
# ============================================================
cat > "$RMRF_DIR/cleanup.sh" << 'EOF'
#!/bin/bash

RMRF_DIR="$HOME/.rm-rf"
META_DIR="$RMRF_DIR/meta"
today=$(date +%Y%m%d)
purged_log="$META_DIR/purged-$today.log"

source "$RMRF_DIR/.rmrfrc"

mkdir -p "$META_DIR"
touch "$purged_log"

purge() {
    local base="$1"
    local days="$2"

    find "$base" -maxdepth 1 -type d -name "202*" -mtime +"$days" | while read -r dir; do
        echo "$(date '+%F %T') | PURGE | $dir" >> "$purged_log"
        rm -rf "$dir"
    done
}

purge "$RMRF_DIR/.trash" "$TRASH_DAYS"
purge "$RMRF_DIR/.blobs" "$BLOBS_DAYS"
EOF

chmod +x "$RMRF_DIR/cleanup.sh"

# ============================================================
# 4. Bashrc
# ============================================================
if ! grep -q "flatu System" ~/.bashrc; then
cat >> ~/.bashrc << 'EOF'

# flatu System
[[ -f ~/.rm-rf/flatu.sh ]] && source ~/.rm-rf/flatu.sh
EOF
fi

# ============================================================
# 5. Cron
# ============================================================
(crontab -l 2>/dev/null | grep -v "rm-rf/cleanup.sh"; echo "0 2 * * * $RMRF_DIR/cleanup.sh >/dev/null 2>&1") | crontab -

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo " FLATULENCE-IN-FLOUR. Vanilla."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "Logs:"
echo "  meta/deleted-YYYYMMDD.log"
echo "  meta/purged-YYYYMMDD.log"
echo ""
echo ""
