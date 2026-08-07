"""
Patches the UxPlay submodule for embedded mDNS, readable audio-quality logs,
and de-duplicated audio metadata output.
Run this after cloning the submodule: python patch_cmake.py
"""

import re
import os

cmake_path = os.path.join("lib", "uxplay", "lib", "CMakeLists.txt")
uxplay_path = os.path.join("lib", "uxplay", "uxplay.cpp")

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

if 'option(USE_EMBEDDED_MDNS' not in content:
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

with open(uxplay_path, "r") as f:
    uxplay_content = f.read()

# 3. Add readable audio codec/resolution logging. The receiver profile in
# this fork is currently fixed at 16-bit/44.1 kHz; the log must say so rather
# than implying that an encoded ALAC bitrate was measured.
if "AIRPLAY_AUDIO_SAMPLE_RATE" not in uxplay_content:
    old_constants = "#define DEFAULT_PLAYBIN_VERSION 3\n"
    new_constants = """#define DEFAULT_PLAYBIN_VERSION 3
#define AIRPLAY_AUDIO_SAMPLE_RATE 44100U
#define AIRPLAY_AUDIO_BIT_DEPTH 16U
#define AIRPLAY_AUDIO_CHANNELS 2U
"""
    if old_constants not in uxplay_content:
        raise RuntimeError("Could not find UxPlay audio constants insertion point")
    uxplay_content = uxplay_content.replace(old_constants, new_constants, 1)

if "static const char *audio_codec_name" not in uxplay_content:
    old_audio_function = """extern \"C\" void audio_get_format (void *cls, unsigned char *ct, unsigned short *spf, bool *usingScreen, bool *isMedia, uint64_t *audioFormat) {
    unsigned char type;
    LOGI(\"ct=%d spf=%d usingScreen=%d isMedia=%d  audioFormat=0x%lx\",*ct, *spf, *usingScreen, *isMedia, (unsigned long) *audioFormat);
"""
    new_audio_function = """static const char *audio_codec_name(unsigned char ct) {
    switch (ct) {
    case 2:
        return \"ALAC\";
    case 8:
        return \"AAC-ELD\";
    case 4:
        return \"AAC-Main\";
    default:
        return \"unknown\";
    }
}

static const char *audio_quality_name(unsigned char ct, unsigned int sample_rate) {
    if (ct != 2) {
        return ct == 8 || ct == 4 ? \"Lossy\" : \"Unknown\";
    }
    return sample_rate > 48000U ? \"Hi-Res Lossless\" : \"Lossless\";
}

static void log_audio_quality(unsigned char ct, unsigned short spf, uint64_t audio_format) {
    const uint64_t pcm_bitrate_kbps =
        ((uint64_t) AIRPLAY_AUDIO_SAMPLE_RATE * AIRPLAY_AUDIO_BIT_DEPTH * AIRPLAY_AUDIO_CHANNELS + 500U) / 1000U;

    LOGI(\"audio quality: codec=%s (ct=%u); quality=%s; resolution=%u-bit/%u Hz; channels=%u; \"
         \"equivalent PCM bitrate=%\" PRIu64 \" kbps; spf=%u; audioFormat=0x%016\" PRIx64,
         audio_codec_name(ct), (unsigned int) ct,
         audio_quality_name(ct, AIRPLAY_AUDIO_SAMPLE_RATE),
         AIRPLAY_AUDIO_BIT_DEPTH, AIRPLAY_AUDIO_SAMPLE_RATE, AIRPLAY_AUDIO_CHANNELS,
         pcm_bitrate_kbps, (unsigned int) spf, audio_format);
    LOGI(\"audio quality note: AirPlay receiver profile is fixed at %u-bit/%u Hz; encoded bitrate is not exposed\",
         AIRPLAY_AUDIO_BIT_DEPTH, AIRPLAY_AUDIO_SAMPLE_RATE);
}

extern \"C\" void audio_get_format (void *cls, unsigned char *ct, unsigned short *spf, bool *usingScreen, bool *isMedia, uint64_t *audioFormat) {
    unsigned char type;
    LOGI(\"ct=%d spf=%d usingScreen=%d isMedia=%d  audioFormat=0x%lx\",*ct, *spf, *usingScreen, *isMedia, (unsigned long) *audioFormat);
    log_audio_quality(*ct, *spf, *audioFormat);
"""
    if old_audio_function not in uxplay_content:
        raise RuntimeError("Could not find UxPlay audio logging insertion point")
    uxplay_content = uxplay_content.replace(old_audio_function, new_audio_function, 1)

# 4. De-duplicate unchanged DMAP metadata blocks in the console. The iPhone
# can resend the same metadata while playback continues; keep -md file output
# unchanged, but print a block only when its text differs from the last one.
if "last_audio_metadata_text" not in uxplay_content:
    old_metadata_global = 'static std::string metadata_filename = "";\n'
    new_metadata_global = old_metadata_global + 'static std::string last_audio_metadata_text = "";\n'
    if old_metadata_global not in uxplay_content:
        raise RuntimeError("Could not find UxPlay metadata cache insertion point")
    uxplay_content = uxplay_content.replace(old_metadata_global, new_metadata_global, 1)

if "last_audio_metadata_text.clear();" not in uxplay_content:
    old_audio_reset = "    log_audio_quality(*ct, *spf, *audioFormat);\n"
    new_audio_reset = old_audio_reset + "    last_audio_metadata_text.clear();\n"
    if old_audio_reset not in uxplay_content:
        raise RuntimeError("Could not find UxPlay metadata cache reset point")
    uxplay_content = uxplay_content.replace(old_audio_reset, new_audio_reset, 1)

metadata_header = '    printf("====================Audio Metadata==================\\n");\n\n'
if metadata_header in uxplay_content:
    uxplay_content = uxplay_content.replace(metadata_header, "", 1)

if "if (!metadata_text.empty() && metadata_text != last_audio_metadata_text)" not in uxplay_content:
    old_metadata_log = '    LOGI("%s", metadata_text.c_str());\n'
    new_metadata_log = """    if (!metadata_text.empty() && metadata_text != last_audio_metadata_text) {
        printf("====================Audio Metadata==================\\n");
        LOGI("%s", metadata_text.c_str());
        last_audio_metadata_text = metadata_text;
    }
"""
    if old_metadata_log not in uxplay_content:
        raise RuntimeError("Could not find UxPlay metadata log insertion point")
    uxplay_content = uxplay_content.replace(old_metadata_log, new_metadata_log, 1)

with open(uxplay_path, "w") as f:
    f.write(uxplay_content)

print(f"Patched {cmake_path}")
