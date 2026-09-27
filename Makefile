include $(TOPDIR)/rules.mk

LUCI_TITLE:=LuCI support for Xray (Stella)
LUCI_DEPENDS:=+xray-core +ucode +ucode-mod-fs +ucode-mod-uci +curl +kmod-nft-tproxy +kmod-nft-queue +ip-full
LUCI_PKGARCH:=all

PKG_NAME:=luci-app-stella
PKG_VERSION:=0.1.5
PKG_RELEASE:=1

define Package/luci-app-stella/conffiles
/etc/config/stella
/etc/stella/
endef

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
