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

// Entity Status Flags (exact bitshifts in The Binding of Isaac: Repentance)
static constexpr uint64_t FLAG_FREEZE    = 1ULL << 5;
static constexpr uint64_t FLAG_POISON    = 1ULL << 6;
static constexpr uint64_t FLAG_SLOW      = 1ULL << 7;
static constexpr uint64_t FLAG_CHARM     = 1ULL << 8;
static constexpr uint64_t FLAG_CONFUSION = 1ULL << 9;
static constexpr uint64_t FLAG_FEAR      = 1ULL << 11;
static constexpr uint64_t FLAG_BURN      = 1ULL << 12;

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

// Passthrough view that ignores all touch events so Isaac's virtual controls receive them
@interface BossBarPassthroughView : UIView
@end

@implementation BossBarPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil; // Pure passthrough
}
@end

#pragma mark - Texture Cache & Slicing

@interface BossBarIconEntry : NSObject
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) NSArray<UIImage *> *animationImages;
@property (nonatomic, assign) BOOL isLarge; // 64x64
@end

@implementation BossBarIconEntry
@end

@interface BossBarTextureEntry : NSObject
@property (nonatomic, strong) UIImage *bgImage;
@property (nonatomic, strong) UIImage *fillImage;
@property (nonatomic, strong) NSArray<UIImage *> *fillAnimationImages;
@property (nonatomic, strong) UIImage *damageFlashImage;
@property (nonatomic, strong) UIImage *overlayImage;
@end

@implementation BossBarTextureEntry
@end

@interface BossBarTextureCache : NSObject
+ (instancetype)sharedCache;
- (BossBarTextureEntry *)entryForStyle:(BossBarStyleInfo)style bundle:(NSBundle *)bundle;
- (BossBarIconEntry *)iconEntryForRelPath:(NSString *)relPath bundle:(NSBundle *)bundle;
- (UIImage *)statusIconForIndex:(int)index bundle:(NSBundle *)bundle;
@end

@interface BossBarTextureCache ()
@property (nonatomic, strong) NSMutableDictionary<NSString *, BossBarTextureEntry *> *styleEntries;
@property (nonatomic, strong) NSMutableDictionary<NSString *, BossBarIconEntry *> *iconCache;
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
        fullPath = [self resolveResourcePath:@"bosshp_bars/custom_bosshp_default.png" bundle:bundle];
    }
    if (!fullPath) return nil;

    UIImage *sheet = [UIImage imageWithContentsOfFile:fullPath];
    if (!sheet || !sheet.CGImage) return nil;
    CGImageRef cgSheet = sheet.CGImage;

    BossBarTextureEntry *entry = [[BossBarTextureEntry alloc] init];

    // Background Frame: (0, 32, 160, 32)
    entry.bgImage = SliceCGImage(cgSheet, CGRectMake(0, 32, 160, 32));

    NSString *lowerKey = key.lowercaseString;

    // 1. Dogma TV static animated fill
    if ([lowerKey containsString:@"dogma"]) {
        NSMutableArray<UIImage *> *staticFrames = [NSMutableArray arrayWithCapacity:4];
        for (int f = 0; f < 4; ++f) {
            CGImageRef stripCG = CGImageCreateWithImageInRect(cgSheet, CGRectMake(170, f * 15, 120, 10));
            if (stripCG) {
                UIImage *stripImg = [UIImage imageWithCGImage:stripCG scale:1.0 orientation:UIImageOrientationUp];
                UIGraphicsBeginImageContextWithOptions(CGSizeMake(120, 32), NO, 1.0);
                [stripImg drawInRect:CGRectMake(0, 12, 120, 10)];
                UIImage *fullFrame = UIGraphicsGetImageFromCurrentImageContext();
                UIGraphicsEndImageContext();
                CGImageRelease(stripCG);
                if (fullFrame) [staticFrames addObject:fullFrame];
            }
        }
        entry.fillAnimationImages = staticFrames;
        entry.fillImage = staticFrames.firstObject;
        entry.damageFlashImage = TintImage(entry.fillImage, [UIColor colorWithWhite:1.0 alpha:0.9]);
    }
    // 2. Colostomia (crop at X=170)
    else if ([lowerKey containsString:@"colostomia"]) {
        UIImage *rawFill = SliceCGImage(cgSheet, CGRectMake(170, 0, 120, 32));
        entry.fillImage = rawFill;
        entry.damageFlashImage = TintImage(rawFill, [UIColor colorWithWhite:1.0 alpha:0.9]);
    }
    // 3. Thematic / Standard boss bars
    else {
        UIImage *rawFill = SliceCGImage(cgSheet, CGRectMake(20, 0, 120, 32));
        if (style.isDefaultTint) {
            // Authentic Repentance red tint: (0.84, 0.12, 0.15)
            entry.fillImage = TintImage(rawFill, [UIColor colorWithRed:0.84 green:0.12 blue:0.15 alpha:1.0]);
            // Amber flash on damage: (0.95, 0.78, 0.25)
            entry.damageFlashImage = TintImage(rawFill, [UIColor colorWithRed:0.95 green:0.78 blue:0.25 alpha:1.0]);
        } else {
            // Natural thematic texture color (Delirium yellow, Mother bone, Beast lava, etc.)
            entry.fillImage = rawFill;
            // Bright white damage flash
            entry.damageFlashImage = TintImage(rawFill, [UIColor colorWithWhite:1.0 alpha:0.9]);
        }
    }

    // 4. Thematic Overlays (Mother bones/overgrowth, Beast fire overlay)
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

