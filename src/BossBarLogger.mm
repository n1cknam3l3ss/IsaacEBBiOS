#import "BossBarLogger.h"

void BossBarLog(NSString *format, ...) {
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[IsaacEnhancedBossBarsiOS] %@", msg);
}
