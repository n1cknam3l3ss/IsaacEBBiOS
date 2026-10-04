#import "BossBarController.h"
#import "BossBarData.h"
#import "BossBarMemory.h"
#import "BossBarLogger.h"

#import <QuartzCore/QuartzCore.h>
#import <vector>
#import <string>
#import <unordered_set>

// Offsets in Isaac engine (arm64 iOS)
static constexpr uintptr_t kGameGlobalRVA = 0xAC3B90;
static constexpr size_t kGameCurrentRoomOffset = 0x21550;
static constexpr size_t kRoomDescriptorOffset = 0x8;
static constexpr size_t kRoomDescriptorDataOffset = 0x10;
static constexpr size_t kRoomConfigTypeOffset = 0x8;
static constexpr size_t kRoomEntitiesArrayOffset = 0x19C8;
static constexpr size_t kRoomEntitiesCountOffset = 0x19D4;

// Entity offsets
static constexpr size_t kEntityTypeOffset = 0x38;
static constexpr size_t kEntityVariantOffset = 0x3C;
static constexpr size_t kEntitySubTypeOffset = 0x40;
static constexpr size_t kEntityFlagsOffset = 0x198;
static constexpr size_t kEntityIsDeadOffset = 0x1C3;
static constexpr size_t kEntityHPOffset = 0x354;
static constexpr size_t kEntityMaxHPOffset = 0x358;

// Entity Status Flags
static constexpr uint64_t FLAG_POISON = 1ULL << 10;
static constexpr uint64_t FLAG_CONFUSION = 1ULL << 11;
static constexpr uint64_t FLAG_CHARM = 1ULL << 12;
static constexpr uint64_t FLAG_FEAR = 1ULL << 13;
static constexpr uint64_t FLAG_FREEZE = 1ULL << 14;
static constexpr uint64_t FLAG_SLOW = 1ULL << 15;
static constexpr uint64_t FLAG_BURN = 1ULL << 30;

struct ActiveBossData {
    uintptr_t entityPtr;
    int32_t type;
    int32_t variant;
    std::string name;
    std::string iconRelPath;
    std::string barRelPath;
    std::string overlayRelPath;
    bool isDefaultTint;
    float currentHP;
    float maxHP;
    uint64_t flags;
};

// Passthrough view that ignores all touch events so Isaac's controls receive them
@interface BossBarPassthroughView : UIView
@end

@implementation BossBarPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil; // Pure passthrough
}
@end

#pragma mark - Texture Cache & Slicing

@interface BossBarTextureEntry : NSObject
@property (nonatomic, strong) UIImage *bgImage;
@property (nonatomic, strong) UIImage *fillImage;
@property (nonatomic, strong) UIImage *damageFlashImage;
@property (nonatomic, strong) UIImage *overlayImage;
@end

@implementation BossBarTextureEntry
@end

@interface BossBarTextureCache : NSObject
+ (instancetype)sharedCache;
- (BossBarTextureEntry *)entryForStyle:(BossBarStyleInfo)style bundle:(NSBundle *)bundle;
- (UIImage *)iconForRelPath:(NSString *)relPath bundle:(NSBundle *)bundle;
- (UIImage *)statusIconForIndex:(int)index bundle:(NSBundle *)bundle;
@end

@interface BossBarTextureCache ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, BossBarTextureEntry *> *styleEntries;
@property (nonatomic, strong) NSMutableDictionary<NSString *, UIImage *> *iconCache;
@property (nonatomic, strong) NSMutableDictionary<NSNumber *, UIImage *> *statusIconCache;
@property (nonatomic, strong) UIImage *statusSheet;
@end

@implementation BossBarTextureCache

+ (instancetype)sharedCache {
    static BossBarTextureCache *cache = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        cache = [[BossBarTextureCache alloc] init];
    });
    return cache;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _styleEntries = [NSMutableDictionary dictionary];
        _iconCache = [NSMutableDictionary dictionary];
        _statusIconCache = [NSMutableDictionary dictionary];
    }
    return self;
}

