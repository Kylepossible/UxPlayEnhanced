/**
 *  Embedded mDNS responder for UxPlay - replaces Bonjour/dnssd.dll dependency.
 *
 *  Drop-in replacement for dnssd.c that implements the same dnssd.h API using
 *  an in-process mDNS responder running on a background thread. No external
 *  Bonjour service or dnssd.dll required.
 *
 *  Copyright (C) 2011-2012  Juho Vähä-Herttua (original dnssd.c API)
 *  Copyright (C) 2026  Embedded mDNS implementation
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 */

#include <stdlib.h>
#include <string.h>
#include <stdio.h>
#include <assert.h>

#include "compat.h"
#include "dnssd.h"
#include "dnssdint.h"
#include "global.h"
#include "utils.h"

#ifdef WIN32
#include <iphlpapi.h>
#else
#include <ifaddrs.h>
#include <net/if.h>
#endif

#define MAX_DEVICEID 18
#define MAX_SERVNAME 256

/* mDNS constants */
#define MDNS_PORT       5353
#define MDNS_ADDR       "224.0.0.251"
#define MDNS_BUF_SIZE   1500

/* DNS record types */
#define DNS_TYPE_A      1
#define DNS_TYPE_PTR    12
#define DNS_TYPE_TXT    16
#define DNS_TYPE_AAAA   28
#define DNS_TYPE_SRV    33
#define DNS_TYPE_ANY    255

/* DNS class */
#define DNS_CLASS_IN    0x0001
#define DNS_CLASS_FLUSH 0x8001   /* unique record, cache-flush bit set */

/* TTL values (seconds) */
#define TTL_DEFAULT     4500
#define TTL_HOST        120

/* Announcement repeat count and interval (ms) */
#define ANNOUNCE_COUNT  3
#define ANNOUNCE_INTERVAL_MS 250

/* Use the record's normal TTL rather than an explicit override. */
#define TTL_USE_DEFAULT (-1)

/* Interfaces the responder will advertise on, and how often the list is
 * rechecked so that joining Wi-Fi, docking, or raising a VPN is picked up. */
#define MAX_MDNS_IFACES 16
#define IFACE_REFRESH_INTERVAL_S 15

/* ------------------------------------------------------------------ */
/*  TXT Record helpers (replaces Bonjour TXTRecord* functions)        */
/* ------------------------------------------------------------------ */

typedef struct {
    uint8_t *data;
    uint16_t len;
    uint16_t capacity;
} txt_record_t;

static void txt_record_create(txt_record_t *rec)
{
    rec->data = NULL;
    rec->len = 0;
    rec->capacity = 0;
}

static void txt_record_deallocate(txt_record_t *rec)
{
    free(rec->data);
    rec->data = NULL;
    rec->len = 0;
    rec->capacity = 0;
}

/**
 * Locate the entry for key. Returns the offset of its length byte, or -1.
 * Keys are compared exactly; every caller passes an internal lowercase literal.
 */
static int txt_record_find(const txt_record_t *rec, const char *key,
                           uint16_t *entry_len_out)
{
    uint16_t key_len = (uint16_t)strlen(key);
    uint16_t pos = 0;

    while (pos < rec->len) {
        uint8_t entry_len = rec->data[pos];
        if (entry_len == 0 || pos + 1 + entry_len > rec->len) break;
        if (entry_len > key_len && rec->data[pos + 1 + key_len] == '=' &&
            memcmp(rec->data + pos + 1, key, key_len) == 0) {
            if (entry_len_out) *entry_len_out = entry_len;
            return (int)pos;
        }
        pos = (uint16_t)(pos + 1 + entry_len);
    }
    return -1;
}

static int txt_record_set_value(txt_record_t *rec, const char *key,
                                uint8_t value_size, const void *value)
{
    /* TXT record entry format: [len_byte] key=value */
    uint16_t key_len = (uint16_t)strlen(key);
    uint16_t entry_len = key_len + 1 + value_size; /* key + '=' + value */

    /* The length prefix is one byte, so an entry cannot exceed 255. */
    if (entry_len > 255) return -1;

    /* Bonjour's TXTRecordSetValue() replaces the value when the key is already
     * present. Appending a second entry instead would leave duplicate keys in
     * the record, which RFC 6763 6.4 says clients resolve by taking the first
     * occurrence -- so the embedded responder would advertise a different value
     * than the Bonjour build for any key set more than once. */
    uint16_t existing_len = 0;
    int existing = txt_record_find(rec, key, &existing_len);
    if (existing >= 0) {
        uint16_t removed = (uint16_t)(1 + existing_len);
        memmove(rec->data + existing, rec->data + existing + removed,
                (size_t)(rec->len - existing - removed));
        rec->len = (uint16_t)(rec->len - removed);
    }

    uint16_t needed = rec->len + 1 + entry_len;    /* +1 for length byte */

    if (needed > rec->capacity) {
        uint16_t new_cap = (needed < 256) ? 256 : (needed * 2);
        uint8_t *new_data = (uint8_t *)realloc(rec->data, new_cap);
        if (!new_data) return -1;
        rec->data = new_data;
        rec->capacity = new_cap;
    }

    rec->data[rec->len] = (uint8_t)entry_len;
    memcpy(rec->data + rec->len + 1, key, key_len);
    rec->data[rec->len + 1 + key_len] = '=';
    if (value_size > 0 && value)
        memcpy(rec->data + rec->len + 1 + key_len + 1, value, value_size);
    rec->len = needed;
    return 0;
}

/* ------------------------------------------------------------------ */
/*  mDNS service descriptor                                           */
/* ------------------------------------------------------------------ */

typedef struct {
    char instance_name[MAX_SERVNAME]; /* e.g. "AABBCCDDEEFF@MyPC" or "MyPC" */
    char reg_type[64];                /* e.g. "_raop._tcp" */
    uint16_t port;                    /* host byte order */
    uint8_t *txt_data;               /* copy of TXT record bytes */
    uint16_t txt_len;
    int active;
} mdns_service_t;

/* ------------------------------------------------------------------ */
/*  Main dnssd struct                                                  */
/* ------------------------------------------------------------------ */

struct dnssd_s {
    txt_record_t raop_record;
    txt_record_t airplay_record;

    mdns_service_t raop_service;
    mdns_service_t airplay_service;

    char *name;
    int name_len;

    char *hw_addr;
    int hw_addr_len;

    char *pk;

    uint32_t features1;
    uint32_t features2;

