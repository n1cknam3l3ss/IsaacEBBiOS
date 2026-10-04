#pragma once

#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <Foundation/Foundation.h>
#include <cstdint>

template <typename T>
inline bool SafeRead(uintptr_t address, T &outVal) {
    if (!address) return false;
    vm_size_t copied = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         static_cast<vm_address_t>(address),
                                         sizeof(T),
                                         reinterpret_cast<vm_address_t>(&outVal),
                                         &copied);
    return (kr == KERN_SUCCESS && copied == sizeof(T));
}

inline bool SafeReadBytes(uintptr_t address, void *outBuf, size_t size) {
    if (!address || !outBuf || !size) return false;
    vm_size_t copied = 0;
    kern_return_t kr = vm_read_overwrite(mach_task_self(),
                                         static_cast<vm_address_t>(address),
                                         size,
                                         reinterpret_cast<vm_address_t>(outBuf),
                                         &copied);
    return (kr == KERN_SUCCESS && copied == size);
}

static inline NSString *BossBarUUIDForHeader(const mach_header_64 *header) {
    if (!header || header->magic != MH_MAGIC_64 || header->ncmds > 65536 ||
        header->sizeofcmds > 64 * 1024 * 1024) return @"UNKNOWN";

    const uint8_t *cursor = reinterpret_cast<const uint8_t *>(header + 1);
    const uint8_t *end = cursor + header->sizeofcmds;
    for (uint32_t index = 0; index < header->ncmds; ++index) {
        if (cursor > end || static_cast<size_t>(end - cursor) < sizeof(load_command)) break;
        const load_command *command = reinterpret_cast<const load_command *>(cursor);
        if (command->cmdsize < sizeof(load_command) ||
            static_cast<size_t>(end - cursor) < command->cmdsize) break;
        if (command->cmd == LC_UUID && command->cmdsize >= sizeof(uuid_command)) {
            const uuid_command *uuidCommand = reinterpret_cast<const uuid_command *>(cursor);
            const unsigned char *u = uuidCommand->uuid;
            return [NSString stringWithFormat:
                    @"%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X",
                    u[0],u[1],u[2],u[3],u[4],u[5],u[6],u[7],u[8],u[9],u[10],u[11],u[12],u[13],u[14],u[15]];
        }
        cursor += command->cmdsize;
    }
    return @"UNKNOWN";
}

inline uintptr_t BossBarGetBaseAddress(void) {
    static uintptr_t cachedBase = 0;
    if (cachedBase) return cachedBase;

    uint32_t count = _dyld_image_count();

    // 1. LiveContainer guest matching by verified Isaac Repentance iOS UUID
    for (uint32_t i = 0; i < count; ++i) {
        const mach_header_64 *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        NSString *uuid = BossBarUUIDForHeader(header);
        if ([uuid caseInsensitiveCompare:@"F4357753-A25F-30EE-BACF-63709F902895"] == NSOrderedSame) {
            cachedBase = reinterpret_cast<uintptr_t>(header);
            return cachedBase;
        }
    }

    // 2. Search by image name containing Isaac / com.Nicalis
    for (uint32_t i = 0; i < count; ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        NSString *nameStr = [NSString stringWithUTF8String:name];
        if ([nameStr containsString:@"com.Nicalis.Isaac"] ||
            [nameStr containsString:@"TheBindingOfIsaac"] ||
            [nameStr.lastPathComponent containsString:@"Isaac"]) {
            const mach_header_64 *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
            if (header && header->magic == MH_MAGIC_64) {
                cachedBase = reinterpret_cast<uintptr_t>(header);
                return cachedBase;
            }
        }
    }

    // 3. Fallback to main executable if running standalone (not LiveContainer)
    for (uint32_t i = 0; i < count; ++i) {
        const mach_header_64 *header = reinterpret_cast<const mach_header_64 *>(_dyld_get_image_header(i));
        if (header && header->magic == MH_MAGIC_64 && header->filetype == MH_EXECUTE) {
            cachedBase = reinterpret_cast<uintptr_t>(header);
            return cachedBase;
        }
    }

    return 0;
}