- (NSString *)resolveResourcePath:(NSString *)relPath bundle:(NSBundle *)bundle {
    if (!relPath.length) return nil;
    NSArray<NSString *> *searchRoots = @[
        bundle.resourcePath ?: @"",
        bundle.bundlePath ?: @"",
        [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"resources"],
        NSBundle.mainBundle.bundlePath ?: @""
    ];
    for (NSString *root in searchRoots) {
        if (!root.length) continue;
        NSString *candidate = [root stringByAppendingPathComponent:relPath];
        if ([[NSFileManager defaultManager] fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

static UIImage *SliceCGImage(CGImageRef source, CGRect rect) {
    if (!source) return nil;
    CGImageRef cropped = CGImageCreateWithImageInRect(source, rect);
    if (!cropped) return nil;
    UIImage *res = [UIImage imageWithCGImage:cropped scale:1.0 orientation:UIImageOrientationUp];
    CGImageRelease(cropped);
    return res;
}

static UIImage *TintImage(UIImage *image, UIColor *color) {
    if (!image) return nil;
    UIGraphicsBeginImageContextWithOptions(image.size, NO, 1.0);
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGRect rect = CGRectMake(0, 0, image.size.width, image.size.height);
    [image drawInRect:rect];
    CGContextSetBlendMode(ctx, kCGBlendModeSourceIn);
    [color setFill];
    CGContextFillRect(ctx, rect);
    UIImage *tinted = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return tinted;
}

- (BossBarTextureEntry *)entryForStyle:(BossBarStyleInfo)style bundle:(NSBundle *)bundle {
    NSString *key = [NSString stringWithUTF8String:style.barRelPath ?: "default"];
    BossBarTextureEntry *cached = self.styleEntries[key];
    if (cached) return cached;

    NSString *fullPath = [self resolveResourcePath:key bundle:bundle];
    if (!fullPath) {
        // Fallback to default
        fullPath = [self resolveResourcePath:@"bosshp_bars/custom_bosshp_default.png" bundle:bundle];
    }
    if (!fullPath) return nil;

    UIImage *sheet = [UIImage imageWithContentsOfFile:fullPath];
    if (!sheet || !sheet.CGImage) return nil;
    CGImageRef cgSheet = sheet.CGImage;

    BossBarTextureEntry *entry = [[BossBarTextureEntry alloc] init];

    // Background Frame: (0, 32, 160, 32)
    entry.bgImage = SliceCGImage(cgSheet, CGRectMake(0, 32, 160, 32));

    // Fill: (20, 0, 120, 32) or (170, 0, 120, 32) for Colostomia
    CGFloat fillCropX = [key containsString:@"colostomia"] ? 170.0 : 20.0;
    UIImage *rawFill = SliceCGImage(cgSheet, CGRectMake(fillCropX, 0, 120, 32));

    if (style.isDefaultTint) {
        // Authentic Repentance red tint: (0.84, 0.12, 0.15)
        entry.fillImage = TintImage(rawFill, [UIColor colorWithRed:0.84 green:0.12 blue:0.15 alpha:1.0]);
        // Amber flash on damage: (0.95, 0.78, 0.25)
        entry.damageFlashImage = TintImage(rawFill, [UIColor colorWithRed:0.95 green:0.78 blue:0.25 alpha:1.0]);
    } else {
        // Natural thematic texture color (Delirium yellow, Mother bone, Beast lava, etc.)
        entry.fillImage = rawFill;
        // Bright white/amber damage flash
        entry.damageFlashImage = TintImage(rawFill, [UIColor colorWithWhite:1.0 alpha:0.9]);
    }

    // Overlay (e.g. Mother bones/overgrowth or Beast overlay)
    if (style.overlayRelPath && strlen(style.overlayRelPath) > 0) {
        NSString *ovPath = [self resolveResourcePath:[NSString stringWithUTF8String:style.overlayRelPath] bundle:bundle];
        if (ovPath) {
            UIImage *ovSheet = [UIImage imageWithContentsOfFile:ovPath];
            if (ovSheet && ovSheet.CGImage) {
                entry.overlayImage = SliceCGImage(ovSheet.CGImage, CGRectMake(0, 32, 160, 32));
            }
        }
    }

    self.styleEntries[key] = entry;
    return entry;
}

- (UIImage *)iconForRelPath:(NSString *)relPath bundle:(NSBundle *)bundle {
    if (!relPath.length) return nil;
    UIImage *cached = self.iconCache[relPath];
    if (cached) return cached;

    NSString *pathWithPrefix = [NSString stringWithFormat:@"bosshp_icons/%@", relPath];
    NSString *fullPath = [self resolveResourcePath:pathWithPrefix bundle:bundle];
    if (!fullPath) {
        fullPath = [self resolveResourcePath:relPath bundle:bundle];
    }
    if (!fullPath) return nil;

    UIImage *raw = [UIImage imageWithContentsOfFile:fullPath];
    if (!raw) return nil;

    // Multi-frame animation spritesheets (e.g. dogma_tv.png is 64x64): take top-left 32x32 frame
    if (raw.size.width == 64.0 && (raw.size.height == 64.0 || raw.size.height == 32.0)) {
        raw = SliceCGImage(raw.CGImage, CGRectMake(0, 0, 32, 32));
    }

    if (raw) {
        self.iconCache[relPath] = raw;
    }
    return raw;
}

- (UIImage *)statusIconForIndex:(int)index bundle:(NSBundle *)bundle {
    NSNumber *num = @(index);
    UIImage *cached = self.statusIconCache[num];
    if (cached) return cached;

    if (!self.statusSheet) {
        NSString *fullPath = [self resolveResourcePath:@"bosshp_icons/statuseffect_icons.png" bundle:bundle];
        if (fullPath) {
            self.statusSheet = [UIImage imageWithContentsOfFile:fullPath];
        }
    }
    if (!self.statusSheet || !self.statusSheet.CGImage) return nil;

    // 16x16 frames in horizontal row: index 0..8 at Y=0, index 9..17 at Y=16
    CGFloat x = (index % 9) * 16.0;
    CGFloat y = (index / 9) * 16.0;
    UIImage *icon = SliceCGImage(self.statusSheet.CGImage, CGRectMake(x, y, 16, 16));
    if (icon) {
        self.statusIconCache[num] = icon;
    }
    return icon;
}

@end

#pragma mark - Single Boss Bar View

@interface SingleBossBarView : UIView

@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UIView *barContainer;
@property (nonatomic, strong) UIImageView *bgImageView;
@property (nonatomic, strong) UIView *damageFillContainer;
@property (nonatomic, strong) UIImageView *damageFillImageView;
@property (nonatomic, strong) UIView *fillContainer;
@property (nonatomic, strong) UIImageView *fillImageView;
@property (nonatomic, strong) UIImageView *overlayImageView;
@property (nonatomic, strong) UIView *statusContainer;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *statusIcons;

@property (nonatomic, assign) CGFloat pixelScale;
@property (nonatomic, assign) CGFloat fillTotalWidth;
@property (nonatomic, assign) CGFloat fillOffsetX;
@property (nonatomic, assign) float displayedRatio;

- (void)updateWithData:(const ActiveBossData &)data bundle:(NSBundle *)bundle;

@end

@implementation SingleBossBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        _pixelScale = 1.75;
        _displayedRatio = 1.0f;
        _statusIcons = [NSMutableArray array];

        // 160x32 bar frame at scale 1.75 = 280 x 56 pt
        CGFloat barW = 160.0 * _pixelScale;
        CGFloat barH = 32.0 * _pixelScale;
        CGFloat iconSize = 32.0 * _pixelScale;
        CGFloat iconOverlap = 6.0 * _pixelScale;

        _fillOffsetX = 20.0 * _pixelScale;
        _fillTotalWidth = 120.0 * _pixelScale;

        // 1. Icon View on the left
        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, (frame.size.height - iconSize) / 2.0, iconSize, iconSize)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.magnificationFilter = kCAFilterNearest;
        _iconView.layer.minificationFilter = kCAFilterNearest;
        _iconView.userInteractionEnabled = NO;
        [self addSubview:_iconView];

        // 2. Bar Frame Container
        CGFloat barX = iconSize - iconOverlap;
        _barContainer = [[UIView alloc] initWithFrame:CGRectMake(barX, (frame.size.height - barH) / 2.0, barW, barH)];
        _barContainer.backgroundColor = UIColor.clearColor;
        _barContainer.userInteractionEnabled = NO;
        _barContainer.clipsToBounds = NO;
        [self addSubview:_barContainer];

        // 3. Background Frame Sprite
        _bgImageView = [[UIImageView alloc] initWithFrame:_barContainer.bounds];
        _bgImageView.contentMode = UIViewContentModeScaleToFill;
        _bgImageView.layer.magnificationFilter = kCAFilterNearest;
        _bgImageView.layer.minificationFilter = kCAFilterNearest;
        _bgImageView.userInteractionEnabled = NO;
        [_barContainer addSubview:_bgImageView];

        // 4. Delayed Damage Flash Fill Container (clips from right)
        _damageFillContainer = [[UIView alloc] initWithFrame:CGRectMake(_fillOffsetX, 0, _fillTotalWidth, barH)];
        _damageFillContainer.clipsToBounds = YES;
        _damageFillContainer.backgroundColor = UIColor.clearColor;
        _damageFillContainer.userInteractionEnabled = NO;
        [_barContainer addSubview:_damageFillContainer];

        _damageFillImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, _fillTotalWidth, barH)];
        _damageFillImageView.contentMode = UIViewContentModeScaleToFill;
        _damageFillImageView.layer.magnificationFilter = kCAFilterNearest;
        _damageFillImageView.layer.minificationFilter = kCAFilterNearest;
        _damageFillImageView.userInteractionEnabled = NO;
        [_damageFillContainer addSubview:_damageFillImageView];

        // 5. Main HP Fill Container (clips from right)
        _fillContainer = [[UIView alloc] initWithFrame:CGRectMake(_fillOffsetX, 0, _fillTotalWidth, barH)];
        _fillContainer.clipsToBounds = YES;
        _fillContainer.backgroundColor = UIColor.clearColor;
        _fillContainer.userInteractionEnabled = NO;
        [_barContainer addSubview:_fillContainer];

        _fillImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, _fillTotalWidth, barH)];
        _fillImageView.contentMode = UIViewContentModeScaleToFill;
        _fillImageView.layer.magnificationFilter = kCAFilterNearest;
        _fillImageView.layer.minificationFilter = kCAFilterNearest;
        _fillImageView.userInteractionEnabled = NO;
        [_fillContainer addSubview:_fillImageView];

        // 6. Thematic Overlay Sprite (Mother creeping bones, Beast overlay, etc.)
        _overlayImageView = [[UIImageView alloc] initWithFrame:_barContainer.bounds];
        _overlayImageView.contentMode = UIViewContentModeScaleToFill;
        _overlayImageView.layer.magnificationFilter = kCAFilterNearest;
        _overlayImageView.layer.minificationFilter = kCAFilterNearest;
        _overlayImageView.userInteractionEnabled = NO;
        [_barContainer addSubview:_overlayImageView];

        // 7. Status Effects Container above the bar
        _statusContainer = [[UIView alloc] initWithFrame:CGRectMake(barX + _fillOffsetX, (frame.size.height - barH) / 2.0 - 20, _fillTotalWidth, 18)];
        _statusContainer.backgroundColor = UIColor.clearColor;
        _statusContainer.userInteractionEnabled = NO;
        [self addSubview:_statusContainer];
    }
    return self;
}