    unsigned char pin_pw;

    /* mDNS responder state */
    thread_handle_t mdns_thread;
    int             mdns_sock;       /* UDP socket (SOCKET on Windows) */
    volatile int    mdns_running;
    char            hostname[128];   /* "UxPlay-XXXX.local" */
    mutex_handle_t  lock;

    /* Local IPv4 addresses to advertise on, network byte order. Guarded by
     * iface_lock, which is also held across a send so that the per-interface
     * IP_MULTICAST_IF setting cannot be changed by another thread mid-send.
     * Lock order is always lock -> iface_lock; never the reverse. */
    uint32_t        ifaces[MAX_MDNS_IFACES];
    int             iface_count;
    mutex_handle_t  iface_lock;
};

/* ------------------------------------------------------------------ */
/*  DNS packet encoding helpers                                        */
/* ------------------------------------------------------------------ */

static int write_u16(uint8_t *buf, uint16_t val)
{
    buf[0] = (uint8_t)(val >> 8);
    buf[1] = (uint8_t)(val & 0xFF);
    return 2;
}

static int write_u32(uint8_t *buf, uint32_t val)
{
    buf[0] = (uint8_t)(val >> 24);
    buf[1] = (uint8_t)(val >> 16);
    buf[2] = (uint8_t)(val >> 8);
    buf[3] = (uint8_t)(val & 0xFF);
    return 4;
}

static uint16_t read_u16(const uint8_t *buf)
{
    return (uint16_t)((buf[0] << 8) | buf[1]);
}

/**
 * Encode a dotted name into DNS label format.
 * e.g. "_airplay._tcp.local" -> [8]_airplay[4]_tcp[5]local[0]
 * Returns bytes written, or -1 on error.
 */
static int dns_name_encode(const char *name, uint8_t *buf, int buf_size)
{
    int pos = 0;
    const char *p = name;

    while (*p) {
        const char *dot = strchr(p, '.');
        int label_len = dot ? (int)(dot - p) : (int)strlen(p);
        if (label_len > 63 || pos + 1 + label_len >= buf_size) return -1;
        buf[pos++] = (uint8_t)label_len;
        memcpy(buf + pos, p, label_len);
        pos += label_len;
        p += label_len;
        if (*p == '.') p++;
    }
    if (pos >= buf_size) return -1;
    buf[pos++] = 0;
    return pos;
}

/**
 * Decode a DNS name from a packet (handles compression pointers).
 * Returns the offset after the name in the original packet position,
 * or -1 on error.
 */
static int dns_name_decode(const uint8_t *pkt, int pkt_len, int offset,
                           char *name, int name_size)
{
    int pos = offset;
    int name_pos = 0;
    int jumped = 0;
    int next_pos = -1;
    int safety = 256;

    while (pos < pkt_len && safety-- > 0) {
        uint8_t len = pkt[pos];
        if (len == 0) {
            pos++;
            break;
        }
        if ((len & 0xC0) == 0xC0) {
            if (pos + 1 >= pkt_len) return -1;
            if (!jumped) next_pos = pos + 2;
            jumped = 1;
            pos = ((len & 0x3F) << 8) | pkt[pos + 1];
            continue;
        }
        pos++;
        if (pos + len > pkt_len) return -1;
        if (name_pos > 0 && name_pos < name_size - 1)
            name[name_pos++] = '.';
        int copy = (name_pos + len < name_size - 1) ? len : (name_size - 1 - name_pos);
        memcpy(name + name_pos, pkt + pos, copy);
        name_pos += copy;
        pos += len;
    }
    if (name_pos < name_size) name[name_pos] = '\0';
    return jumped ? next_pos : pos;
}

/**
 * Build the fully-qualified instance name for a service.
 * e.g. "AABBCCDDEEFF@MyPC._raop._tcp.local"
 */
static void build_fqsn(const mdns_service_t *svc, char *buf, int buf_size)
{
    snprintf(buf, buf_size, "%s.%s.local", svc->instance_name, svc->reg_type);
}

/**
 * Build the service type FQDN.
 * e.g. "_raop._tcp.local"
 */
static void build_type_fqdn(const mdns_service_t *svc, char *buf, int buf_size)
{
    snprintf(buf, buf_size, "%s.local", svc->reg_type);
}

/* ------------------------------------------------------------------ */
/*  DNS record writing helpers                                         */
/* ------------------------------------------------------------------ */

/**
 * Write a DNS resource record header + encoded name.
 * Returns bytes written to buf, or -1 on error.
 */
static int write_rr_header(uint8_t *buf, int buf_size, const char *name,
                           uint16_t rtype, uint16_t rclass, uint32_t ttl,
                           uint16_t rdlength)
{
    int pos = 0;
    int n = dns_name_encode(name, buf, buf_size);
    if (n < 0) return -1;
    pos += n;
    if (pos + 10 > buf_size) return -1;
    pos += write_u16(buf + pos, rtype);
    pos += write_u16(buf + pos, rclass);
    pos += write_u32(buf + pos, ttl);
    pos += write_u16(buf + pos, rdlength);
    return pos;
}

/** Write a PTR record. Returns total bytes written. */
static int write_ptr_record(uint8_t *buf, int buf_size, const char *type_fqdn,
                            const char *instance_fqdn, uint32_t ttl)
{
    /* First compute RDATA length (encoded instance name) */
    uint8_t rdata[MAX_SERVNAME + 10];
    int rdata_len = dns_name_encode(instance_fqdn, rdata, sizeof(rdata));
    if (rdata_len < 0) return -1;

    int hdr_len = write_rr_header(buf, buf_size, type_fqdn,
                                  DNS_TYPE_PTR, DNS_CLASS_IN, ttl, (uint16_t)rdata_len);
    if (hdr_len < 0 || hdr_len + rdata_len > buf_size) return -1;
    memcpy(buf + hdr_len, rdata, rdata_len);
    return hdr_len + rdata_len;
}

