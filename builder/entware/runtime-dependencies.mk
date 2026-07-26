# Canonical Entware runtime dependency set used by both the Mors package and
# the prebuilt builder image. Keep this list free of package-version data so a
# Mors-only release does not invalidate the builder image.
MORS_RUNTIME_DEPENDS:=+libpcre +jq +curl +knot-dig +nano-full +cron +bind-dig +dnsmasq-full +ipset +dnscrypt-proxy2 +iptables +conntrack +coreutils-cksum +coreutils-stat +coreutils-timeout +shadowsocks-libev-ss-redir +shadowsocks-libev-ss-local +shadowsocks-libev-config +libmbedtls +xray