- (void)updateWithData:(const ActiveBossData &)data bundle:(NSBundle *)bundle {
    BossBarTextureCache *cache = [BossBarTextureCache sharedCache];

    // 1. Resolve and apply Boss Bar Style
    BossBarStyleInfo style = {
        data.barRelPath.c_str(),
        data.overlayRelPath.empty() ? nullptr : data.overlayRelPath.c_str(),
        data.isDefaultTint
    };
    BossBarTextureEntry *entry = [cache entryForStyle:style bundle:bundle];
    if (entry) {
        _bgImageView.image = entry.bgImage;
        _fillImageView.image = entry.fillImage;
        _damageFillImageView.image = entry.damageFlashImage;
        _overlayImageView.image = entry.overlayImage;
        _overlayImageView.hidden = (entry.overlayImage == nil);
    }

    // 2. Resolve and apply Boss Icon
    NSString *iconRel = [NSString stringWithUTF8String:data.iconRelPath.c_str()];
    _iconView.image = [cache iconForRelPath:iconRel bundle:bundle];

    // 3. Smooth HP bar draining animation
    float maxHP = data.maxHP > 0.0f ? data.maxHP : 1.0f;
    float targetRatio = MAX(0.0f, MIN(1.0f, data.currentHP / maxHP));
    CGFloat targetWidth = _fillTotalWidth * targetRatio;

    // Instant main fill update (smooth 0.1s curve)
    [UIView animateWithDuration:0.10 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.fillContainer.frame = CGRectMake(self.fillOffsetX, 0, targetWidth, self.barContainer.bounds.size.height);
    } completion:nil];

    // Delayed damage flash (lingering amber bar)
    [UIView animateWithDuration:0.35 delay:0.12 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.damageFillContainer.frame = CGRectMake(self.fillOffsetX, 0, targetWidth, self.barContainer.bounds.size.height);
    } completion:nil];

    _displayedRatio = targetRatio;

    // 4. Status Effect Badges (pixel icons, no text)
    std::vector<int> activeStatusIndices;
    if (data.flags & FLAG_BURN) activeStatusIndices.push_back(0);        // Burn
    if (data.flags & FLAG_CHARM) activeStatusIndices.push_back(1);       // Charm
    if (data.flags & FLAG_CONFUSION) activeStatusIndices.push_back(2);   // Confusion
    if (data.flags & FLAG_FEAR) activeStatusIndices.push_back(3);        // Fear
    if (data.flags & FLAG_FREEZE) activeStatusIndices.push_back(4);      // Freeze
    if (data.flags & FLAG_POISON) activeStatusIndices.push_back(5);      // Poison
    if (data.flags & FLAG_SLOW) activeStatusIndices.push_back(6);        // Slow

    while (_statusIcons.count < activeStatusIndices.size()) {
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 16 * _pixelScale, 16 * _pixelScale)];
        iv.contentMode = UIViewContentModeScaleAspectFit;
        iv.layer.magnificationFilter = kCAFilterNearest;
        iv.layer.minificationFilter = kCAFilterNearest;
        [_statusContainer addSubview:iv];
        [_statusIcons addObject:iv];
    }
    while (_statusIcons.count > activeStatusIndices.size()) {
        UIImageView *last = [_statusIcons lastObject];
        [last removeFromSuperview];
        [_statusIcons removeLastObject];
    }

    CGFloat sx = 0.0;
    CGFloat sSpacing = 4.0;
    for (size_t i = 0; i < activeStatusIndices.size(); ++i) {
        UIImageView *iv = _statusIcons[i];
        iv.image = [cache statusIconForIndex:activeStatusIndices[i] bundle:bundle];
        iv.frame = CGRectMake(sx, 0, 16 * _pixelScale, 16 * _pixelScale);
        sx += 16 * _pixelScale + sSpacing;
    }
}

