#!/usr/bin/env bash
# Shared, provider-agnostic rsync settings; intended to be sourced.
set -euo pipefail

log() { printf '[%s] %s\n' "$(date -Is)" "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

setup_rsync() {
  [[ -n "${RSYNC_DESTINATION:-}" ]] || die 'RSYNC_DESTINATION is required.'
  [[ "${RSYNC_DESTINATION}" != *$'\n'* ]] || die 'Invalid destination.'

  local ssh_transport=false
  if [[ "$RSYNC_DESTINATION" != rsync://* && "$RSYNC_DESTINATION" != *::* && "$RSYNC_DESTINATION" == *:* ]]; then
    ssh_transport=true
  fi

  if [[ "$ssh_transport" == true ]]; then
    if [[ -z "${RSYNC_RSH:-}" ]]; then
      [[ "${SSH_PORT:-22}" =~ ^[0-9]+$ ]] || die 'SSH_PORT must be numeric.'
      [[ -f /config/known_hosts ]] || die 'SSH requires /config/known_hosts with the remote host key verified and pinned.'
      local sshcmd="ssh -p ${SSH_PORT:-22} -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/config/known_hosts -o ServerAliveInterval=30"
      if [[ -n "${SSH_IDENTITY_FILE:-}" ]]; then
        [[ -f "$SSH_IDENTITY_FILE" ]] || die "SSH key missing: $SSH_IDENTITY_FILE"
        [[ "$SSH_IDENTITY_FILE" =~ ^[A-Za-z0-9_./-]+$ ]] || die 'SSH_IDENTITY_FILE path contains unsupported characters.'
        sshcmd="$sshcmd -i $SSH_IDENTITY_FILE -o IdentitiesOnly=yes"
      fi
      if [[ -n "${RSYNC_SSH_PASSWORD_FILE:-}" ]]; then
        [[ -f "$RSYNC_SSH_PASSWORD_FILE" ]] || die "SSH password file missing: $RSYNC_SSH_PASSWORD_FILE"
        [[ "$RSYNC_SSH_PASSWORD_FILE" =~ ^[A-Za-z0-9_./-]+$ ]] || die 'Password-file path contains unsupported characters.'
        sshcmd="sshpass -f $RSYNC_SSH_PASSWORD_FILE $sshcmd"
      else
        sshcmd="$sshcmd -o BatchMode=yes"
      fi
      export RSYNC_RSH="$sshcmd"
    fi
  fi

  RSYNC_ARGS=(-r -v)
  case "${RSYNC_PROFILE:-standard}" in
    standard)
      case "${BACKUP_MODE:-append}" in
        append) RSYNC_ARGS+=(--ignore-existing) ;;
        update) RSYNC_ARGS+=(-t) ;;
        *) die 'BACKUP_MODE must be append or update.' ;;
      esac
      ;;
    custom)
      # Explicit flags from a file; no potentially unsafe defaults other than -r -v.
      ;;
    *) die 'RSYNC_PROFILE must be standard or custom.' ;;
  esac

  if [[ -n "${RSYNC_OPTIONS_FILE:-}" ]]; then
    [[ -f "$RSYNC_OPTIONS_FILE" ]] || die "RSYNC_OPTIONS_FILE not found: $RSYNC_OPTIONS_FILE"
    local line
    while IFS= read -r line || [[ -n "$line" ]]; do
      [[ -z "$line" || "$line" == \#* ]] && continue
      # One literal argument per line; never eval or expand shell code.
      RSYNC_ARGS+=("$line")
    done < "$RSYNC_OPTIONS_FILE"
  fi

  # Backup process intentionally prohibits deletion of local/remote files.
  local arg
  for arg in "${RSYNC_ARGS[@]}"; do
    case "$arg" in
      --delete*|--del|--remove-source-files|--prune-empty-dirs|--force)
        die "Disallowed destructive rsync argument: $arg" ;;
    esac
  done

  if [[ -n "${RSYNC_DAEMON_PASSWORD_FILE:-}" ]]; then
    [[ -f "$RSYNC_DAEMON_PASSWORD_FILE" ]] || die "Daemon password file missing: $RSYNC_DAEMON_PASSWORD_FILE"
    RSYNC_ARGS+=(--password-file="$RSYNC_DAEMON_PASSWORD_FILE")
  fi

  if [[ "${DRY_RUN:-false}" == true ]]; then
    RSYNC_ARGS+=(--dry-run)
  fi
}
