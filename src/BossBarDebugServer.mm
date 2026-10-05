#import "BossBarDebugServer.h"
#import "BossBarLogger.h"
#import <sys/socket.h>
#import <netinet/in.h>
#import <arpa/inet.h>
#import <unistd.h>
#import <fcntl.h>
#import <ifaddrs.h>
#import <mutex>
#import <vector>
#import <string>
#import <sstream>
#import <iomanip>
#import <chrono>

static int g_serverSocket = -1;
static dispatch_queue_t g_serverQueue = nil;
static std::mutex g_stateMutex;

struct DebugEvent {
    double timestamp;
    std::string text;
};

static std::vector<BossDebugInfo> g_lastBosses;
static std::vector<DebugEvent> g_recentEvents;
static int32_t g_lastStage = 0;
static int32_t g_lastRoomType = 0;
static double g_serverStartTime = 0.0;

static double GetCurrentTimeSeconds(void) {
    return [[NSDate date] timeIntervalSince1970];
}

NSString *BossBarDebugServerGetLocalIP(void) {
    struct ifaddrs *interfaces = nullptr;
    if (getifaddrs(&interfaces) != 0 || !interfaces) return @"127.0.0.1";

    NSString *wifiIP = nil;
    for (struct ifaddrs *ifa = interfaces; ifa != nullptr; ifa = ifa->ifa_next) {
        if (!ifa->ifa_addr || ifa->ifa_addr->sa_family != AF_INET) continue;
        NSString *name = [NSString stringWithUTF8String:ifa->ifa_name];
        if ([name isEqualToString:@"en0"] || [name isEqualToString:@"en1"]) {
            char ipBuf[INET_ADDRSTRLEN] = {0};
            auto *addrIn = reinterpret_cast<struct sockaddr_in *>(ifa->ifa_addr);
            if (inet_ntop(AF_INET, &addrIn->sin_addr, ipBuf, sizeof(ipBuf))) {
                wifiIP = [NSString stringWithUTF8String:ipBuf];
                break;
            }
        }
    }
    freeifaddrs(interfaces);
    return wifiIP ? wifiIP : @"127.0.0.1";
}

static void AppendEvent(const std::string &msg) {
    DebugEvent ev;
    ev.timestamp = GetCurrentTimeSeconds() - g_serverStartTime;
    ev.text = msg;
    g_recentEvents.push_back(ev);
    if (g_recentEvents.size() > 500) {
        g_recentEvents.erase(g_recentEvents.begin(), g_recentEvents.begin() + 100);
    }

    // Also write to Documents/boss_debug.log
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count > 0) {
        NSString *docDir = paths.firstObject;
        NSString *logPath = [docDir stringByAppendingPathComponent:@"boss_debug.log"];
        NSString *line = [NSString stringWithFormat:@"[+%.2fs] %s\n", ev.timestamp, msg.c_str()];
        NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:logPath];
        if (!handle) {
            [[line dataUsingEncoding:NSUTF8StringEncoding] writeToFile:logPath atomically:YES];
        } else {
            [handle seekToEndOfFile];
            [handle writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [handle closeFile];
        }
    }
}

