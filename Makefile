include $(TOPDIR)/rules.mk

PKG_NAME:=mors
PKG_VERSION:=1.3.0~beta5
PKG_RELEASE:=18
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)-$(PKG_RELEASE)
MOLOT_UNINSTALL:=mors uninstall full

include $(INCLUDE_DIR)/package.mk

define Package/mors
	SECTION:=utils
	CATEGORY:=Keendev
	# DEPENDS:=+jq +curl +knot-dig +libpcre +nano-full +cron +bind-dig +dnsmasq-full +ipset +dnscrypt-proxy2 +iptables +libopenssl +shadowsocks-rust +xray
	DEPENDS:=+libpcre +jq +curl +knot-dig +nano-full +cron +bind-dig +dnsmasq-full +ipset +dnscrypt-proxy2 +iptables +conntrack +coreutils-cksum +coreutils-timeout +shadowsocks-libev-ss-redir +shadowsocks-libev-ss-local +shadowsocks-libev-config +libmbedtls +xray
	URL:=no
	TITLE:=VPN клиент для обработки запросов по внесению хостов в белый список.
	PKGARCH:=all
endef
# +libstdcpp 
define Package/mors/description
	Данный пакет позволяет осуществлять контроль и поддерживать в актуальном состоянии
	защищенный список хостов или "Белый список". При обращении к любому хосту из
	этого списка, весь трафик будет идти через любое VPN, Shadowsocks или VLESS соединение,
	заранее настроенное на роутере.
endef

define Build/Prepare
endef
define Build/Configure
endef
define Build/Compile
endef

# Во время инсталляции задаем папку в которую будем
# копировать наш скрипт и затем копируем его в эту папку
define Package/mors/install
	$(INSTALL_DIR) $(1)/opt/apps/mors

	$(CP) ./opt/. $(1)/opt/apps/mors
endef

# Legacy bootstrap is intentionally self-contained: during an upgrade the new
# data files, including lifecycle_state, have not been installed yet.
define Package/mors/preinst

#!/bin/sh

[ "$$1" = upgrade ] || exit 0
[ ! -e /opt/etc/.mors/lifecycle/state.json ] || exit 0

state=unconfigured
source=legacy_migration
setup_finished=$$(grep '^SETUP_FINISHED=' /opt/etc/mors.conf 2>/dev/null | head -n 1 | cut -d= -f2-)
interface=$$(grep '^INFACE_CLI=' /opt/etc/mors.conf 2>/dev/null | head -n 1 | cut -d= -f2-)
if [ "$$setup_finished" = true ]; then
	if [ -n "$$interface" ] && [ -f /opt/etc/init.d/S96mors ]; then
		state=ready
	else
		state=recovery_required
		source=legacy_validation_failed
	fi
fi

umask 077
mkdir -p /opt/etc/.mors/lifecycle/transactions || exit 1
chmod 700 /opt/etc/.mors/lifecycle /opt/etc/.mors/lifecycle/transactions || exit 1
now=$$(date -u '+%Y-%m-%dT%H:%M:%SZ')
jq -n --arg state "$$state" --arg updated_at "$$now" --arg source "$$source" \
	'{schema_version: 1, state: $$state, updated_at: $$updated_at, source: $$source}' \
	>/opt/etc/.mors/lifecycle/state.json.tmp || exit 1
chmod 600 /opt/etc/.mors/lifecycle/state.json.tmp || exit 1
mv -f /opt/etc/.mors/lifecycle/state.json.tmp /opt/etc/.mors/lifecycle/state.json || exit 1
sync

endef

#---------------------------------------------------------------------
# Скрипт создаем, который выполняется после инсталляции пакета
# Задаем в кроне время обновления ip адресов хостов
#---------------------------------------------------------------------
define Package/mors/postinst

#!/bin/sh

BLUE="\033[36m";
NOCL="\033[m";

print_line()(printf "%83s\n" | tr " " "=")

chmod -R +x /opt/apps/mors/bin/*
# chmod -R +x /opt/apps/mors/sbin/dnsmasq/*
chmod -R +x /opt/apps/mors/etc/init.d/*
chmod -R +x /opt/apps/mors/etc/ndm/*

ln -sf /opt/apps/mors/bin/mors /opt/bin/mors

[ -f /opt/etc/mors.conf ] || cp -f /opt/apps/mors/etc/conf/mors.conf /opt/etc/mors.conf
[ -f /opt/etc/mors.list ] || cp -f /opt/apps/mors/etc/conf/mors.list /opt/etc/mors.list
mkdir -p /opt/etc/adblock /opt/etc/dnsmasq.d
[ -f /opt/etc/adblock/sources.list ] || cp -f /opt/apps/mors/etc/conf/adblock.sources /opt/etc/adblock/sources.list
cp -f /opt/apps/mors/etc/ndm/ndm /opt/apps/mors/bin/libs/ndm

sed -i "s/\(APP_VERSION=\).*/\1$(PKG_VERSION)/; s/^,//; s/\,/ /g;" "/opt/etc/mors.conf"
sed -i "s/\(APP_RELEASE=\).*/\1$(PKG_RELEASE)/; s/^,//; s/\,/ /g;" "/opt/etc/mors.conf"

