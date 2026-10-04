#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "BossBarController.h"
#import "BossBarLogger.h"

static dispatch_once_t gBossBarStartOnce;

static void BossBarStart(void) {
    dispatch_once(&gBossBarStartOnce, ^{
        BossBarLog(@"[BOOTSTRAP] Executing BossBarStart on main thread...");
        [[BossBarController sharedInstance] start];
    });
}

__attribute__((constructor))
static void BossBarInitialize(void) {
    @autoreleasepool {
        BossBarLog(@"[BOOTSTRAP] IsaacEnhancedBossBarsiOS constructor invoked! Registering UI lifecycle observers...");

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
