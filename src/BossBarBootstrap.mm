#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "BossBarController.h"
#import "BossBarLogger.h"
#import "BossBarDebugServer.h"

static dispatch_once_t gBossBarStartOnce;

static void BossBarStart(void) {
    dispatch_once(&gBossBarStartOnce, ^{
        BossBarLog(@"[BOOTSTRAP] Executing BossBarStart on main thread...");
        BossBarDebugServerStart();
        [[BossBarController sharedInstance] start];
    });
}

static void SuppressVanillaBossBarTextures(void) {
    NSBundle *mainBundle = [NSBundle mainBundle];
    NSString *bundlePath = mainBundle.bundlePath;
    if (!bundlePath) return;

    // 1x1 70-byte transparent PNG
    static const unsigned char kTransparentPNG[70] = {
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
        0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
        0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x60, 0x60, 0x60, 0x60,
        0x00, 0x00, 0x00, 0x05, 0x00, 0x01, 0xA5, 0xF6, 0x45, 0x40, 0x00, 0x00,
        0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82
    };
    NSData *pngData = [NSData dataWithBytes:kTransparentPNG length:sizeof(kTransparentPNG)];

    NSArray<NSString *> *targets = @[
        @"repentance-resources/data/gfx/ui/ui_bosshealthbar.png",
        @"repentance-resources/data/gfx/ui/ui_bosshealthbar_static.png",
        @"repentance-resources/data/gfx/ui/ui_bosshealthbar_stone.png",
        @"repentance-resources/data/gfx/ui/ui_bosshealthbar_mini.png",
        @"afterbirthplus-resources/data/gfx/ui/ui_bosshealthbar.png",
        @"afterbirth-resources/data/gfx/ui/ui_bosshealthbar.png",
        @"afterbirth-resources/data.kr/gfx/ui/ui_bosshealthbar.png",
        @"rebirth-resources/data/gfx/ui/ui_bosshealthbar.png"
    ];

    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *rel in targets) {
        NSString *fullPath = [bundlePath stringByAppendingPathComponent:rel];
        if ([fm fileExistsAtPath:fullPath]) {
            NSDictionary *attrs = [fm attributesOfItemAtPath:fullPath error:nil];
            if (attrs && [attrs fileSize] != sizeof(kTransparentPNG)) {
                NSError *err = nil;
                BOOL ok = [pngData writeToFile:fullPath options:NSDataWritingAtomic error:&err];
                if (ok) {
                    BossBarLog(@"[BOOTSTRAP] Suppressed vanilla bar: %@", rel);
                }
            }
        }
    }
}

__attribute__((constructor))
static void BossBarInitialize(void) {
    @autoreleasepool {
        BossBarLog(@"[BOOTSTRAP] IsaacEnhancedBossBarsiOS constructor invoked! Registering UI lifecycle observers...");
        SuppressVanillaBossBarTextures();

        dispatch_async(dispatch_get_main_queue(), ^{
            NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
            [center addObserverForName:UIApplicationDidBecomeActiveNotification
                                object:nil
                                 queue:[NSOperationQueue mainQueue]
                            usingBlock:^(__unused NSNotification *note) {
                BossBarLog(@"[BOOTSTRAP] UIApplicationDidBecomeActiveNotification received");
                BossBarStart();
            }];

            if (UIApplication.sharedApplication.applicationState == UIApplicationStateActive) {
                BossBarLog(@"[BOOTSTRAP] Application already in active state");
                BossBarStart();
            }

            // Fallback timers to handle LiveContainer's guest startup flow
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BossBarStart();
            });
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                BossBarStart();
            });
        });
    }
}
