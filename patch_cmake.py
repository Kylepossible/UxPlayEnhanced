"""
Patches lib/uxplay/lib/CMakeLists.txt to add USE_EMBEDDED_MDNS support.
Run this after cloning the submodule: python patch_cmake.py
"""

import re
import os

cmake_path = os.path.join("lib", "uxplay", "lib", "CMakeLists.txt")

with open(cmake_path, "r") as f:
    content = f.read()

# 1. Add option and source file swap after aux_source_directory
old_aux = "aux_source_directory(. play_src)\nset(DIR_SRCS ${play_src})"
new_aux = """option(USE_EMBEDDED_MDNS "Use embedded mDNS responder instead of Bonjour/Avahi" OFF)

aux_source_directory(. play_src)
set(DIR_SRCS ${play_src})

if(USE_EMBEDDED_MDNS)
  # Swap dnssd.c for the embedded mDNS implementation
  list(REMOVE_ITEM DIR_SRCS ./dnssd.c)
  list(APPEND DIR_SRCS ${CMAKE_CURRENT_SOURCE_DIR}/dnssd_embedded.c)
  add_definitions(-DUSE_EMBEDDED_MDNS)
  message(STATUS "Using embedded mDNS responder (no Bonjour/Avahi required)")
endif()"""

content = content.replace(old_aux, new_aux)

# 2. Add embedded mDNS branch before the dns_sd detection block
old_dns = "#dns_sd \nif ( NOT APPLE )"
new_dns = """#dns_sd
if(USE_EMBEDDED_MDNS)
  # No external dns_sd library needed - embedded mDNS handles everything.
  # Winsock2 (ws2_32) and iphlpapi are already linked above for WIN32.
  message(STATUS "dns_sd: using embedded mDNS (no external dependency)")
elseif ( NOT APPLE )"""

# Handle both possible whitespace variants
if old_dns in content:
    content = content.replace(old_dns, new_dns)
else:
    content = content.replace("#dns_sd \r\nif ( NOT APPLE )", new_dns)
    content = content.replace("#dns_sd\nif ( NOT APPLE )", new_dns)
    content = content.replace("#dns_sd \nif ( NOT APPLE )", new_dns)

with open(cmake_path, "w") as f:
    f.write(content)

print(f"Patched {cmake_path}")