/** Write an SRV record. Returns total bytes written. */
static int write_srv_record(uint8_t *buf, int buf_size, const char *instance_fqdn,
                            uint16_t port, const char *target_host, uint32_t ttl)
{
    uint8_t target_enc[256];
    int target_len = dns_name_encode(target_host, target_enc, sizeof(target_enc));
    if (target_len < 0) return -1;

    uint16_t rdlength = (uint16_t)(6 + target_len); /* priority(2) + weight(2) + port(2) + target */
    int hdr_len = write_rr_header(buf, buf_size, instance_fqdn,
                                  DNS_TYPE_SRV, DNS_CLASS_FLUSH, ttl, rdlength);
    if (hdr_len < 0 || hdr_len + rdlength > buf_size) return -1;

    int pos = hdr_len;
    pos += write_u16(buf + pos, 0);      /* priority */
    pos += write_u16(buf + pos, 0);      /* weight */
    pos += write_u16(buf + pos, port);
    memcpy(buf + pos, target_enc, target_len);
    pos += target_len;
    return pos;
}

/** Write a TXT record. Returns total bytes written. */
static int write_txt_record(uint8_t *buf, int buf_size, const char *instance_fqdn,
                            const uint8_t *txt_data, uint16_t txt_len, uint32_t ttl)
{
    uint16_t rdlength = txt_len > 0 ? txt_len : 1; /* at least 1 byte (empty TXT = single 0) */
    int hdr_len = write_rr_header(buf, buf_size, instance_fqdn,
                                  DNS_TYPE_TXT, DNS_CLASS_FLUSH, ttl, rdlength);
    if (hdr_len < 0 || hdr_len + rdlength > buf_size) return -1;

    if (txt_len > 0 && txt_data) {
        memcpy(buf + hdr_len, txt_data, txt_len);
    } else {
        buf[hdr_len] = 0;
    }
    return hdr_len + rdlength;
}

/** Write an A record. Returns total bytes written. */
static int write_a_record(uint8_t *buf, int buf_size, const char *hostname,
                          uint32_t ip_net_order, uint32_t ttl)
{
    int hdr_len = write_rr_header(buf, buf_size, hostname,
                                  DNS_TYPE_A, DNS_CLASS_FLUSH, ttl, 4);
    if (hdr_len < 0 || hdr_len + 4 > buf_size) return -1;
    memcpy(buf + hdr_len, &ip_net_order, 4);
    return hdr_len + 4;
}

/* ------------------------------------------------------------------ */
/*  Build a full mDNS response for a service                           */
/* ------------------------------------------------------------------ */

/**
 * Build a complete mDNS response packet for a service, given a query type.
 * For PTR queries: answer=PTR + additional=SRV,TXT,A (one-shot discovery).
 * For SRV/TXT/A queries: answer=requested record + additional records.
 * local_ip is the address of the interface this response will be sent on, so
 * each interface advertises the address a client on that link can reach.
 * ttl_override is TTL_USE_DEFAULT for normal records, or an explicit TTL --
 * notably 0, which is how a goodbye packet asks clients to flush.
 * Returns total packet size, or -1 on error.
 */
static int build_mdns_response(dnssd_t *dnssd, mdns_service_t *svc,
                               txt_record_t *txt_rec, int query_type,
                               uint8_t *pkt, int pkt_size, int ttl_override,
                               uint32_t local_ip)
{
    char type_fqdn[MAX_SERVNAME];
    char inst_fqdn[MAX_SERVNAME];
    char host_fqdn[256];

    build_type_fqdn(svc, type_fqdn, sizeof(type_fqdn));
    build_fqsn(svc, inst_fqdn, sizeof(inst_fqdn));
    snprintf(host_fqdn, sizeof(host_fqdn), "%s.local", dnssd->hostname);

    uint32_t ttl = ttl_override >= 0 ? (uint32_t) ttl_override : TTL_DEFAULT;
    uint32_t ttl_host = ttl_override >= 0 ? (uint32_t) ttl_override : TTL_HOST;

    int pos = 12; /* skip header, fill in later */
    int ancount = 0, arcount = 0;
    int n;

    if (pos >= pkt_size) return -1;

    switch (query_type) {
    case DNS_TYPE_PTR:
        /* Answer: PTR */
        n = write_ptr_record(pkt + pos, pkt_size - pos, type_fqdn, inst_fqdn, ttl);
        if (n < 0) return -1;
        pos += n; ancount++;
        /* Additional: SRV + TXT + A */
        n = write_srv_record(pkt + pos, pkt_size - pos, inst_fqdn, svc->port, host_fqdn, ttl_host);
        if (n > 0) { pos += n; arcount++; }
        n = write_txt_record(pkt + pos, pkt_size - pos, inst_fqdn,
                             txt_rec->data, txt_rec->len, ttl);
        if (n > 0) { pos += n; arcount++; }
        n = write_a_record(pkt + pos, pkt_size - pos, host_fqdn, local_ip, ttl_host);
        if (n > 0) { pos += n; arcount++; }
        break;

    case DNS_TYPE_SRV:
        n = write_srv_record(pkt + pos, pkt_size - pos, inst_fqdn, svc->port, host_fqdn, ttl_host);
        if (n < 0) return -1;
        pos += n; ancount++;
        /* Additional: A */
        n = write_a_record(pkt + pos, pkt_size - pos, host_fqdn, local_ip, ttl_host);
        if (n > 0) { pos += n; arcount++; }
        break;

    case DNS_TYPE_TXT:
        n = write_txt_record(pkt + pos, pkt_size - pos, inst_fqdn,
                             txt_rec->data, txt_rec->len, ttl);
        if (n < 0) return -1;
        pos += n; ancount++;
        break;

    case DNS_TYPE_A:
        n = write_a_record(pkt + pos, pkt_size - pos, host_fqdn, local_ip, ttl_host);
        if (n < 0) return -1;
        pos += n; ancount++;
        break;

    default:
        return -1;
    }

    /* Write header */
    write_u16(pkt + 0, 0);              /* Transaction ID = 0 */
    write_u16(pkt + 2, 0x8400);         /* Flags: response, authoritative */
    write_u16(pkt + 4, 0);              /* QDCOUNT */
    write_u16(pkt + 6, (uint16_t)ancount);
    write_u16(pkt + 8, 0);              /* NSCOUNT */
    write_u16(pkt + 10, (uint16_t)arcount);

    return pos;
}

/* ------------------------------------------------------------------ */
/*  Network helpers                                                    */
/* ------------------------------------------------------------------ */