@end

#pragma mark - Master Controller

@interface BossBarController ()

@property (nonatomic, strong) BossBarPassthroughView *rootView;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) NSMutableArray<SingleBossBarView *> *barViews;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) uintptr_t baseAddress;
@property (nonatomic, strong) NSBundle *modBundle;
@property (nonatomic, assign) BOOL loggedFirstDetection;

@end

@implementation BossBarController

+ (instancetype)sharedInstance {
    static BossBarController *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[BossBarController alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _baseAddress = BossBarGetBaseAddress();
        _barViews = [NSMutableArray array];
        _modBundle = [NSBundle bundleForClass:[self class]];
    }
    return self;
}

- (UIWindow *)findGameWindow {
    UIWindow *fallback = nil;
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *window in ((UIWindowScene *)scene).windows) {
            if (window.hidden || window.alpha <= 0.0 || window.windowLevel != UIWindowLevelNormal) continue;
            if (window.isKeyWindow) return window;
            if (!fallback) fallback = window;
        }
    }
    if (!fallback) {
        fallback = UIApplication.sharedApplication.keyWindow;
    }
    return fallback;
}

- (void)setupOverlayIfNeeded {
    UIWindow *window = [self findGameWindow];
    if (!window || CGRectIsEmpty(window.bounds)) return;

    if (self.rootView && self.rootView.superview == window) {
        [window bringSubviewToFront:self.rootView];
        return;
    }

    [self.rootView removeFromSuperview];

    self.rootView = [[BossBarPassthroughView alloc] initWithFrame:window.bounds];
    self.rootView.backgroundColor = UIColor.clearColor;
    self.rootView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.rootView.userInteractionEnabled = NO;
    self.rootView.layer.zPosition = 9999.0f;

    // Scale 1.75: bar 280 pt, icon 56 pt -> total width ~326 pt
    CGFloat pixelScale = 1.75;
    CGFloat singleBarW = (160.0 + 32.0 - 6.0) * pixelScale;
    CGFloat singleBarH = 32.0 * pixelScale + 20.0; // Extra room for status badges
    CGFloat bottomInset = 16.0;
    if (@available(iOS 11.0, *)) {
        bottomInset = MAX(bottomInset, window.safeAreaInsets.bottom + 6.0);
    }

    self.containerView = [[UIView alloc] initWithFrame:CGRectMake((window.bounds.size.width - singleBarW) / 2.0,
                                                                  window.bounds.size.height - singleBarH - bottomInset,
                                                                  singleBarW, singleBarH)];
    self.containerView.backgroundColor = UIColor.clearColor;
    self.containerView.userInteractionEnabled = NO;
    self.containerView.alpha = 0.0;
    self.containerView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                          UIViewAutoresizingFlexibleRightMargin |
                                          UIViewAutoresizingFlexibleTopMargin;
    [self.rootView addSubview:self.containerView];
    [window addSubview:self.rootView];
    [window bringSubviewToFront:self.rootView];

    BossBarLog(@"[OVERLAY] Attached Enhanced Boss Bars overlay to window (zPosition: 9999)");
}

