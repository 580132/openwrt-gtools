#
# luci-app-gtools - update proxy cores from upstream GitHub releases
#
# This is free software, licensed under the GNU General Public License v3
# or later.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-gtools
PKG_VERSION:=1.0.0
PKG_RELEASE:=1
PKG_LICENSE:=GPL-3.0-or-later
PKG_MAINTAINER:=gtools contributors

LUCI_TITLE:=GTools - update proxy cores from upstream releases
LUCI_DESCRIPTION:=LuCI app that downloads and installs the latest honk (and future) cores from upstream GitHub releases, with SHA256 verification, backups and rollback.
LUCI_DEPENDS:=+luci-base +ucode +ucode-mod-fs +ucode-mod-uci +uclient-fetch +ca-bundle
LUCI_PKGARCH:=all

define Package/$(PKG_NAME)/conffiles
/etc/config/gtools
endef

# luci.mk only reloads rpcd; also make sure the helper scripts are executable
# even when the source checkout lost the mode bits (e.g. on Windows).
define Package/$(PKG_NAME)/postinst
#!/bin/sh
ROOT="$${IPKG_INSTROOT:-}"
chmod 0755 "$$ROOT/usr/share/gtools/gtools.sh" 2>/dev/null
chmod 0755 "$$ROOT/etc/uci-defaults/90-gtools" 2>/dev/null
chmod 0600 "$$ROOT/etc/config/gtools" 2>/dev/null
[ -n "$$ROOT" ] || {
	rm -f /tmp/luci-indexcache.*
	rm -rf /tmp/luci-modulecache/
	/etc/init.d/rpcd reload 2>/dev/null
}
exit 0
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
