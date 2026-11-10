# OpenResty Manager for Railway.
# Upstream pinned by digest. The wrapper entrypoint keeps all state on one volume at /data, replaces the
# upstream default login (admin / #Passw0rd) with $ADMIN_PASSWORD before anything is exposed, and puts an
# HTTP front proxy on Railway's injected PORT (upstream serves HTTPS only, on 34567, with a self-signed
# certificate, which Railway's edge and healthcheck cannot dial).
FROM uusec/openresty-manager@sha256:be49bec115b30c69fb19dbd7bb84f3a72499d8bb73abedd85f60d78111a2375b

COPY railway-entrypoint.sh /usr/local/bin/railway-entrypoint.sh
COPY front.conf.template /etc/om-front.conf.template
RUN chmod 755 /usr/local/bin/railway-entrypoint.sh

WORKDIR /opt/om
EXPOSE 8080
ENTRYPOINT ["/usr/local/bin/railway-entrypoint.sh"]
