#pragma once

#import <UIKit/UIKit.h>

@interface BossBarController : NSObject

+ (instancetype)sharedInstance;
- (void)start;
- (void)stop;

@end