/** Detect the best local IPv4 address (non-loopback). */
static uint32_t get_local_ip(void)
{
    /* Connect a UDP socket to a public address — doesn't send data,
       but the OS picks the right source interface for us. */
    int sock = (int)socket(AF_INET, SOCK_DGRAM, 0);
    if (sock < 0) return 0;

    struct sockaddr_in remote;
    memset(&remote, 0, sizeof(remote));
    remote.sin_family = AF_INET;
    remote.sin_port = htons(53);
    remote.sin_addr.s_addr = inet_addr("8.8.8.8");

    if (connect(sock, (struct sockaddr *)&remote, sizeof(remote)) < 0) {
        CLOSESOCKET(sock);
        return 0;
    }

    struct sockaddr_in local;
    socklen_t len = sizeof(local);
    if (getsockname(sock, (struct sockaddr *)&local, &len) < 0) {
        CLOSESOCKET(sock);
        return 0;
    }

    CLOSESOCKET(sock);
    return local.sin_addr.s_addr; /* network byte order */
}

/**
 * Collect every usable local IPv4 address.
 *
 * get_local_ip() alone is not enough: it reports only the interface that
 * happens to route toward the internet, so a multi-homed PC advertised on the
 * wrong link, a VPN could hide the LAN, and a machine with no default route
 * got nothing at all. Returns the number of addresses written.
 */
static int enumerate_local_ipv4(uint32_t *out, int max_count)
{
    int count = 0;

#ifdef WIN32
    ULONG size = 16384;
    IP_ADAPTER_ADDRESSES *adapters = NULL;
    ULONG result = ERROR_BUFFER_OVERFLOW;
    int attempts = 0;

    while (result == ERROR_BUFFER_OVERFLOW && attempts++ < 4) {
        IP_ADAPTER_ADDRESSES *resized =
            (IP_ADAPTER_ADDRESSES *)realloc(adapters, size);
        if (!resized) {
            free(adapters);
            return 0;
        }
        adapters = resized;
        result = GetAdaptersAddresses(AF_INET,
                                      GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST |
                                      GAA_FLAG_SKIP_DNS_SERVER,
                                      NULL, adapters, &size);
    }

    if (result != NO_ERROR) {
        free(adapters);
        return 0;
    }

    for (IP_ADAPTER_ADDRESSES *adapter = adapters;
         adapter && count < max_count; adapter = adapter->Next) {
        if (adapter->OperStatus != IfOperStatusUp) continue;
        if (adapter->IfType == IF_TYPE_SOFTWARE_LOOPBACK) continue;
        for (IP_ADAPTER_UNICAST_ADDRESS *unicast = adapter->FirstUnicastAddress;
             unicast && count < max_count; unicast = unicast->Next) {
            if (!unicast->Address.lpSockaddr ||
                unicast->Address.lpSockaddr->sa_family != AF_INET) continue;
            uint32_t ip =
                ((struct sockaddr_in *)unicast->Address.lpSockaddr)->sin_addr.s_addr;
            if (ip == 0 || (ntohl(ip) >> 24) == 127) continue;
            out[count++] = ip;
        }
    }
    free(adapters);
#else
    struct ifaddrs *list = NULL;
    if (getifaddrs(&list) != 0) return 0;
    for (struct ifaddrs *entry = list; entry && count < max_count;
         entry = entry->ifa_next) {
        if (!entry->ifa_addr || entry->ifa_addr->sa_family != AF_INET) continue;
        if (!(entry->ifa_flags & IFF_UP)) continue;
        if (entry->ifa_flags & IFF_LOOPBACK) continue;
        uint32_t ip = ((struct sockaddr_in *)entry->ifa_addr)->sin_addr.s_addr;
        if (ip == 0) continue;
        out[count++] = ip;
    }
    freeifaddrs(list);
#endif

    return count;
}

static int iface_listed(const uint32_t *list, int count, uint32_t ip)
{
    for (int i = 0; i < count; i++) {
        if (list[i] == ip) return 1;
    }
    return 0;
}

/** Join or leave the mDNS multicast group on one interface. */
static void set_group_membership(int sock, uint32_t iface_ip, int join)
{
    struct ip_mreq mreq;
    mreq.imr_multiaddr.s_addr = inet_addr(MDNS_ADDR);
    mreq.imr_interface.s_addr = iface_ip;
    setsockopt(sock, IPPROTO_IP, join ? IP_ADD_MEMBERSHIP : IP_DROP_MEMBERSHIP,
               (const char *)&mreq, sizeof(mreq));
}

/**
 * Re-read the interface list, joining the group on interfaces that appeared
 * and leaving it on ones that went away. Returns the number of newly added
 * interfaces so the caller can announce on them.
 */
static int refresh_interfaces(dnssd_t *dnssd)
{
    uint32_t found[MAX_MDNS_IFACES];
    int count = enumerate_local_ipv4(found, MAX_MDNS_IFACES);
    int added = 0;

    if (count == 0) {
        /* Enumeration unavailable; fall back to the routing-table guess. */
        uint32_t fallback = get_local_ip();
        if (fallback) {
            found[0] = fallback;
            count = 1;
        }
    }

    MUTEX_LOCK(dnssd->iface_lock);
    if (dnssd->mdns_sock >= 0) {
        for (int i = 0; i < count; i++) {
            if (!iface_listed(dnssd->ifaces, dnssd->iface_count, found[i])) {
                set_group_membership(dnssd->mdns_sock, found[i], 1);
                added++;
            }
        }
        for (int i = 0; i < dnssd->iface_count; i++) {
            if (!iface_listed(found, count, dnssd->ifaces[i])) {
                set_group_membership(dnssd->mdns_sock, dnssd->ifaces[i], 0);
            }
        }
    }
    if (count > 0) {
        memcpy(dnssd->ifaces, found, (size_t)count * sizeof(uint32_t));
    }
    dnssd->iface_count = count;
    MUTEX_UNLOCK(dnssd->iface_lock);

    return added;
}

/** Create and bind the mDNS multicast socket. */
static int create_mdns_socket(void)
{
    int sock = (int)socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock < 0) return -1;

    /* Allow multiple listeners on the same port */
    int reuse = 1;
    setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, (const char *)&reuse, sizeof(reuse));

    /* Bind to INADDR_ANY:5353 */
    struct sockaddr_in bind_addr;
    memset(&bind_addr, 0, sizeof(bind_addr));
    bind_addr.sin_family = AF_INET;
    bind_addr.sin_port = htons(MDNS_PORT);
    bind_addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(sock, (struct sockaddr *)&bind_addr, sizeof(bind_addr)) < 0) {
        CLOSESOCKET(sock);
        return -1;
    }

    /* Group membership is per interface and set up by refresh_interfaces(). */

    /* Set TTL to 255 (required by mDNS spec) */
    int ttl = 255;
    setsockopt(sock, IPPROTO_IP, IP_MULTICAST_TTL, (const char *)&ttl, sizeof(ttl));

    /* Disable loopback of our own multicast packets */
    int loop = 0;
    setsockopt(sock, IPPROTO_IP, IP_MULTICAST_LOOP, (const char *)&loop, sizeof(loop));

    return sock;
}

