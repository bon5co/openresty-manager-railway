# openresty-manager-railway

Wrapper image for [OpenResty Manager](https://github.com/Safe3/openresty-manager) (an OpenResty/nginx reverse-proxy control panel with a REST API) on Railway.

The upstream image is pinned by digest. The wrapper entrypoint:

- keeps the database, JWT key, certificates and generated proxy configs on one volume at `/data`, write-tested at every boot,
- starts the upstream server on loopback only, replaces the upstream default login (`admin` / `#Passw0rd`) with `ADMIN_PASSWORD`, and only then opens the public listener, so there is no window in which the default login is reachable,
- serves the panel over HTTP on Railway's injected `PORT` through a small front proxy (upstream is HTTPS-only on 34567 with a self-signed certificate), with websocket upgrade for the web terminal, and answers `401` rather than upstream's `400` when an API call carries no token.

Mount one volume at `/data`. Set `ADMIN_PASSWORD`. Published as `ghcr.io/bon5co/openresty-manager-railway`. Used by the Railway template "OpenResty Manager".
