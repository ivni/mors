include $(TOPDIR)/rules.mk

PKG_NAME:=mors
PKG_VERSION:=1.1.9_beta-10
PKG_RELEASE:= 26
PKG_BUILD_DIR:=$(BUILD_DIR)/$(PKG_NAME)-$(PKG_VERSION)-$(PKG_RELEASE)
MOLOT_UNINSTALL:=mors uninstall full

include $(INCLUDE_DIR)/package.mk

define Package/mors
	SECTION:=utils
	CATEGORY:=Keendev
	# DEPENDS:=+jq +curl +knot-dig +libpcre +nano-full +cron +bind-dig +dnsmasq-full +ipset +dnscrypt-proxy2 +iptables +libopenssl +shadowsocks-rust +xray
	DEPENDS:=+libpcre +jq +curl +knot-dig +nano-full +cron +bind-dig +dnsmasq-full +ipset +dnscrypt-proxy2 +iptables +shadowsocks-libev-ss-redir +shadowsocks-libev-config +libmbedtls +xray
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
	$(INSTALL_DIR) $(1)/opt/etc/init.d
	$(INSTALL_DIR) $(1)/opt/etc/ndm/fs.d
	$(INSTALL_DIR) $(1)/opt/etc/ndm/netfilter.d
	$(INSTALL_DIR) $(1)/opt/apps/mors

	$(INSTALL_BIN) opt/etc/ndm/fs.d/15-mors-start.sh $(1)/opt/etc/ndm/fs.d
	$(INSTALL_BIN) opt/etc/ndm/netfilter.d/100-dns-local $(1)/opt/etc/ndm/netfilter.d

	$(INSTALL_BIN) opt/etc/init.d/S96mors $(1)/opt/etc/init.d
	$(CP) ./opt/. $(1)/opt/apps/mors
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

cp -f /opt/apps/mors/etc/conf/mors.conf /opt/etc/mors.conf
[ -f /opt/etc/mors.list ] || cp -f /opt/apps/mors/etc/conf/mors.list /opt/etc/mors.list
mkdir -p /opt/etc/adblock /opt/etc/dnsmasq.d
cp -f /opt/apps/mors/etc/conf/adblock.sources /opt/etc/adblock/sources.list
cp -f /opt/apps/mors/etc/ndm/ndm /opt/apps/mors/bin/libs/ndm

sed -i "s/\(APP_VERSION=\).*/\1$(PKG_VERSION)/; s/^,//; s/\,/ /g;" "/opt/etc/mors.conf"
sed -i "s/\(APP_RELEASE=\).*/\1$(PKG_RELEASE)/; s/^,//; s/\,/ /g;" "/opt/etc/mors.conf"

print_line
echo -e "Для настройки пакета МОРС наберите \033[36mmors setup\033[m"
print_line

endef

#---------------------------------------------------------------------
# Создаем скрипт, который выполняется при удалении пакета
# Удаляем из крона запись об обновлении ip адресов
#---------------------------------------------------------------------
define Package/mors/postrm

#!/bin/sh

endef

$(eval $(call BuildPackage,mors))
