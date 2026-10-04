#pragma once

#import <mach/mach.h>
#import <mach/vm_map.h>
#import <mach-o/dyld.h>
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

inline uintptr_t BossBarGetBaseAddress(void) {
    uint32_t count = _dyld_image_count();
    for (uint32_t i = 0; i < count; ++i) {
        const char *name = _dyld_get_image_name(i);
        if (!name) continue;
        const struct mach_header_64 *header = reinterpret_cast<const struct mach_header_64 *>(_dyld_get_image_header(i));
        if (header && header->magic == MH_MAGIC_64 && header->filetype == MH_EXECUTE) {
            return reinterpret_cast<uintptr_t>(header);
        }
    }
    return 0;
}