/** Send a packet to the mDNS multicast group. */
static void mdns_send(int sock, const uint8_t *pkt, int pkt_len)
{
    struct sockaddr_in dest;
    memset(&dest, 0, sizeof(dest));
    dest.sin_family = AF_INET;
    dest.sin_port = htons(MDNS_PORT);
    dest.sin_addr.s_addr = inet_addr(MDNS_ADDR);
    sendto(sock, (const char *)pkt, pkt_len, 0,
           (struct sockaddr *)&dest, sizeof(dest));
}

/**
 * Send a response on every advertised interface, each carrying that
 * interface's own A record.
 *
 * iface_lock is held for the whole loop: IP_MULTICAST_IF is socket-wide state,
 * so a concurrent send from another thread would otherwise be able to redirect
 * a packet to the wrong link between the setsockopt and the sendto.
 */
static void mdns_respond(dnssd_t *dnssd, mdns_service_t *svc,
                         txt_record_t *txt_rec, int query_type,
                         int ttl_override)
{
    uint8_t pkt[MDNS_BUF_SIZE];

    MUTEX_LOCK(dnssd->iface_lock);
    for (int i = 0; i < dnssd->iface_count; i++) {
        int len = build_mdns_response(dnssd, svc, txt_rec, query_type,
                                      pkt, sizeof(pkt), ttl_override,
                                      dnssd->ifaces[i]);
        if (len <= 0) continue;
        setsockopt(dnssd->mdns_sock, IPPROTO_IP, IP_MULTICAST_IF,
                   (const char *)&dnssd->ifaces[i], sizeof(uint32_t));
        mdns_send(dnssd->mdns_sock, pkt, len);
    }
    MUTEX_UNLOCK(dnssd->iface_lock);
}

/* ------------------------------------------------------------------ */
/*  Case-insensitive string comparison for DNS names                   */
/* ------------------------------------------------------------------ */

static int dns_name_eq(const char *a, const char *b)
{
#ifdef WIN32
    return _stricmp(a, b) == 0;
#else
    return strcasecmp(a, b) == 0;
#endif
}

/* ------------------------------------------------------------------ */
/*  mDNS query processing                                              */
/* ------------------------------------------------------------------ */

/**
 * Check if a query name matches a service and determine the response type.
 * Returns the query_type to use for build_mdns_response, or 0 if no match.
 * Sets *out_svc and *out_txt to the matching service.
 */
static int match_query(dnssd_t *dnssd, const char *qname, uint16_t qtype,
                       mdns_service_t **out_svc, txt_record_t **out_txt)
{
    char type_fqdn[MAX_SERVNAME];
    char inst_fqdn[MAX_SERVNAME];
    char host_fqdn[256];

    snprintf(host_fqdn, sizeof(host_fqdn), "%s.local", dnssd->hostname);

    /* Check both services */
    mdns_service_t *services[2] = { &dnssd->raop_service, &dnssd->airplay_service };
    txt_record_t *txt_recs[2] = { &dnssd->raop_record, &dnssd->airplay_record };

    for (int i = 0; i < 2; i++) {
        if (!services[i]->active) continue;

        build_type_fqdn(services[i], type_fqdn, sizeof(type_fqdn));
        build_fqsn(services[i], inst_fqdn, sizeof(inst_fqdn));

        /* PTR query for service type */
        if ((qtype == DNS_TYPE_PTR || qtype == DNS_TYPE_ANY) &&
            dns_name_eq(qname, type_fqdn)) {
            *out_svc = services[i];
            *out_txt = txt_recs[i];
            return DNS_TYPE_PTR;
        }

        /* SRV query for instance */
        if ((qtype == DNS_TYPE_SRV || qtype == DNS_TYPE_ANY) &&
            dns_name_eq(qname, inst_fqdn)) {
            *out_svc = services[i];
            *out_txt = txt_recs[i];
            return DNS_TYPE_SRV;
        }

        /* TXT query for instance */
        if ((qtype == DNS_TYPE_TXT || qtype == DNS_TYPE_ANY) &&
            dns_name_eq(qname, inst_fqdn)) {
            *out_svc = services[i];
            *out_txt = txt_recs[i];
            return DNS_TYPE_TXT;
        }
    }

    /* A query for our hostname */
    if ((qtype == DNS_TYPE_A || qtype == DNS_TYPE_ANY) &&
        dns_name_eq(qname, host_fqdn)) {
        /* Use whichever active service for context (we just need dnssd for IP) */
        for (int i = 0; i < 2; i++) {
            if (services[i]->active) {
                *out_svc = services[i];
                *out_txt = txt_recs[i];
                return DNS_TYPE_A;
            }
        }
    }

    return 0;
}

/**
 * Process an incoming mDNS packet. If it contains queries we can answer,
 * send responses.
 */
static void process_mdns_packet(dnssd_t *dnssd, const uint8_t *pkt, int pkt_len)
{
    if (pkt_len < 12) return;

    uint16_t flags = read_u16(pkt + 2);
    /* Only process queries (QR bit = 0) */
    if (flags & 0x8000) return;

    uint16_t qdcount = read_u16(pkt + 4);
    if (qdcount == 0 || qdcount > 16) return;

    int offset = 12;
    char qname[MAX_SERVNAME];

    for (uint16_t i = 0; i < qdcount && offset < pkt_len; i++) {
        int next = dns_name_decode(pkt, pkt_len, offset, qname, sizeof(qname));
        if (next < 0 || next + 4 > pkt_len) break;

        uint16_t qtype = read_u16(pkt + next);
        /* uint16_t qclass = read_u16(pkt + next + 2); -- not needed */
        offset = next + 4;

        mdns_service_t *svc = NULL;
        txt_record_t *txt = NULL;

        MUTEX_LOCK(dnssd->lock);
        int resp_type = match_query(dnssd, qname, qtype, &svc, &txt);
        if (resp_type > 0 && svc && txt) {
            mdns_respond(dnssd, svc, txt, resp_type, TTL_USE_DEFAULT);
        }
        MUTEX_UNLOCK(dnssd->lock);
    }
}