. /opt/apps/mors/bin/libs/lifecycle_state
lifecycle_state__read >/dev/null || {
	echo "Не удалось создать или прочитать lifecycle state Mors." >&2
	exit 1
}

print_line
echo -e "Для настройки пакета МОРС наберите \033[36mmors setup\033[m"
print_line

endef

#---------------------------------------------------------------------
# Создаем скрипт, который выполняется при удалении пакета
# Удаляем из крона запись об обновлении ip адресов
#---------------------------------------------------------------------
define Package/mors/prerm

#!/bin/sh

operation=$$1
case "$$operation" in
	remove)
		active=''
		[ ! -r /opt/etc/.mors/lifecycle/active ] || \
			active=$$(tr -d '\r\n' </opt/etc/.mors/lifecycle/active)
		journal=/opt/etc/.mors/lifecycle/transactions/$$active/journal.json
		if [ -z "$$active" ] || [ ! -r "$$journal" ] || \
			[ "$$(jq -r '.operation // empty' "$$journal" 2>/dev/null)" != uninstall ] || \
			[ "$$(jq -r '.phase // empty' "$$journal" 2>/dev/null)" != package_remove_ready ]; then
			echo "Удаление остановлено: сначала выполните mors uninstall --yes." >&2
			exit 1
		fi
		;;
	upgrade)
		active=''
		[ ! -r /opt/etc/.mors/lifecycle/active ] || \
			active=$$(tr -d '\r\n' </opt/etc/.mors/lifecycle/active)
		journal=/opt/etc/.mors/lifecycle/transactions/$$active/journal.json
		transaction_operation=$$(jq -r '.operation // empty' "$$journal" 2>/dev/null)
		if [ -z "$$active" ] || [ ! -r "$$journal" ] || \
			{ [ "$$transaction_operation" != upgrade ] && [ "$$transaction_operation" != rollback ]; }; then
			echo "Обновление остановлено: используйте mors update apply ... --yes." >&2
			exit 1
		fi
		;;
esac

endef

define Package/mors/postrm

#!/bin/sh

operation=$$1
[ "$$operation" = remove ] || exit 0

# Passive cleanup only: dataplane has already been removed and verified by
# prerm/uninstall while all Mors code and dependencies were still available.
rm -f /opt/bin/mors \
	/opt/etc/init.d/S96mors \
	/opt/etc/init.d/S25mors-vless \
	/opt/etc/init.d/S97xray \
	/opt/etc/ndm/fs.d/15-mors-start.sh \
	/opt/etc/ndm/netfilter.d/100-dns-local \
	/opt/etc/ndm/netfilter.d/100-vpn-mark \
	/opt/etc/ndm/netfilter.d/100-proxy-redirect \
	/opt/etc/ndm/ifcreated.d/mors-iface-add \
	/opt/etc/ndm/ifdestroyed.d/mors-iface-del \
	/opt/etc/ndm/iflayerchanged.d/100-mors-vpn \
	/opt/etc/cron.5mins/vless-watchdog

if [ -e /opt/etc/.mors/lifecycle/purge-requested ]; then
	rm -f /opt/etc/mors.conf /opt/etc/mors.list \
		/opt/etc/dnsmasq.d/mors.dnsmasq \
		/opt/etc/adblock/sources.list \
		/opt/etc/adblock/exception.list \
		/opt/etc/adblock/ads.mors.list
	rm -rf /opt/etc/.mors
else
	umask 077
	mkdir -p /opt/etc/.mors/lifecycle/transactions
	now=$$(date -u '+%Y-%m-%dT%H:%M:%SZ')
	active=''
	[ ! -r /opt/etc/.mors/lifecycle/active ] || \
		active=$$(tr -d '\r\n' </opt/etc/.mors/lifecycle/active)
	journal=/opt/etc/.mors/lifecycle/transactions/$$active/journal.json
	commit_ok=true
	if [ -z "$$active" ] || [ ! -r "$$journal" ] || \
		! sed \
			-e 's/"phase": *"[^"]*"/"phase": "completed"/' \
			-e 's/"outcome": *[^,}]*/"outcome": "success"/' \
			-e 's/"updated_at": *"[^"]*"/"updated_at": "'"$$now"'"/' \
			"$$journal" >"$$journal.tmp" || \
		! chmod 600 "$$journal.tmp" || ! mv -f "$$journal.tmp" "$$journal"; then
		commit_ok=false
	fi
	if ! printf '{"schema_version":1,"state":"unconfigured","updated_at":"%s","source":"package_removed"}\n' "$$now" \
		>/opt/etc/.mors/lifecycle/state.json.tmp || \
		! chmod 600 /opt/etc/.mors/lifecycle/state.json.tmp || \
		! mv -f /opt/etc/.mors/lifecycle/state.json.tmp /opt/etc/.mors/lifecycle/state.json; then
		commit_ok=false
	fi
	[ "$$commit_ok" = true ] && rm -f /opt/etc/.mors/lifecycle/active
	sync
	[ "$$commit_ok" = true ] || exit 1
fi

endef

$(eval $(call BuildPackage,mors))
