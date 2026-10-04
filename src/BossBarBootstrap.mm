#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "BossBarController.h"
#import "BossBarLogger.h"

__attribute__((constructor))
static void BossBarInitialize(void) {
    BossBarLog(@"IsaacEnhancedBossBarsiOS initialized! Registering UI lifecycle observers...");

    dispatch_async(dispatch_get_main_queue(), ^{
        if (UIApplication.sharedApplication.keyWindow || UIApplication.sharedApplication.windows.count > 0) {
            [[BossBarController sharedInstance] start];
        } else {
            [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidFinishLaunchingNotification
                                                              object:nil
                                                               queue:[NSOperationQueue mainQueue]
                                                          usingBlock:^(NSNotification * _Nonnull note) {
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [[BossBarController sharedInstance] start];
                });
            }];
        }
    });
}