- (void)start {
    BossBarLog(@"[CONTROLLER] Starting Enhanced Boss Bars controller...");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self setupOverlayIfNeeded];

        if (!self.timer) {
            self.timer = [NSTimer scheduledTimerWithTimeInterval:0.05
                                                          target:self
                                                        selector:@selector(tick:)
                                                        userInfo:nil
                                                         repeats:YES];
            [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
            BossBarLog(@"[CONTROLLER] NSTimer scheduled on main runloop (0.05s / 20 Hz)");
        }
    });
}

- (void)stop {
    [self.timer invalidate];
    self.timer = nil;
    [self.rootView removeFromSuperview];
    self.rootView = nil;
}

- (void)tick:(NSTimer *)timer {
    (void)timer;

    if (!self.baseAddress) {
        self.baseAddress = BossBarGetBaseAddress();
        if (!self.baseAddress) return;
        BossBarLog(@"[CONTROLLER] Resolved Isaac base address: 0x%lx", (unsigned long)self.baseAddress);
    }

    [self setupOverlayIfNeeded];

    uintptr_t gamePtrAddr = self.baseAddress + kGameGlobalRVA;
    uintptr_t game = 0;
    if (!SafeRead(gamePtrAddr, game) || !game) {
        [self setOverlayVisible:NO];
        return;
    }

    uintptr_t room = 0;
    if (!SafeRead(game + kGameCurrentRoomOffset, room) || !room) {
        [self setOverlayVisible:NO];
        return;
    }

    int32_t roomType = 0;
    uintptr_t descriptor = 0;
    if (SafeRead(room + kRoomDescriptorOffset, descriptor) && descriptor) {
        uintptr_t roomData = 0;
        if (SafeRead(descriptor + kRoomDescriptorDataOffset, roomData) && roomData) {
            SafeRead(roomData + kRoomConfigTypeOffset, roomType);
        }
    }

    // Scan entities in the room
    uintptr_t entitiesArrayPtr = 0;
    int32_t count = 0;
    if (!SafeRead(room + kRoomEntitiesArrayOffset, entitiesArrayPtr) || !entitiesArrayPtr ||
        !SafeRead(room + kRoomEntitiesCountOffset, count) || count <= 0 || count > 2048) {
        [self setOverlayVisible:NO];
        return;
    }

    std::vector<ActiveBossData> activeBosses;
    std::unordered_set<uintptr_t> seenEntities;

    for (int32_t i = 0; i < count; ++i) {
        uintptr_t entity = 0;
        if (!SafeRead(entitiesArrayPtr + i * sizeof(uintptr_t), entity) || !entity) continue;
        if (seenEntities.count(entity)) continue;

        uint8_t isDead = 0;
        SafeRead(entity + kEntityIsDeadOffset, isDead);
        if (isDead) continue;

        int32_t type = 0;
        int32_t variant = 0;
        if (!SafeRead(entity + kEntityTypeOffset, type)) continue;
        SafeRead(entity + kEntityVariantOffset, variant);

        // Filter: only boss NPCs (type >= 10 && < 1000)
        if (type < 10 || type >= 1000) continue;

        float hp = 0.0f;
        float maxHp = 0.0f;
        if (!SafeRead(entity + kEntityHPOffset, hp) || hp <= 0.0f) continue;
        SafeRead(entity + kEntityMaxHPOffset, maxHp);
        if (maxHp <= 0.0f) continue;

        const BossBarInfo *info = FindBossInfo(type, variant);

        // Eligible if in database OR in a boss room (roomType == 5) with significant HP
        if (info || (roomType == 5 && maxHp >= 40.0f)) {
            // Deduplicate multi-part / subsidiary entities of the same boss type (e.g. Mom foot vs doors/eyes)
            bool foundExistingType = false;
            for (auto &existing : activeBosses) {
                if (existing.type == type) {
                    foundExistingType = true;
                    // If current entity has larger maxHP (e.g. main body vs appendage), adopt it
                    if (maxHp > existing.maxHP) {
                        existing.entityPtr = entity;
                        existing.variant = variant;
                        existing.currentHP = hp;
                        existing.maxHP = maxHp;
                        SafeRead(entity + kEntityFlagsOffset, existing.flags);
                    }
                    break;
                }
            }
            if (foundExistingType) continue;

            ActiveBossData b;
            b.entityPtr = entity;
            b.type = type;
            b.variant = variant;
            b.name = info ? info->name : "Boss";
            b.iconRelPath = info ? info->iconRelPath : "boss.png";

            // Resolve authentic thematic bar style
            BossBarStyleInfo style = GetBarStyleInfo(info ? info->barStyle : nullptr);
            b.barRelPath = style.barRelPath;
            b.overlayRelPath = style.overlayRelPath ? style.overlayRelPath : "";
            b.isDefaultTint = style.isDefaultTint;

            b.currentHP = hp;
            b.maxHP = maxHp;

            uint64_t flags = 0;
            SafeRead(entity + kEntityFlagsOffset, flags);
            b.flags = flags;

            seenEntities.insert(entity);
            activeBosses.push_back(b);

            if (!self.loggedFirstDetection) {
                BossBarLog(@"[BOSS DETECTED] %s (Type: %d, Variant: %d, BarStyle: %s)",
                           b.name.c_str(), type, variant, info ? (info->barStyle ? info->barStyle : "Default") : "Default");
                self.loggedFirstDetection = YES;
            }

            if (activeBosses.size() >= 4) break; // Limit to 4 bars max
        }
    }

    if (activeBosses.empty()) {
        self.loggedFirstDetection = NO;
        [self setOverlayVisible:NO];
        return;
    }

    [self updateBarsWithBosses:activeBosses];
    [self setOverlayVisible:YES];
}