void BossBarDebugServerUpdate(const std::vector<BossDebugInfo> &bosses, int32_t stage, int32_t roomType) {
    std::lock_guard<std::mutex> lock(g_stateMutex);
    g_lastStage = stage;
    g_lastRoomType = roomType;

    // Detect deltas against last state
    for (const auto &b : bosses) {
        const BossDebugInfo *prev = nullptr;
        for (const auto &p : g_lastBosses) {
            if (p.entityPtr == b.entityPtr) {
                prev = &p;
                break;
            }
        }

        if (prev) {
            // Check flags 0x560 delta
            if (b.flags560 != prev->flags560) {
                uint64_t added = b.flags560 & ~prev->flags560;
                uint64_t removed = prev->flags560 & ~b.flags560;

                std::ostringstream ss;
                ss << "[FLAG 0x560 CHANGE] " << b.name << " (HP: " << std::fixed << std::setprecision(1) << b.currentHP
                   << "/" << b.maxHP << ") 0x560: 0x" << std::hex << std::setfill('0') << std::setw(16) << prev->flags560
                   << " -> 0x" << std::setw(16) << b.flags560 << std::dec;

                if (added) {
                    ss << " [ADDED BITS:";
                    for (int bit = 0; bit < 64; ++bit) {
                        if (added & (1ULL << bit)) ss << " " << bit;
                    }
                    ss << "]";
                }
                if (removed) {
                    ss << " [REMOVED BITS:";
                    for (int bit = 0; bit < 64; ++bit) {
                        if (removed & (1ULL << bit)) ss << " " << bit;
                    }
                    ss << "]";
                }
                AppendEvent(ss.str());
                BossBarLog(@"%s", ss.str().c_str());
            }

            // Check flags 0x1B8 delta
            if (b.flags1b8 != prev->flags1b8) {
                std::ostringstream ss;
                ss << "[FLAG 0x1B8 CHANGE] " << b.name << " 0x1B8: 0x" << std::hex << std::setfill('0') << std::setw(16)
                   << prev->flags1b8 << " -> 0x" << std::setw(16) << b.flags1b8 << std::dec;
                AppendEvent(ss.str());
                BossBarLog(@"%s", ss.str().c_str());
            }

            // Check HP damage
            if (b.currentHP < prev->currentHP - 0.05f) {
                float dmg = prev->currentHP - b.currentHP;
                std::ostringstream ss;
                ss << "[HIT] " << b.name << " took " << std::fixed << std::setprecision(1) << dmg
                   << " dmg (HP: " << b.currentHP << ") 0x560: 0x" << std::hex << std::setfill('0') << std::setw(16)
                   << b.flags560 << std::dec;
                AppendEvent(ss.str());
            }
        } else {
            // New boss entered
            std::ostringstream ss;
            ss << "[BOSS SPAWN/ENTER] " << b.name << " Type=" << b.type << "." << b.variant
               << " HP=" << std::fixed << std::setprecision(1) << b.currentHP << "/" << b.maxHP
               << " Initial 0x560=0x" << std::hex << std::setfill('0') << std::setw(16) << b.flags560
               << " 0x1B8=0x" << std::setw(16) << b.flags1b8 << std::dec;
            AppendEvent(ss.str());
            BossBarLog(@"%s", ss.str().c_str());
        }
    }

    g_lastBosses = bosses;
}