- (BossBarIconEntry *)iconEntryForRelPath:(NSString *)relPath bundle:(NSBundle *)bundle {
    if (!relPath.length) return nil;
    BossBarIconEntry *cached = self.iconCache[relPath];
    if (cached) return cached;

    NSString *pathWithPrefix = [NSString stringWithFormat:@"bosshp_icons/%@", relPath];
    NSString *fullPath = [self resolveResourcePath:pathWithPrefix bundle:bundle];
    if (!fullPath) {
        fullPath = [self resolveResourcePath:relPath bundle:bundle];
    }
    if (!fullPath) return nil;

    UIImage *raw = [UIImage imageWithContentsOfFile:fullPath];
    if (!raw || !raw.CGImage) return nil;
    CGImageRef cg = raw.CGImage;

    BossBarIconEntry *res = [[BossBarIconEntry alloc] init];
    NSString *lower = relPath.lowercaseString;

    // Dogma Phase 2 wings: 128x128 containing four 64x64 animated frames
    if ([lower containsString:@"dogma_phase2"]) {
        NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:4];
        [frames addObject:SliceCGImage(cg, CGRectMake(0, 0, 64, 64))];
        [frames addObject:SliceCGImage(cg, CGRectMake(64, 0, 64, 64))];
        [frames addObject:SliceCGImage(cg, CGRectMake(0, 64, 64, 64))];
        [frames addObject:SliceCGImage(cg, CGRectMake(64, 64, 64, 64))];
        res.animationImages = frames;
        res.image = frames.firstObject;
        res.isLarge = YES;
    }
    // Dogma Phase 1 TV static: 64x64 containing four 32x32 animated frames
    else if ([lower containsString:@"dogma_tv"] || [lower containsString:@"final/dogma.png"]) {
        NSMutableArray<UIImage *> *frames = [NSMutableArray arrayWithCapacity:4];
        [frames addObject:SliceCGImage(cg, CGRectMake(0, 0, 32, 32))];
        [frames addObject:SliceCGImage(cg, CGRectMake(32, 0, 32, 32))];
        [frames addObject:SliceCGImage(cg, CGRectMake(0, 32, 32, 32))];
        [frames addObject:SliceCGImage(cg, CGRectMake(32, 32, 32, 32))];
        res.animationImages = frames;
        res.image = frames.firstObject;
        res.isLarge = NO;
    }
    // Ultra Harbingers & Mega Satan (64x64 large icons)
    else if (raw.size.width >= 60.0 && raw.size.height >= 60.0) {
        res.image = raw;
        res.isLarge = YES;
    }
    // Standard 32x32 icons
    else {
        res.image = raw;
        res.isLarge = NO;
    }

    self.iconCache[relPath] = res;
    return res;
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

    // 16x16 frames in horizontal rows (9 frames per row)
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

