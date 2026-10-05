#pragma once

#import <Foundation/Foundation.h>
#import <vector>
#import <string>
#import <cstdint>

struct BossDebugInfo {
    uintptr_t entityPtr;
    int32_t type;
    int32_t variant;
    std::string name;
    float currentHP;
    float maxHP;
    uint64_t flags560;
    uint64_t flags1b8;
    uint8_t memoryChunk540[64]; // entity + 0x540 to 0x580
};

#ifdef __cplusplus
extern "C" {
#endif

// Start background server on port 8765
void BossBarDebugServerStart(void);

// Stop background server
void BossBarDebugServerStop(void);

// Returns detected local Wi-Fi IP address (e.g. "192.168.0.123")
NSString *BossBarDebugServerGetLocalIP(void);

// Called every tick from BossBarController with current boss snapshot
void BossBarDebugServerUpdate(const std::vector<BossDebugInfo> &bosses, int32_t stage, int32_t roomType);

#ifdef __cplusplus
}
#endif