static void HandleClient(int clientFd) {
    char reqBuf[2048] = {0};
    ssize_t n = read(clientFd, reqBuf, sizeof(reqBuf) - 1);
    if (n <= 0) {
        close(clientFd);
        return;
    }

    std::string request(reqBuf);
    std::string path = "/";
    size_t firstSpace = request.find(' ');
    if (firstSpace != std::string::npos) {
        size_t secondSpace = request.find(' ', firstSpace + 1);
        if (secondSpace != std::string::npos) {
            path = request.substr(firstSpace + 1, secondSpace - firstSpace - 1);
        }
    }

    std::ostringstream respBody;
    std::string contentType = "application/json";

    if (path == "/log" || path == "/events") {
        contentType = "text/plain; charset=utf-8";
        std::lock_guard<std::mutex> lock(g_stateMutex);
        respBody << "=== Isaac Enhanced Boss Bars Live Event Log ===\n";
        respBody << "Stage: " << g_lastStage << " | RoomType: " << g_lastRoomType
                 << " | Active Bosses: " << g_lastBosses.size() << "\n\n";
        for (const auto &ev : g_recentEvents) {
            respBody << "[+" << std::fixed << std::setprecision(2) << ev.timestamp << "s] " << ev.text << "\n";
        }
    } else if (path == "/clear") {
        std::lock_guard<std::mutex> lock(g_stateMutex);
        g_recentEvents.clear();
        respBody << "{\"status\":\"cleared\"}\n";
    } else {
        // JSON status
        std::lock_guard<std::mutex> lock(g_stateMutex);
        respBody << "{\n";
        respBody << "  \"uptime_seconds\": " << (GetCurrentTimeSeconds() - g_serverStartTime) << ",\n";
        respBody << "  \"stage\": " << g_lastStage << ",\n";
        respBody << "  \"room_type\": " << g_lastRoomType << ",\n";
        respBody << "  \"boss_count\": " << g_lastBosses.size() << ",\n";
        respBody << "  \"bosses\": [\n";

        for (size_t i = 0; i < g_lastBosses.size(); ++i) {
            const auto &b = g_lastBosses[i];
            respBody << "    {\n";
            respBody << "      \"name\": \"" << b.name << "\",\n";
            respBody << "      \"type\": " << b.type << ",\n";
            respBody << "      \"variant\": " << b.variant << ",\n";
            respBody << "      \"hp\": " << std::fixed << std::setprecision(1) << b.currentHP << ",\n";
            respBody << "      \"max_hp\": " << b.maxHP << ",\n";

            std::ostringstream s560, s1b8;
            s560 << "0x" << std::hex << std::setfill('0') << std::setw(16) << b.flags560;
            s1b8 << "0x" << std::hex << std::setfill('0') << std::setw(16) << b.flags1b8;
            respBody << "      \"flags_0x560\": \"" << s560.str() << "\",\n";
            respBody << "      \"flags_0x1b8\": \"" << s1b8.str() << "\",\n";

            // Active bit indices in 0x560
            respBody << "      \"active_bits_0x560\": [";
            bool firstBit = true;
            for (int bit = 0; bit < 64; ++bit) {
                if (b.flags560 & (1ULL << bit)) {
                    if (!firstBit) respBody << ", ";
                    respBody << bit;
                    firstBit = false;
                }
            }
            respBody << "],\n";

            // Memory snapshot 0x540 (64 bytes hex)
            respBody << "      \"memory_0x540_hex\": \"";
            for (int m = 0; m < 64; ++m) {
                respBody << std::hex << std::setfill('0') << std::setw(2) << (int)b.memoryChunk540[m];
            }
            respBody << std::dec << "\"\n";
            respBody << "    }" << (i + 1 < g_lastBosses.size() ? "," : "") << "\n";
        }
        respBody << "  ],\n";

        // Last 15 events
        respBody << "  \"recent_events\": [\n";
        size_t startIdx = (g_recentEvents.size() > 20) ? g_recentEvents.size() - 20 : 0;
        for (size_t i = startIdx; i < g_recentEvents.size(); ++i) {
            respBody << "    \"[+" << std::fixed << std::setprecision(2) << g_recentEvents[i].timestamp << "s] "
                     << g_recentEvents[i].text << "\"" << (i + 1 < g_recentEvents.size() ? "," : "") << "\n";
        }
        respBody << "  ]\n";
        respBody << "}\n";
    }

    std::string body = respBody.str();
    std::ostringstream header;
    header << "HTTP/1.1 200 OK\r\n";
    header << "Content-Type: " << contentType << "\r\n";
    header << "Content-Length: " << body.size() << "\r\n";
    header << "Access-Control-Allow-Origin: *\r\n";
    header << "Connection: close\r\n\r\n";

    std::string full = header.str() + body;
    write(clientFd, full.data(), full.size());
    close(clientFd);
}

void BossBarDebugServerStart(void) {
    if (g_serverSocket >= 0) return;

    g_serverStartTime = GetCurrentTimeSeconds();
    g_serverSocket = socket(AF_INET, SOCK_STREAM, 0);
    if (g_serverSocket < 0) {
        BossBarLog(@"[DebugServer] Failed to create socket: %d", errno);
        return;
    }

    int opt = 1;
    setsockopt(g_serverSocket, SOL_SOCKET, SO_REUSEADDR, &opt, sizeof(opt));

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(8765);
    addr.sin_addr.s_addr = htonl(INADDR_ANY);

    if (bind(g_serverSocket, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        BossBarLog(@"[DebugServer] Failed to bind to port 8765: %d", errno);
        close(g_serverSocket);
        g_serverSocket = -1;
        return;
    }

    if (listen(g_serverSocket, 5) != 0) {
        BossBarLog(@"[DebugServer] Failed to listen: %d", errno);
        close(g_serverSocket);
        g_serverSocket = -1;
        return;
    }

    NSString *ip = BossBarDebugServerGetLocalIP();
    BossBarLog(@"[DebugServer] Running live on http://%@:8765", ip);

    g_serverQueue = dispatch_queue_create("com.nicknameless.ebb.debugserver", DISPATCH_QUEUE_SERIAL);
    dispatch_async(g_serverQueue, ^{
        while (g_serverSocket >= 0) {
            struct sockaddr_in clientAddr;
            socklen_t clientLen = sizeof(clientAddr);
            int clientFd = accept(g_serverSocket, (struct sockaddr *)&clientAddr, &clientLen);
            if (clientFd >= 0) {
                HandleClient(clientFd);
            }
        }
    });
}

void BossBarDebugServerStop(void) {
    if (g_serverSocket >= 0) {
        int s = g_serverSocket;
        g_serverSocket = -1;
        close(s);
    }
}
