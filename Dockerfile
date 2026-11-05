FROM alpine:3.22

RUN apk add --no-cache \
    bash \
    rsync \
    openssh-client \
    curl \
    sshpass \
    tzdata \
    coreutils \
    findutils \
    util-linux \
    tini \
  && mkdir -p /config /run/rsync-secrets /data

COPY scripts/entrypoint.sh scripts/backup.sh scripts/rsync-common.sh /usr/local/bin/
RUN chmod 0755 /usr/local/bin/entrypoint.sh /usr/local/bin/backup.sh /usr/local/bin/rsync-common.sh

ENV TZ=UTC \
    BACKUP_TIME=03:00 \
    RUN_ON_START=false \
    RSYNC_PROFILE=standard \
    BACKUP_MODE=append \
    SOURCE_DIRS="upload library profile backups" \
    REQUIRE_DB_BACKUP=true \
    DB_BACKUP_MAX_AGE_HOURS=48 \
    TRIGGER_DB_BACKUP=false \
    DB_BACKUP_TRIGGER_TIMEOUT_SECONDS=1800 \
    SSH_PORT=22

VOLUME /config
ENTRYPOINT ["/sbin/tini", "--", "/usr/local/bin/entrypoint.sh"]
CMD ["schedule"]
