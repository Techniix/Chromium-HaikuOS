// Haiku compat <net/if_arp.h>: only the hardware-type constants, mapped to
// the IFT_* values Haiku puts in sockaddr_dl::sdl_type.
#ifndef HAIKU_COMPAT_NET_IF_ARP_H
#define HAIKU_COMPAT_NET_IF_ARP_H
#if __has_include(<net/if_types.h>)
#include <net/if_types.h>
#endif
#ifndef IFT_ETHER
#define IFT_ETHER 0x6
#endif
#ifndef ARPHRD_ETHER
#define ARPHRD_ETHER IFT_ETHER
#endif
#ifndef ARPHRD_IEEE802
#define ARPHRD_IEEE802 IFT_ETHER
#endif
#endif
