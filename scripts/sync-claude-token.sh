#!/bin/bash
set -euo pipefail

CREDENTIALS_FILE="${HOME}/.claude/.credentials.json"
ONECLI="${HOME}/.local/bin/onecli"
CACHE_FILE="/tmp/claude-token-sync.last"
ALERT_SENT_FILE="/tmp/claude-token-sync.alert-sent"
REFRESH_ATTEMPT_FILE="/tmp/claude-token-sync.last-refresh"
REFRESH_COOLDOWN=900  # 15 minutes between refresh attempts
POLL_INTERVAL=60
VALIDATE_EVERY=5
POLL_COUNT=0
LOG_PREFIX="[claude-token-sync]"

# Otis container shared Claude dir — credentials copied here so Claude Code
# reads the real token directly (no proxy injection needed).
OTIS_CLAUDE_DIR="/opt/homelab/nanoclaw/data/v2-sessions/ag-1777829798973-ekfj9v/.claude-shared"

TELEGRAM_BOT_TOKEN="8444142055:AAFf2IFJ2uxsDTtiTUTMFYG_yP8sdXUfD1U"
TELEGRAM_CHAT_ID="540462263"

log() { echo "$(date -Iseconds) ${LOG_PREFIX} $*"; }

get_token() {
    node -e "const d=require('${CREDENTIALS_FILE}'); process.stdout.write(d.claudeAiOauth.accessToken)"
}

get_expires_at() {
    node -e "const d=require('${CREDENTIALS_FILE}'); process.stdout.write(String(d.claudeAiOauth.expiresAt))"
}

send_telegram() {
    curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
        -d "chat_id=${TELEGRAM_CHAT_ID}" \
        --data-urlencode "text=$1" > /dev/null 2>&1 || true
}

validate_token() {
    curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer $1" \
        -H "anthropic-version: 2023-06-01" \
        "https://api.anthropic.com/v1/models" 2>/dev/null || echo "000"
}