/* ------------------------------------------------------------------ */
/*  mDNS responder thread                                              */
/* ------------------------------------------------------------------ */

/** Send announcement packets for a service. */
static void announce_service(dnssd_t *dnssd, mdns_service_t *svc, txt_record_t *txt)
{
    for (int i = 0; i < ANNOUNCE_COUNT; i++) {
        mdns_respond(dnssd, svc, txt, DNS_TYPE_PTR, TTL_USE_DEFAULT);
        if (i < ANNOUNCE_COUNT - 1) {
            sleepms(ANNOUNCE_INTERVAL_MS);
        }
    }
}

/** Send goodbye packet for a service, TTL 0, so clients flush the records. */
static void goodbye_service(dnssd_t *dnssd, mdns_service_t *svc, txt_record_t *txt)
{
    mdns_respond(dnssd, svc, txt, DNS_TYPE_PTR, 0);
}

/** Re-announce every active service, e.g. after a new interface appears. */
static void announce_active_services(dnssd_t *dnssd)
{
    MUTEX_LOCK(dnssd->lock);
    int raop_active = dnssd->raop_service.active;
    int airplay_active = dnssd->airplay_service.active;
    if (raop_active) {
        mdns_respond(dnssd, &dnssd->raop_service, &dnssd->raop_record,
                     DNS_TYPE_PTR, TTL_USE_DEFAULT);
    }
    if (airplay_active) {
        mdns_respond(dnssd, &dnssd->airplay_service, &dnssd->airplay_record,
                     DNS_TYPE_PTR, TTL_USE_DEFAULT);
    }
    MUTEX_UNLOCK(dnssd->lock);
}

static THREAD_RETVAL mdns_thread_func(void *arg)
{
    dnssd_t *dnssd = (dnssd_t *)arg;
    uint8_t buf[MDNS_BUF_SIZE];
    int seconds_since_refresh = 0;

    while (dnssd->mdns_running) {
        fd_set fds;
        struct timeval tv;
        tv.tv_sec = 1;
        tv.tv_usec = 0;

        FD_ZERO(&fds);
        FD_SET((unsigned int)dnssd->mdns_sock, &fds);

        int ret = select(dnssd->mdns_sock + 1, &fds, NULL, NULL, &tv);

        if (++seconds_since_refresh >= IFACE_REFRESH_INTERVAL_S) {
            seconds_since_refresh = 0;
            /* Announce on links that just came up, so clients there do not
             * have to wait for their next query to find the receiver. */
            if (refresh_interfaces(dnssd) > 0) {
                announce_active_services(dnssd);
            }
        }

        if (ret <= 0) continue;

        struct sockaddr_in from;
        socklen_t from_len = sizeof(from);
        int n = recvfrom(dnssd->mdns_sock, (char *)buf, sizeof(buf), 0,
                         (struct sockaddr *)&from, &from_len);
        if (n > 0) {
            process_mdns_packet(dnssd, buf, n);
        }
    }

    return NULL;
}

/** Start the mDNS responder thread (called on first service registration). */
static int start_mdns_responder(dnssd_t *dnssd)
{
    if (dnssd->mdns_running) return 0;

    /* Build a hostname from the service name */
    snprintf(dnssd->hostname, sizeof(dnssd->hostname), "%s", dnssd->name);
    /* Sanitize: replace spaces and special chars with hyphens */
    for (char *p = dnssd->hostname; *p; p++) {
        if (*p == ' ' || *p == '\'' || *p == '\"' || *p == '/' || *p == '\\')
            *p = '-';
    }

    dnssd->mdns_sock = create_mdns_socket();
    if (dnssd->mdns_sock < 0) {
        fprintf(stderr, "embedded mDNS: failed to create multicast socket\n");
        return -1;
    }

    if (refresh_interfaces(dnssd) == 0) {
        fprintf(stderr, "embedded mDNS: no usable IPv4 interface found\n");
        CLOSESOCKET(dnssd->mdns_sock);
        dnssd->mdns_sock = -1;
        return -1;
    }

    dnssd->mdns_running = 1;
    THREAD_CREATE(dnssd->mdns_thread, mdns_thread_func, dnssd);
    if (!dnssd->mdns_thread) {
        fprintf(stderr, "embedded mDNS: failed to create responder thread\n");
        dnssd->mdns_running = 0;
        CLOSESOCKET(dnssd->mdns_sock);
        dnssd->mdns_sock = -1;
        return -1;
    }

    fprintf(stdout, "embedded mDNS: responder started (hostname: %s.local)\n",
            dnssd->hostname);
    MUTEX_LOCK(dnssd->iface_lock);
    for (int i = 0; i < dnssd->iface_count; i++) {
        struct in_addr addr;
        addr.s_addr = dnssd->ifaces[i];
        fprintf(stdout, "embedded mDNS: advertising on %s\n", inet_ntoa(addr));
    }
    MUTEX_UNLOCK(dnssd->iface_lock);

    return 0;
}

/** Stop the mDNS responder thread. */
static void stop_mdns_responder(dnssd_t *dnssd)
{
    if (!dnssd->mdns_running) return;

    dnssd->mdns_running = 0;
    THREAD_JOIN(dnssd->mdns_thread);

    MUTEX_LOCK(dnssd->iface_lock);
    if (dnssd->mdns_sock >= 0) {
        for (int i = 0; i < dnssd->iface_count; i++) {
            set_group_membership(dnssd->mdns_sock, dnssd->ifaces[i], 0);
        }
        CLOSESOCKET(dnssd->mdns_sock);
        dnssd->mdns_sock = -1;
    }
    dnssd->iface_count = 0;
    MUTEX_UNLOCK(dnssd->iface_lock);
}

/* ================================================================== */
/*  PUBLIC API — same signatures as dnssd.h                            */
/* ================================================================== */