@property (nonatomic, strong) UIView *barContainer;
@property (nonatomic, strong) UIImageView *bgImageView;
@property (nonatomic, strong) UIView *damageFillContainer;
@property (nonatomic, strong) UIImageView *damageFillImageView;
@property (nonatomic, strong) UIView *fillContainer;
@property (nonatomic, strong) UIImageView *fillImageView;
@property (nonatomic, strong) UIImageView *overlayImageView;
@property (nonatomic, strong) UIImageView *iconView;

@property (nonatomic, strong) UIView *statusContainer;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *statusIcons;

@property (nonatomic, assign) CGFloat pixelScale;
@property (nonatomic, assign) CGFloat fillTotalWidth;
@property (nonatomic, assign) CGFloat fillOffsetX;
@property (nonatomic, assign) CGFloat extraLeftPad;

- (void)updateWithData:(const ActiveBossData &)data bundle:(NSBundle *)bundle;

@end

@implementation SingleBossBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        _pixelScale = 1.75;
        _statusIcons = [NSMutableArray array];

        // Layout constants at scale 1.75:
        // Background frame: 160 x 32 px -> 280 x 56 pt
        CGFloat barW = 160.0 * _pixelScale;
        CGFloat barH = 32.0 * _pixelScale;
        _extraLeftPad = 48.0; // Space for status badges to the left of the portrait

        _fillOffsetX = 20.0 * _pixelScale;   // 35.0 pt
        _fillTotalWidth = 120.0 * _pixelScale; // 210.0 pt

        // 1. Status effects container (to the left of the boss portrait)
        _statusContainer = [[UIView alloc] initWithFrame:CGRectMake(0, 0, _extraLeftPad, barH)];
        _statusContainer.backgroundColor = UIColor.clearColor;
        _statusContainer.userInteractionEnabled = NO;
        [self addSubview:_statusContainer];

        // 2. Bar Container (seamlessly hosts background frame, fills, overlay, and boss portrait)
        _barContainer = [[UIView alloc] initWithFrame:CGRectMake(_extraLeftPad, 0, barW, barH)];
        _barContainer.backgroundColor = UIColor.clearColor;
        _barContainer.userInteractionEnabled = NO;
        _barContainer.clipsToBounds = NO;
        [self addSubview:_barContainer];

        // 3. Background Frame Sprite (starts at X=0, frame notch at X=18..26)
        _bgImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, barW, barH)];
        _bgImageView.contentMode = UIViewContentModeScaleToFill;
        _bgImageView.layer.magnificationFilter = kCAFilterNearest;
        _bgImageView.layer.minificationFilter = kCAFilterNearest;
        _bgImageView.userInteractionEnabled = NO;
        [_barContainer addSubview:_bgImageView];

        // 4. Delayed Damage Flash Fill Container
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

        // 5. Main HP Fill Container
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

        // 6. Thematic Overlay Sprite (Mother creeping bones, Beast fire)
        _overlayImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, barW, barH)];
        _overlayImageView.contentMode = UIViewContentModeScaleToFill;
        _overlayImageView.layer.magnificationFilter = kCAFilterNearest;
        _overlayImageView.layer.minificationFilter = kCAFilterNearest;
        _overlayImageView.userInteractionEnabled = NO;
        [_barContainer addSubview:_overlayImageView];

        // 7. Boss Portrait Icon (centered at X=16, Y=16 of bar coordinate space to seamlessly sit in notch)
        CGFloat iconCenter = 16.0 * _pixelScale;
        CGFloat defaultIconSize = 32.0 * _pixelScale;
        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(iconCenter - defaultIconSize / 2.0,
                                                                 iconCenter - defaultIconSize / 2.0,
                                                                 defaultIconSize, defaultIconSize)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.magnificationFilter = kCAFilterNearest;
        _iconView.layer.minificationFilter = kCAFilterNearest;
        _iconView.userInteractionEnabled = NO;
        [_barContainer addSubview:_iconView];
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
        _damageFillImageView.image = entry.damageFlashImage;
        _overlayImageView.image = entry.overlayImage;
        _overlayImageView.hidden = (entry.overlayImage == nil);

        // Animated TV static for Dogma bar fill
        if (entry.fillAnimationImages.count > 1) {
            if (!_fillImageView.isAnimating) {
                _fillImageView.animationImages = entry.fillAnimationImages;
                _fillImageView.animationDuration = 0.25;
                [_fillImageView startAnimating];
            }
        } else {
            if (_fillImageView.isAnimating) {
                [_fillImageView stopAnimating];
                _fillImageView.animationImages = nil;
            }
            _fillImageView.image = entry.fillImage;
        }
    }

    // 2. Resolve and apply Boss Icon
    NSString *iconRel = [NSString stringWithUTF8String:data.iconRelPath.c_str()];
    BossBarIconEntry *iconEntry = [cache iconEntryForRelPath:iconRel bundle:bundle];
    if (iconEntry) {
        CGFloat centerCoord = 16.0 * _pixelScale;
        if (iconEntry.isLarge) {
            CGFloat size = 64.0 * _pixelScale;
            _iconView.frame = CGRectMake(centerCoord - size / 2.0, centerCoord - size / 2.0, size, size);
        } else {
            CGFloat size = 32.0 * _pixelScale;
            _iconView.frame = CGRectMake(centerCoord - size / 2.0, centerCoord - size / 2.0, size, size);
        }

        if (iconEntry.animationImages.count > 1) {
            if (!_iconView.isAnimating) {
                _iconView.animationImages = iconEntry.animationImages;
                _iconView.animationDuration = 0.25;
                [_iconView startAnimating];
            }
        } else {
            if (_iconView.isAnimating) {
                [_iconView stopAnimating];
                _iconView.animationImages = nil;
            }
            _iconView.image = iconEntry.image;
        }
    }

    // 3. Smooth HP bar draining animation
    float maxHP = data.maxHP > 0.0f ? data.maxHP : 1.0f;
    float targetRatio = MAX(0.0f, MIN(1.0f, data.currentHP / maxHP));
    CGFloat targetWidth = _fillTotalWidth * targetRatio;

    CGFloat barH = 32.0 * _pixelScale;
    [UIView animateWithDuration:0.10 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.fillContainer.frame = CGRectMake(self.fillOffsetX, 0, targetWidth, barH);
    } completion:nil];

    [UIView animateWithDuration:0.35 delay:0.12 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.damageFillContainer.frame = CGRectMake(self.fillOffsetX, 0, targetWidth, barH);
    } completion:nil];

    // 4. Status Effect Badges (pixel icons, rendered directly to the left of the portrait)
    std::vector<int> activeStatusIndices;
    if (data.flags & FLAG_POISON)    activeStatusIndices.push_back(5);  // Green droplet
    if (data.flags & FLAG_BURN)      activeStatusIndices.push_back(0);  // Orange flame
    if (data.flags & FLAG_FREEZE)    activeStatusIndices.push_back(12); // Cyan snowflake
    if (data.flags & FLAG_SLOW)      activeStatusIndices.push_back(6);  // Snail
    if (data.flags & FLAG_CHARM)     activeStatusIndices.push_back(1);  // Pink heart
    if (data.flags & FLAG_FEAR)      activeStatusIndices.push_back(3);  // Purple face
    if (data.flags & FLAG_CONFUSION) activeStatusIndices.push_back(2);  // Confusion stars

    while (_statusIcons.count < activeStatusIndices.size()) {
        CGFloat sSize = 16.0 * _pixelScale;
        UIImageView *iv = [[UIImageView alloc] initWithFrame:CGRectMake(0, (barH - sSize) / 2.0, sSize, sSize)];
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

    // Align status badges right-to-left towards the boss portrait
    CGFloat badgeSize = 16.0 * _pixelScale;
    CGFloat badgeSpacing = 3.0;
    CGFloat rightEdge = _extraLeftPad - 2.0;

    for (size_t i = 0; i < activeStatusIndices.size(); ++i) {
        UIImageView *iv = _statusIcons[i];
        iv.image = [cache statusIconForIndex:activeStatusIndices[i] bundle:bundle];
        CGFloat x = rightEdge - (i + 1) * badgeSize - i * badgeSpacing;
        iv.frame = CGRectMake(x, (barH - badgeSize) / 2.0, badgeSize, badgeSize);
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

    CGFloat pixelScale = 1.75;
    CGFloat extraLeftPad = 48.0;
    CGFloat singleBarW = 160.0 * pixelScale + extraLeftPad; // 328 pt
    CGFloat singleBarH = 32.0 * pixelScale;                 // 56 pt
    CGFloat bottomInset = 16.0;
    if (@available(iOS 11.0, *)) {
        bottomInset = MAX(bottomInset, window.safeAreaInsets.bottom + 4.0);
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

    // Scan entities in current room
    uintptr_t entitiesArrayPtr = 0;
    int32_t count = 0;
    if (!SafeRead(room + kRoomEntitiesArrayOffset, entitiesArrayPtr) || !entitiesArrayPtr ||
        !SafeRead(room + kRoomEntitiesCountOffset, count) || count <= 0 || count > 2048) {
        [self setOverlayVisible:NO];
        return;
    }

    // 1. Check if any Ultra Harbinger is present and actively alive during the Beast fight
    bool hasActiveHarbinger = false;
    for (int32_t i = 0; i < count; ++i) {
        uintptr_t entity = 0;
        if (!SafeRead(entitiesArrayPtr + i * sizeof(uintptr_t), entity) || !entity) continue;
        uint8_t isDead = 0;
        SafeRead(entity + kEntityIsDeadOffset, isDead);
        if (isDead) continue;
        int32_t type = 0, variant = 0;
        if (!SafeRead(entity + kEntityTypeOffset, type)) continue;
        SafeRead(entity + kEntityVariantOffset, variant);
        if (type == 951 && (variant == 10 || variant == 20 || variant == 30 || variant == 40)) {
            float hp = 0.0f;
            SafeRead(entity + kEntityHPOffset, hp);
            if (hp > 0.0f) {
                hasActiveHarbinger = true;
                break;
            }
        }
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

        // Skip dormant Beast (Variant 0) while Ultra Harbingers are still being fought
        if (type == 951 && variant == 0 && hasActiveHarbinger) {
            continue;
        }

        float hp = 0.0f;
        float maxHp = 0.0f;
        if (!SafeRead(entity + kEntityHPOffset, hp) || hp <= 0.0f) continue;
        SafeRead(entity + kEntityMaxHPOffset, maxHp);
        if (maxHp <= 0.0f) continue;

        const BossBarInfo *info = FindBossInfo(type, variant);

        // Eligible if in database OR in a boss room with significant HP
        if (info || (roomType == 5 && maxHp >= 40.0f)) {
            // Deduplicate multi-part / subsidiary entities of the same boss
            // For Type 951 (Harbingers & Beast), variants are distinct bosses
            bool foundExisting = false;
            for (auto &existing : activeBosses) {
                bool isSameBoss = (type == 951) ? (existing.type == type && existing.variant == variant)
                                                : (existing.type == type);
                if (isSameBoss) {
                    foundExisting = true;
                    // Adopt main body with highest maxHP
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
            if (foundExisting) continue;

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

            if (activeBosses.size() >= 4) break;
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
    CGFloat extraLeftPad = 48.0;
    CGFloat singleBarW = 160.0 * pixelScale + extraLeftPad; // 328.0 pt
    CGFloat singleBarH = 32.0 * pixelScale;                 // 56.0 pt
    CGFloat spacing = 4.0;
    CGFloat totalH = bosses.size() * singleBarH + (bosses.size() - 1) * spacing;

    UIWindow *window = self.rootView.window ?: [self findGameWindow];
    CGFloat bottomInset = 16.0;
    if (@available(iOS 11.0, *)) {
        if (window) bottomInset = MAX(bottomInset, window.safeAreaInsets.bottom + 4.0);
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

    // Stack bottom-up (main boss at bottom)
    for (size_t i = 0; i < bosses.size(); ++i) {
        SingleBossBarView *view = self.barViews[i];
        CGFloat y = (bosses.size() - 1 - i) * (singleBarH + spacing);
        view.frame = CGRectMake(0, y, singleBarW, singleBarH);
        [view updateWithData:bosses[i] bundle:self.modBundle];
    }
}

@end