# Call claude.ai OAuth token refresh endpoint to get a new access+refresh token.
# Updates credentials file in-place on success. Rate-limited by REFRESH_COOLDOWN.
try_proactive_refresh() {
    # Cooldown: don't spam the refresh endpoint
    if [ -f "$REFRESH_ATTEMPT_FILE" ]; then
        local last_attempt now_s
        last_attempt=$(cat "$REFRESH_ATTEMPT_FILE")
        now_s=$(date +%s)
        if [ $(( now_s - last_attempt )) -lt "$REFRESH_COOLDOWN" ]; then
            log "Refresh cooldown active (last attempt ${last_attempt}), skipping"
            return 1
        fi
    fi
    date +%s > "$REFRESH_ATTEMPT_FILE"

    local refresh_token
    refresh_token=$(node -e "const d=require('${CREDENTIALS_FILE}'); process.stdout.write(d.claudeAiOauth.refreshToken)" 2>/dev/null) || return 1
    [ -z "$refresh_token" ] && return 1

    # Write response to temp file to avoid shell interpolation of token values
    local resp_file
    resp_file=$(mktemp)
    curl -s -X POST "https://platform.claude.com/v1/oauth/token" \
        -H "Content-Type: application/json" \
        -d "{\"grant_type\":\"refresh_token\",\"refresh_token\":\"${refresh_token}\",\"client_id\":\"9d1c250a-e61b-44d9-88ed-5944d1962f5e\"}" \
        -o "$resp_file" 2>/dev/null

    # Parse and update credentials file in one node call (no shell interpolation of tokens)
    local result
    result=$(node -e "
        const fs = require('fs');
        const resp = JSON.parse(fs.readFileSync('${resp_file}', 'utf8'));
        if (!resp.access_token) {
            process.stderr.write('no access_token: ' + JSON.stringify(resp).slice(0,200) + '\n');
            process.exit(1);
        }
        const creds = JSON.parse(fs.readFileSync('${CREDENTIALS_FILE}', 'utf8'));
        creds.claudeAiOauth.accessToken = resp.access_token;
        if (resp.refresh_token) creds.claudeAiOauth.refreshToken = resp.refresh_token;
        const expiresAt = Date.now() + (resp.expires_in * 1000);
        creds.claudeAiOauth.expiresAt = expiresAt;
        fs.writeFileSync('${CREDENTIALS_FILE}', JSON.stringify(creds, null, 2), {mode: 0o600});
        process.stdout.write(String(resp.expires_in));
    " 2>&1)
    local node_exit=$?
    rm -f "$resp_file"

    if [ $node_exit -ne 0 ]; then
        log "Proactive refresh failed: ${result}"
        return 1
    fi

    log "Proactive refresh OK — new token expires in ${result}s (~$(( result / 3600 ))h)"
    return 0
}

sync_token() {
    if [ ! -f "$CREDENTIALS_FILE" ]; then
        log "ERROR: credentials file not found at ${CREDENTIALS_FILE}"
        return 1
    fi

    local token expires_at
    token=$(get_token)
    expires_at=$(get_expires_at)

    # Proactively refresh if token expires within 2 hours (7200s)
    # Note: date +%s%3N gives nanoseconds on this system; use %s * 1000 instead
    local now_ms expires_in_s
    now_ms=$(( $(date +%s) * 1000 ))
    expires_in_s=$(( (expires_at - now_ms) / 1000 ))
    if [ "$expires_in_s" -lt 7200 ]; then
        log "Token expires in ${expires_in_s}s — attempting proactive refresh"
        if try_proactive_refresh; then
            token=$(get_token)
            expires_at=$(get_expires_at)
        fi
    fi

    if [ -z "$token" ]; then
        log "ERROR: no accessToken in credentials file"
        return 1
    fi

    # Sync if token changed
    local token_changed=0
    if [ ! -f "$CACHE_FILE" ] || [ "$(cat "$CACHE_FILE")" != "$expires_at" ]; then
        token_changed=1
    fi

    if [ "$token_changed" -eq 1 ]; then
        log "Token changed (expiresAt=${expires_at}), syncing to onecli..."
        rm -f "$ALERT_SENT_FILE"

        local secrets_json ids
        secrets_json=$("$ONECLI" secrets list 2>&1)
        ids=$(echo "$secrets_json" | node -e "
            const chunks = [];
            process.stdin.on('data', d => chunks.push(d));
            process.stdin.on('end', () => {
                try {
                    const d = JSON.parse(chunks.join(''));
                    const ids = (d.data || []).filter(s => s.hostPattern === 'api.anthropic.com').map(s => s.id);
                    process.stdout.write(ids.join('\n'));
                } catch(e) { process.stderr.write('parse error: ' + e.message + '\n'); process.exit(1); }
            });
        ")

        if [ -z "$ids" ]; then
            log "ERROR: no anthropic secrets found in onecli"
            return 1
        fi

        local any_failed=0
        while IFS= read -r id; do
            [ -z "$id" ] && continue
            if "$ONECLI" secrets update --id "$id" --value "$token" > /dev/null 2>&1; then
                log "Updated secret ${id}"
            else
                log "ERROR: failed to update secret ${id}"
                any_failed=1
            fi
        done <<< "$ids"

        if [ "$any_failed" -eq 0 ]; then
            echo "$expires_at" > "$CACHE_FILE"
            log "Sync complete (expiresAt=${expires_at})"
        fi

        # Also copy credentials directly into Otis's Claude shared dir so
        # Claude Code reads the real token without relying on proxy injection.
        if [ -d "$OTIS_CLAUDE_DIR" ]; then
            cp "$CREDENTIALS_FILE" "$OTIS_CLAUDE_DIR/.credentials.json"
            chmod 600 "$OTIS_CLAUDE_DIR/.credentials.json"
            log "Credentials copied to Otis shared dir"
        fi
    fi

    # Validate every VALIDATE_EVERY polls or after a sync
    POLL_COUNT=$((POLL_COUNT + 1))
    if [ "$token_changed" -eq 1 ] || [ $((POLL_COUNT % VALIDATE_EVERY)) -eq 0 ]; then
        local status
        status=$(validate_token "$token")
        if [ "$status" = "401" ] || [ "$status" = "000" ]; then
            if [ ! -f "$ALERT_SENT_FILE" ]; then
                log "Token invalid (HTTP ${status}) — sending Telegram alert"
                send_telegram "⚠️ Otis: Claude token expired. Run on homelab: claude logout && claude login — you'll only get this message once."
                touch "$ALERT_SENT_FILE"
            else
                log "Token invalid (HTTP ${status}) — alert already sent, staying quiet"
            fi
        else
            log "Token valid (HTTP ${status})"
            if [ -f "$ALERT_SENT_FILE" ]; then
                rm -f "$ALERT_SENT_FILE"
                log "Token recovered — clearing alert flag, restarting Otis"
                systemctl --user restart nanoclaw-v2-e9d3c188.service || log "WARNING: failed to restart Otis service"
                send_telegram "✅ Otis: Claude token recovered — Otis restarted and back online."
            fi
        fi
    fi
}

log "Starting — polling every ${POLL_INTERVAL}s, validating every $((POLL_INTERVAL * VALIDATE_EVERY))s"
sync_token || true

while true; do
    sleep "$POLL_INTERVAL"
    sync_token || true
done