dnssd_t *
dnssd_init(const char *name, int name_len, const char *hw_addr,
           int hw_addr_len, int *error, unsigned char pin_pw)
{
    if (error) *error = DNSSD_ERROR_NOERROR;

    dnssd_t *dnssd = (dnssd_t *)calloc(1, sizeof(dnssd_t));
    if (!dnssd) {
        if (error) *error = DNSSD_ERROR_OUTOFMEM;
        return NULL;
    }

    dnssd->pin_pw = pin_pw;

    char *end = NULL;
    unsigned long features = strtoul(FEATURES_1, &end, 16);
    if (!end || (features & 0xFFFFFFFF) != features) {
        free(dnssd);
        if (error) *error = DNSSD_ERROR_BADFEATURES;
        return NULL;
    }
    dnssd->features1 = (uint32_t)features;

    features = strtoul(FEATURES_2, &end, 16);
    if (!end || (features & 0xFFFFFFFF) != features) {
        free(dnssd);
        if (error) *error = DNSSD_ERROR_BADFEATURES;
        return NULL;
    }
    dnssd->features2 = (uint32_t)features;

    dnssd->name_len = name_len;
    dnssd->name = calloc(1, name_len + 1);
    if (!dnssd->name) {
        free(dnssd);
        if (error) *error = DNSSD_ERROR_OUTOFMEM;
        return NULL;
    }
    memcpy(dnssd->name, name, name_len);

    dnssd->hw_addr_len = hw_addr_len;
    dnssd->hw_addr = calloc(1, hw_addr_len);
    if (!dnssd->hw_addr) {
        free(dnssd->name);
        free(dnssd);
        if (error) *error = DNSSD_ERROR_OUTOFMEM;
        return NULL;
    }
    memcpy(dnssd->hw_addr, hw_addr, hw_addr_len);

    /* Initialize TXT records */
    txt_record_create(&dnssd->raop_record);
    txt_record_create(&dnssd->airplay_record);

    /* Initialize services */
    memset(&dnssd->raop_service, 0, sizeof(mdns_service_t));
    memset(&dnssd->airplay_service, 0, sizeof(mdns_service_t));

    /* mDNS state */
    dnssd->mdns_sock = -1;
    dnssd->mdns_running = 0;
    dnssd->mdns_thread = 0;
    dnssd->iface_count = 0;
    MUTEX_CREATE(dnssd->lock);
    MUTEX_CREATE(dnssd->iface_lock);

    return dnssd;
}

void
dnssd_destroy(dnssd_t *dnssd)
{
    if (dnssd) {
        stop_mdns_responder(dnssd);
        txt_record_deallocate(&dnssd->raop_record);
        txt_record_deallocate(&dnssd->airplay_record);
        MUTEX_DESTROY(dnssd->lock);
        MUTEX_DESTROY(dnssd->iface_lock);
        free(dnssd->name);
        free(dnssd->hw_addr);
        free(dnssd);
    }
}

int
dnssd_register_raop(dnssd_t *dnssd, unsigned short port)
{
    char servname[MAX_SERVNAME];
    char features[22] = {0};

    assert(dnssd);

    snprintf(features, sizeof(features), "0x%X,0x%X", dnssd->features1, dnssd->features2);

    /* Build TXT record */
    MUTEX_LOCK(dnssd->lock);

    txt_record_deallocate(&dnssd->raop_record);
    txt_record_create(&dnssd->raop_record);
    txt_record_set_value(&dnssd->raop_record, "ch", strlen(RAOP_CH), RAOP_CH);
    txt_record_set_value(&dnssd->raop_record, "cn", strlen(RAOP_CN), RAOP_CN);
    txt_record_set_value(&dnssd->raop_record, "da", strlen(RAOP_DA), RAOP_DA);
    txt_record_set_value(&dnssd->raop_record, "et", strlen(RAOP_ET), RAOP_ET);
    txt_record_set_value(&dnssd->raop_record, "vv", strlen(RAOP_VV), RAOP_VV);
    txt_record_set_value(&dnssd->raop_record, "ft", strlen(features), features);
    txt_record_set_value(&dnssd->raop_record, "am", strlen(GLOBAL_MODEL), GLOBAL_MODEL);
    txt_record_set_value(&dnssd->raop_record, "md", strlen(RAOP_MD), RAOP_MD);
    txt_record_set_value(&dnssd->raop_record, "rhd", strlen(RAOP_RHD), RAOP_RHD);
    switch (dnssd->pin_pw) {
    case 2:
    case 3:
        txt_record_set_value(&dnssd->raop_record, "pw", strlen("true"), "true");
        txt_record_set_value(&dnssd->raop_record, "sf", 4, "0x84");
        break;
    case 1:
        txt_record_set_value(&dnssd->raop_record, "pw", strlen("true"), "true");
        txt_record_set_value(&dnssd->raop_record, "sf", 3, "0x8c");
        break;
    default:
        txt_record_set_value(&dnssd->raop_record, "pw", strlen("false"), "false");
        txt_record_set_value(&dnssd->raop_record, "sf", strlen(RAOP_SF), RAOP_SF);
        break;
    }
    txt_record_set_value(&dnssd->raop_record, "sr", strlen(RAOP_SR), RAOP_SR);
    txt_record_set_value(&dnssd->raop_record, "ss", strlen(RAOP_SS), RAOP_SS);
    txt_record_set_value(&dnssd->raop_record, "sv", strlen(RAOP_SV), RAOP_SV);
    txt_record_set_value(&dnssd->raop_record, "tp", strlen(RAOP_TP), RAOP_TP);
    txt_record_set_value(&dnssd->raop_record, "txtvers", strlen(RAOP_TXTVERS), RAOP_TXTVERS);
    txt_record_set_value(&dnssd->raop_record, "sf", strlen(RAOP_SF), RAOP_SF);
    txt_record_set_value(&dnssd->raop_record, "vs", strlen(RAOP_VS), RAOP_VS);
    txt_record_set_value(&dnssd->raop_record, "vn", strlen(RAOP_VN), RAOP_VN);
    txt_record_set_value(&dnssd->raop_record, "pk", strlen(dnssd->pk), dnssd->pk);

    /* Build service instance name: "AABBCCDDEEFF@Name" */
    if (utils_hwaddr_raop(servname, sizeof(servname), dnssd->hw_addr, dnssd->hw_addr_len) < 0) {
        MUTEX_UNLOCK(dnssd->lock);
        return -1;
    }
    if (sizeof(servname) < strlen(servname) + 1 + dnssd->name_len + 1) {
        MUTEX_UNLOCK(dnssd->lock);
        return -2;
    }
    strncat(servname, "@", sizeof(servname) - strlen(servname) - 1);
    strncat(servname, dnssd->name, sizeof(servname) - strlen(servname) - 1);

    /* Set up service descriptor */
    strncpy(dnssd->raop_service.instance_name, servname,
            sizeof(dnssd->raop_service.instance_name) - 1);
    strncpy(dnssd->raop_service.reg_type, "_raop._tcp",
            sizeof(dnssd->raop_service.reg_type) - 1);
    dnssd->raop_service.port = port;
    dnssd->raop_service.active = 1;

    MUTEX_UNLOCK(dnssd->lock);

    /* Start responder if not already running */
    int ret = start_mdns_responder(dnssd);
    if (ret < 0) return ret;

    /* Send initial announcements */
    announce_service(dnssd, &dnssd->raop_service, &dnssd->raop_record);

    return 0;
}

