# Kernel IPsec algorithms

IKE negotiation and kernel ESP/AH processing use separate cryptographic
implementations. A userspace provider such as OpenSSL can negotiate a proposal
even when its kernel algorithm module is not installed.

The `strongswan-mod-kernel-netlink` package includes the kernel dependencies for
strongSwan's default ESP/AH proposals: AES-GCM, HMAC-SHA-256/384/512 and AES-XCBC.
The existing `kmod-ipsec` dependency supplies CBC, HMAC and SHA-1, and OpenWrt's
generic kernel configuration supplies AES. These dependencies belong to the
kernel backend regardless of the selected userspace crypto provider.

Custom ESP/AH proposals may need additional kernel crypto packages. The algorithms
reported by `swanctl --list-algs` describe the loaded userspace plugins; that list
does not prove kernel SA installation. Check the installed CHILD_SA and its native
XFRM state when qualifying a proposal. No service is enabled by this dependency
selection, and existing `ipsec` UCI and `swanctl`/procd service ownership remain
unchanged.

# IKEv1 replacement ownership

A replacement IKEv1 SA adopts existing CHILD SAs through the native manager.
The migrated predecessor remains only for the delayed DELETE grace period;
local renewal, DPD and new Quick Mode selection cannot reuse that retired owner.
The replacement retains its own identity and installed kernel policies.

Competing-renewal qualification must inspect both peers' current CHILD SAs and
traffic across the overlap. A target-side installed CHILD alone does not prove
that the counterpart retained its policy. Disabling a counterpart's renewal
can isolate other behavior, but does not qualify simultaneous renewal with it.