- (void)setOverlayVisible:(BOOL)visible {
    if ((self.containerView.alpha > 0.0) == visible) return;

    [UIView animateWithDuration:0.20 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.containerView.alpha = visible ? 1.0 : 0.0;
    } completion:nil];
}

- (void)updateBarsWithBosses:(const std::vector<ActiveBossData> &)bosses {
    CGFloat pixelScale = 1.75;
    CGFloat singleBarW = (160.0 + 32.0 - 6.0) * pixelScale;
    CGFloat singleBarH = 32.0 * pixelScale + 20.0;
    CGFloat spacing = 4.0;
    CGFloat totalH = bosses.size() * singleBarH + (bosses.size() - 1) * spacing;

    UIWindow *window = self.rootView.window ?: [self findGameWindow];
    CGFloat bottomInset = 16.0;
    if (@available(iOS 11.0, *)) {
        if (window) bottomInset = MAX(bottomInset, window.safeAreaInsets.bottom + 6.0);
    }

    CGRect newFrame = CGRectMake((window.bounds.size.width - singleBarW) / 2.0,
                                 window.bounds.size.height - totalH - bottomInset,
                                 singleBarW, totalH);
    self.containerView.frame = newFrame;

    // Adjust view count
    while (self.barViews.count < bosses.size()) {
        SingleBossBarView *barView = [[SingleBossBarView alloc] initWithFrame:CGRectMake(0, 0, singleBarW, singleBarH)];
        [self.containerView addSubview:barView];
        [self.barViews addObject:barView];
    }
    while (self.barViews.count > bosses.size()) {
        SingleBossBarView *last = [self.barViews lastObject];
        [last removeFromSuperview];
        [self.barViews removeLastObject];
    }

    // Layout each bar view (main boss at bottom, helpers stacked upward)
    for (size_t i = 0; i < bosses.size(); ++i) {
        SingleBossBarView *view = self.barViews[i];
        CGFloat y = (bosses.size() - 1 - i) * (singleBarH + spacing);
        view.frame = CGRectMake(0, y, singleBarW, singleBarH);
        [view updateWithData:bosses[i] bundle:self.modBundle];
    }
}

@end