int
dnssd_register_airplay(dnssd_t *dnssd, unsigned short port)
{
    char device_id[3 * MAX_HWADDR_LEN];
    char features[22] = {0};

    assert(dnssd);

    snprintf(features, sizeof(features), "0x%X,0x%X", dnssd->features1, dnssd->features2);

    if (utils_hwaddr_airplay(device_id, sizeof(device_id), dnssd->hw_addr, dnssd->hw_addr_len) < 0) {
        return -1;
    }

    MUTEX_LOCK(dnssd->lock);

    txt_record_deallocate(&dnssd->airplay_record);
    txt_record_create(&dnssd->airplay_record);
    txt_record_set_value(&dnssd->airplay_record, "deviceid", strlen(device_id), device_id);
    txt_record_set_value(&dnssd->airplay_record, "features", strlen(features), features);
    switch (dnssd->pin_pw) {
    case 1:
        txt_record_set_value(&dnssd->airplay_record, "pw", strlen("true"), "true");
        txt_record_set_value(&dnssd->airplay_record, "flags", 3, "0x4");
        break;
    case 2:
    case 3:
        txt_record_set_value(&dnssd->airplay_record, "pw", strlen("true"), "true");
        txt_record_set_value(&dnssd->airplay_record, "flags", 3, "0x4");
        break;
    default:
        txt_record_set_value(&dnssd->airplay_record, "pw", strlen("false"), "false");
        txt_record_set_value(&dnssd->airplay_record, "flags", 3, "0x4");
        break;
    }
    txt_record_set_value(&dnssd->airplay_record, "model", strlen(GLOBAL_MODEL), GLOBAL_MODEL);
    txt_record_set_value(&dnssd->airplay_record, "pk", strlen(dnssd->pk), dnssd->pk);
    txt_record_set_value(&dnssd->airplay_record, "pi", strlen(AIRPLAY_PI), AIRPLAY_PI);
    txt_record_set_value(&dnssd->airplay_record, "srcvers", strlen(AIRPLAY_SRCVERS), AIRPLAY_SRCVERS);
    txt_record_set_value(&dnssd->airplay_record, "vv", strlen(AIRPLAY_VV), AIRPLAY_VV);

    /* Set up service descriptor */
    strncpy(dnssd->airplay_service.instance_name, dnssd->name,
            sizeof(dnssd->airplay_service.instance_name) - 1);
    strncpy(dnssd->airplay_service.reg_type, "_airplay._tcp",
            sizeof(dnssd->airplay_service.reg_type) - 1);
    dnssd->airplay_service.port = port;
    dnssd->airplay_service.active = 1;

    MUTEX_UNLOCK(dnssd->lock);

    /* Start responder if not already running */
    int ret = start_mdns_responder(dnssd);
    if (ret < 0) return ret;

    /* Send initial announcements */
    announce_service(dnssd, &dnssd->airplay_service, &dnssd->airplay_record);

    return 0;
}

const char *
dnssd_get_raop_txt(dnssd_t *dnssd, int *length)
{
    *length = dnssd->raop_record.len;
    return (const char *)dnssd->raop_record.data;
}

const char *
dnssd_get_airplay_txt(dnssd_t *dnssd, int *length)
{
    *length = dnssd->airplay_record.len;
    return (const char *)dnssd->airplay_record.data;
}

const char *
dnssd_get_name(dnssd_t *dnssd, int *length)
{
    *length = dnssd->name_len;
    return dnssd->name;
}

const char *
dnssd_get_hw_addr(dnssd_t *dnssd, int *length)
{
    *length = dnssd->hw_addr_len;
    return dnssd->hw_addr;
}

void
dnssd_unregister_raop(dnssd_t *dnssd)
{
    assert(dnssd);

    if (!dnssd->raop_service.active) return;

    /* Send goodbye */
    if (dnssd->mdns_running) {
        goodbye_service(dnssd, &dnssd->raop_service, &dnssd->raop_record);
    }

    MUTEX_LOCK(dnssd->lock);
    dnssd->raop_service.active = 0;
    txt_record_deallocate(&dnssd->raop_record);
    MUTEX_UNLOCK(dnssd->lock);

    if (!dnssd->airplay_service.active) {
        stop_mdns_responder(dnssd);
        free(dnssd->name);
        dnssd->name = NULL;
        free(dnssd->hw_addr);
        dnssd->hw_addr = NULL;
    }
}

void
dnssd_unregister_airplay(dnssd_t *dnssd)
{
    assert(dnssd);

    if (!dnssd->airplay_service.active) return;

    /* Send goodbye */
    if (dnssd->mdns_running) {
        goodbye_service(dnssd, &dnssd->airplay_service, &dnssd->airplay_record);
    }

    MUTEX_LOCK(dnssd->lock);
    dnssd->airplay_service.active = 0;
    txt_record_deallocate(&dnssd->airplay_record);
    MUTEX_UNLOCK(dnssd->lock);

    if (!dnssd->raop_service.active) {
        stop_mdns_responder(dnssd);
        free(dnssd->name);
        dnssd->name = NULL;
        free(dnssd->hw_addr);
        dnssd->hw_addr = NULL;
    }
}

uint64_t dnssd_get_airplay_features(dnssd_t *dnssd)
{
    uint64_t features = ((uint64_t)dnssd->features2) << 32;
    features += (uint64_t)dnssd->features1;
    return features;
}

void dnssd_set_pk(dnssd_t *dnssd, char *pk_str)
{
    dnssd->pk = pk_str;
}

void dnssd_set_airplay_features(dnssd_t *dnssd, int bit, int val)
{
    uint32_t mask = 0;
    uint32_t *features = 0;
    if (bit < 0 || bit > 63) return;
    if (val < 0 || val > 1) return;
    if (bit >= 32) {
        mask = 0x1 << (bit - 32);
        features = &(dnssd->features2);
    } else {
        mask = 0x1 << bit;
        features = &(dnssd->features1);
    }
    if (val) {
        *features = *features | mask;
    } else {
        *features = *features & ~mask;
    }
}
