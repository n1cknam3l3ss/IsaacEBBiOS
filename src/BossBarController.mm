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

// Engine Game state offsets (cutscenes, VS splash screen, gameplay active)
static constexpr size_t kGameVersusScreenOffset = 0x25810;
static constexpr size_t kGameIsGameplayActiveOffset = 0x10d45a;
static constexpr size_t kGameCutsceneEventOffset = 0x21560;

// Entity offsets
static constexpr size_t kEntityTypeOffset = 0x38;
static constexpr size_t kEntityVariantOffset = 0x3C;
static constexpr size_t kEntitySubTypeOffset = 0x40;
static constexpr size_t kEntityFlagsOffset = 0x560;
static constexpr size_t kEntityIsDeadOffset = 0x1C3;
static constexpr size_t kEntityHPOffset = 0x354;
static constexpr size_t kEntityMaxHPOffset = 0x358;
static constexpr size_t kEntityParentOffset = 0x6e0;

// Engine Flags (exact Repentance bitshifts)
static constexpr uint64_t FLAG_BOSSDEATH_TRIGGERED = 1ULL << 20;
static constexpr uint64_t FLAG_FRIENDLY            = 1ULL << 29;
static constexpr uint64_t FLAG_DONT_COUNT_BOSS_HP  = 1ULL << 31;

// Entity Status Flags (exact bitshifts in The Binding of Isaac: Repentance)
static constexpr uint64_t FLAG_FREEZE     = 1ULL << 5;
static constexpr uint64_t FLAG_POISON     = 1ULL << 6;
static constexpr uint64_t FLAG_SLOW       = 1ULL << 7;
static constexpr uint64_t FLAG_CHARM      = 1ULL << 8;
static constexpr uint64_t FLAG_CONFUSION  = 1ULL << 9;
static constexpr uint64_t FLAG_FEAR       = 1ULL << 11;
static constexpr uint64_t FLAG_BURN       = 1ULL << 12;
static constexpr uint64_t FLAG_BLEED_OUT  = 1ULL << 39;
static constexpr uint64_t FLAG_BAITED     = 1ULL << 40;
static constexpr uint64_t FLAG_MAGNETIZED = 1ULL << 44;
static constexpr uint64_t FLAG_WEAKNESS   = 1ULL << 45;

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
        entry.damageFlashImage = TintImage(entry.fillImage, [UIColor colorWithWhite:1.0 alpha:0.95]);
    }
    // 2. Colostomia (crop at X=170)
    else if ([lowerKey containsString:@"colostomia"]) {
        UIImage *rawFill = SliceCGImage(cgSheet, CGRectMake(170, 0, 120, 32));
        entry.fillImage = rawFill;
        entry.damageFlashImage = TintImage(rawFill, [UIColor colorWithWhite:1.0 alpha:0.95]);
    }
    // 3. Thematic / Standard boss bars
    else {
        UIImage *rawFill = SliceCGImage(cgSheet, CGRectMake(20, 0, 120, 32));
        if (style.isDefaultTint) {
            // Authentic Repentance red tint: (0.84, 0.12, 0.15)
            entry.fillImage = TintImage(rawFill, [UIColor colorWithRed:0.84 green:0.12 blue:0.15 alpha:1.0]);
            // Bright white damage flash
            entry.damageFlashImage = TintImage(rawFill, [UIColor colorWithWhite:1.0 alpha:0.95]);
        } else {
            // Natural thematic texture color (Delirium yellow, Mother bone, Beast lava, etc.)
            entry.fillImage = rawFill;
            // Bright white damage flash
            entry.damageFlashImage = TintImage(rawFill, [UIColor colorWithWhite:1.0 alpha:0.95]);
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

@property (nonatomic, strong) UIImageView *bgImageView;
@property (nonatomic, strong) UIView *fillContainer;
@property (nonatomic, strong) UIImageView *fillImageView;
@property (nonatomic, strong) UIImageView *fillFlashImageView;
@property (nonatomic, strong) UIImageView *overlayImageView;
@property (nonatomic, strong) UIImageView *iconView;

@property (nonatomic, strong) UIView *statusContainer;
@property (nonatomic, strong) NSMutableArray<UIImageView *> *statusIcons;

@property (nonatomic, assign) CGFloat pixelScale;
@property (nonatomic, assign) CGFloat barW;
@property (nonatomic, assign) CGFloat barH;
@property (nonatomic, assign) CGFloat fillOffsetX;
@property (nonatomic, assign) CGFloat fillTotalWidth;

@property (nonatomic, assign) uintptr_t currentEntityPtr;
@property (nonatomic, assign) float lastHP;

- (void)applyScale:(CGFloat)scale;
- (void)updateWithData:(const ActiveBossData &)data bundle:(NSBundle *)bundle;

@end

@implementation SingleBossBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = NO; // Allow status badges floating above to render without clipping

        _pixelScale = 1.6;
        _barW = 160.0 * _pixelScale;
        _barH = 32.0 * _pixelScale;
        _fillOffsetX = 20.0 * _pixelScale;
        _fillTotalWidth = 120.0 * _pixelScale;
        _statusIcons = [NSMutableArray array];
        _lastHP = -1.0f;
        _currentEntityPtr = 0;

        // 1. Status effects container (floats directly above the bar, Y = -18.0 * scale)
        _statusContainer = [[UIView alloc] initWithFrame:CGRectMake(0, -18.0 * _pixelScale, _barW, 16.0 * _pixelScale)];
        _statusContainer.backgroundColor = UIColor.clearColor;
        _statusContainer.userInteractionEnabled = NO;
        _statusContainer.clipsToBounds = NO;
        [self addSubview:_statusContainer];

        // 2. Background Frame Sprite
        _bgImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, _barW, _barH)];
        _bgImageView.contentMode = UIViewContentModeScaleToFill;
        _bgImageView.layer.magnificationFilter = kCAFilterNearest;
        _bgImageView.layer.minificationFilter = kCAFilterNearest;
        _bgImageView.userInteractionEnabled = NO;
        [self addSubview:_bgImageView];

        // 3. Main HP Fill Container
        _fillContainer = [[UIView alloc] initWithFrame:CGRectMake(_fillOffsetX, 0, _fillTotalWidth, _barH)];
        _fillContainer.clipsToBounds = YES;
        _fillContainer.backgroundColor = UIColor.clearColor;
        _fillContainer.userInteractionEnabled = NO;
        [self addSubview:_fillContainer];

        _fillImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, _fillTotalWidth, _barH)];
        _fillImageView.contentMode = UIViewContentModeScaleToFill;
        _fillImageView.layer.magnificationFilter = kCAFilterNearest;
        _fillImageView.layer.minificationFilter = kCAFilterNearest;
        _fillImageView.userInteractionEnabled = NO;
        [_fillContainer addSubview:_fillImageView];

        // 4. White Damage Flash View (flashes on damage hit, 0 decaying tail)
        _fillFlashImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, _fillTotalWidth, _barH)];
        _fillFlashImageView.contentMode = UIViewContentModeScaleToFill;
        _fillFlashImageView.layer.magnificationFilter = kCAFilterNearest;
        _fillFlashImageView.layer.minificationFilter = kCAFilterNearest;
        _fillFlashImageView.userInteractionEnabled = NO;
        _fillFlashImageView.alpha = 0.0;
        [_fillContainer addSubview:_fillFlashImageView];

        // 5. Thematic Overlay Sprite (Mother creeping bones, Beast fire)
        _overlayImageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, _barW, _barH)];
        _overlayImageView.contentMode = UIViewContentModeScaleToFill;
        _overlayImageView.layer.magnificationFilter = kCAFilterNearest;
        _overlayImageView.layer.minificationFilter = kCAFilterNearest;
        _overlayImageView.userInteractionEnabled = NO;
        [self addSubview:_overlayImageView];

        // 6. Boss Portrait Icon (centered at X=16, Y=16 to seamlessly sit in notch)
        CGFloat iconCenter = 16.0 * _pixelScale;
        CGFloat defaultIconSize = 32.0 * _pixelScale;
        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(iconCenter - defaultIconSize / 2.0,
                                                                 iconCenter - defaultIconSize / 2.0,
                                                                 defaultIconSize, defaultIconSize)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.magnificationFilter = kCAFilterNearest;
        _iconView.layer.minificationFilter = kCAFilterNearest;
        _iconView.userInteractionEnabled = NO;
        [self addSubview:_iconView];
    }
    return self;
}

- (void)applyScale:(CGFloat)scale {
    if (fabs(_pixelScale - scale) < 0.001) return;
    _pixelScale = scale;
    _barW = 160.0 * scale;
    _barH = 32.0 * scale;
    _fillOffsetX = 20.0 * scale;
    _fillTotalWidth = 120.0 * scale;

    self.bounds = CGRectMake(0, 0, _barW, _barH);
    _bgImageView.frame = CGRectMake(0, 0, _barW, _barH);
    _overlayImageView.frame = CGRectMake(0, 0, _barW, _barH);

    CGFloat currentRatio = (_lastHP > 0.0f) ? (_fillContainer.frame.size.width / (_fillTotalWidth > 0 ? _fillTotalWidth : 1.0)) : 1.0;
    _fillContainer.frame = CGRectMake(_fillOffsetX, 0, _fillTotalWidth * currentRatio, _barH);
    _fillImageView.frame = CGRectMake(0, 0, _fillTotalWidth, _barH);
    _fillFlashImageView.frame = CGRectMake(0, 0, _fillTotalWidth, _barH);

    _statusContainer.frame = CGRectMake(0, -18.0 * scale, _barW, 16.0 * scale);

    CGFloat centerCoord = 16.0 * scale;
    CGFloat iconSize = (_iconView.frame.size.width > 40.0 * scale) ? (64.0 * scale) : (32.0 * scale);
    _iconView.frame = CGRectMake(centerCoord - iconSize / 2.0, centerCoord - iconSize / 2.0, iconSize, iconSize);
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
        _fillFlashImageView.image = entry.damageFlashImage;
        _overlayImageView.image = entry.overlayImage;
        _overlayImageView.hidden = (entry.overlayImage == nil);

        // Animated TV static for Dogma bar fill
        if (entry.fillAnimationImages.count > 1) {
            if (![_fillImageView.animationImages isEqualToArray:entry.fillAnimationImages]) {
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
        CGFloat size = iconEntry.isLarge ? (64.0 * _pixelScale) : (32.0 * _pixelScale);
        _iconView.frame = CGRectMake(centerCoord - size / 2.0, centerCoord - size / 2.0, size, size);

        if (iconEntry.animationImages.count > 1) {
            if (![_iconView.animationImages isEqualToArray:iconEntry.animationImages]) {
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

    // 3. Crisp HP bar update & Damage Flash
    float currentHP = data.currentHP;
    float maxHP = data.maxHP > 0.0f ? data.maxHP : 1.0f;
    float targetRatio = MAX(0.0f, MIN(1.0f, currentHP / maxHP));
    CGFloat targetWidth = _fillTotalWidth * targetRatio;

    if (self.currentEntityPtr == data.entityPtr) {
        // Flash bright white on damage hit (like in game)
        if (self.lastHP > 0.0f && currentHP < self.lastHP - 0.001f) {
            self.fillFlashImageView.alpha = 1.0;
            [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
                self.fillFlashImageView.alpha = 0.0;
            } completion:nil];
        }
    } else {
        self.currentEntityPtr = data.entityPtr;
        self.fillFlashImageView.alpha = 0.0;
    }
    self.lastHP = currentHP;

    // Immediate crisp bar update (no fading / decaying tail)
    [UIView animateWithDuration:0.06 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.fillContainer.frame = CGRectMake(self.fillOffsetX, 0, targetWidth, self.barH);
    } completion:nil];

    // 4. Status Effect Badges (disabled until exact status bitfield offset is verified)
    _statusContainer.hidden = YES;
    for (UIImageView *iv in _statusIcons) {
        [iv removeFromSuperview];
    }
    [_statusIcons removeAllObjects];
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

    CGFloat initialW = 256.0;
    CGFloat initialH = 51.2;
    CGFloat bottomInset = 16.0;
    if (@available(iOS 11.0, *)) {
        bottomInset = MAX(bottomInset, window.safeAreaInsets.bottom + 4.0);
    }

    self.containerView = [[UIView alloc] initWithFrame:CGRectMake((window.bounds.size.width - initialW) / 2.0,
                                                                  window.bounds.size.height - initialH - bottomInset,
                                                                  initialW, initialH)];
    self.containerView.backgroundColor = UIColor.clearColor;
    self.containerView.userInteractionEnabled = NO;
    self.containerView.clipsToBounds = NO;
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

    // 1. Versus intro splash screen ("Isaac VS ...") check:
    // When Isaac enters a boss room, an intro animation plays (versusState 1..4).
    // The boss bar must remain hidden until the VS splash animation completes (versusState == 0).
    int32_t versusState = 0;
    if (SafeRead(game + kGameVersusScreenOffset, versusState) && versusState != 0) {
        [self setOverlayVisible:NO];
        return;
    }

    // 2. Active gameplay check:
    // Isaac engine sets Game + 0x10d45a to 0 during VS splash screen, room transitions, and pause/cutscenes.
    // Vanilla engine uses: ldrb w8, [Game + 0x10d45a]; cbz w8, SKIP_BOSS_BAR_RENDER.
    uint8_t isGameplayActive = 1;
    if (SafeRead(game + kGameIsGameplayActiveOffset, isGameplayActive) && isGameplayActive == 0) {
        [self setOverlayVisible:NO];
        return;
    }

    // 3. Cutscene event check:
    // Non-zero when an in-game cutscene or cinematic is active.
    int32_t cutsceneEvent = 0;
    if (SafeRead(game + kGameCutsceneEventOffset, cutsceneEvent) && cutsceneEvent != 0) {
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
    if (roomType < 1 || roomType > 29) {
        roomType = 0;
    }

    // Only display boss bars in rooms that actually host boss fights:
    // RoomType 5:  ROOM_BOSS (Standard floor bosses, Delirium, Mother, Mega Satan, Beast)
    // RoomType 15: ROOM_BOSSRUSH (Boss Rush)
    // RoomType 6:  ROOM_MINIBOSS (Mini-boss rooms: Sins, Krampus)
    // RoomType 11: ROOM_CHALLENGE (Challenge room boss waves)
    bool isBossFightRoom = (roomType == 5 || roomType == 15 || roomType == 6 || roomType == 11);
    if (!isBossFightRoom) {
        [self setOverlayVisible:NO];
        return;
    }

    // Scan entities in current room
    uintptr_t entitiesArrayPtr = 0;
    int32_t count = 0;
    if (!SafeRead(room + kRoomEntitiesArrayOffset, entitiesArrayPtr) || !entitiesArrayPtr ||
        !SafeRead(room + kRoomEntitiesCountOffset, count) || count <= 0 || count > 2048) {
        [self setOverlayVisible:NO];
        return;
    }

    // 1. Pre-scan room for special boss encounters (Delirium isolation, Harbingers/Beast, Dogma)
    bool isDeliriumActive = false;
    bool hasDogmaPhase2 = false;
    bool hasBeastSilhouettes = false;
    int32_t activeHarbingerVariant = -1;

    for (int32_t i = 0; i < count; ++i) {
        uintptr_t entity = 0;
        if (!SafeRead(entitiesArrayPtr + i * sizeof(uintptr_t), entity) || !entity) continue;
        uint8_t isDead = 0;
        SafeRead(entity + kEntityIsDeadOffset, isDead);
        if (isDead) continue;

        float hp = 0.0f;
        SafeRead(entity + kEntityHPOffset, hp);
        if (hp <= 0.0f) continue;

        uint64_t flags = 0;
        SafeRead(entity + kEntityFlagsOffset, flags);
        // Skip dying/friendly entities or entities marked to not count boss HP
        if (flags & (FLAG_DONT_COUNT_BOSS_HP | FLAG_BOSSDEATH_TRIGGERED | FLAG_FRIENDLY)) continue;

        int32_t type = 0, variant = 0;
        if (!SafeRead(entity + kEntityTypeOffset, type)) continue;
        SafeRead(entity + kEntityVariantOffset, variant);

        if (type == 412) {
            isDeliriumActive = true;
        }
        if (type == 950 && variant == 2) {
            hasDogmaPhase2 = true;
        }
        if (type == 951) {
            if (variant >= 100 && variant <= 104) {
                hasBeastSilhouettes = true;
            } else if (variant == 10 || variant == 20 || variant == 30 || variant == 40) {
                if (variant > activeHarbingerVariant) {
                    activeHarbingerVariant = variant;
                }
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

        float hp = 0.0f;
        SafeRead(entity + kEntityHPOffset, hp);
        if (hp <= 0.0f) continue;

        float maxHp = 0.0f;
        SafeRead(entity + kEntityMaxHPOffset, maxHp);
        if (maxHp <= 0.0f) continue;

        uint64_t flags = 0;
        SafeRead(entity + kEntityFlagsOffset, flags);
        // Exclude cutscenes, dying bosses, or friendly entities
        if (flags & (FLAG_DONT_COUNT_BOSS_HP | FLAG_BOSSDEATH_TRIGGERED | FLAG_FRIENDLY)) continue;

        int32_t type = 0;
        int32_t variant = 0;
        if (!SafeRead(entity + kEntityTypeOffset, type)) continue;
        SafeRead(entity + kEntityVariantOffset, variant);

        // Filter: only boss NPCs (type >= 10 && < 1000)
        if (type < 10 || type >= 1000) continue;

        // 1. Delirium isolation: when Delirium is alive, ignore all other boss types/transformations!
        if (isDeliriumActive && type != 412) continue;

        // 2. Dogma (Type 950):
        if (type == 950) {
            // Ignore cord baby (Variant 0)
            if (variant != 1 && variant != 2) continue;
            // When Phase 2 (Angel) is active, skip destroyed TV (Variant 1)
            if (variant == 1 && hasDogmaPhase2) continue;
        }

        // 3. The Beast & Ultra Harbingers (Type 951):
        if (type == 951) {
            // Ignore silhouettes and sub-parts
            if (variant != 0 && variant != 10 && variant != 20 && variant != 30 && variant != 40) {
                continue;
            }
            if (hasBeastSilhouettes) {
                // Beast is swimming in background: NEVER accept Beast (Variant 0)
                if (variant == 0) continue;
                // Only accept active Harbinger; if none engaged yet, skip!
                if (activeHarbingerVariant <= 0 || variant != activeHarbingerVariant) continue;
            } else if (activeHarbingerVariant > 0) {
                // Harbingers are active: ONLY accept active Harbinger
                if (variant != activeHarbingerVariant) continue;
            } else {
                // Harbingers defeated & no silhouettes: The Beast itself!
                if (variant != 0) continue;
            }
        }

        // 4. Segmented worm bosses (Larry Jr 19, Chub/Chad/Carrion 28, Pin/Scolex/Frail/Wormwood 62, Turdlet 918)
        bool isSegmentedWorm = (type == 19 || type == 28 || type == 62 || type == 918);

        // 5. Boss Ignore List & sub-entities
        if (type == 45 && variant == 0) continue;    // Mom doors (Mom herself is 45.10)
        if (type == 79 && variant == 12) continue;   // Blighted Ovum invincible ghost
        if (type == 79 && (variant == 0 || variant == 1 || variant == 2)) {
            // Prevent umbilical cord segments or clone helpers from duplicating main twin bar
            bool alreadyExists = false;
            for (const auto &existing : activeBosses) {
                if (existing.type == 79 && existing.variant == variant) {
                    alreadyExists = true;
                    break;
                }
            }
            if (alreadyExists) continue;
        }
        if (type == 266 && (variant == 1 || variant == 2)) continue; // Mama Gurdy hands
        if (type == 294 && variant == 0) continue;   // Ultra Greed door
        if (type == 404 && variant != 0) continue;   // Little Horn black holes / balls
        if (type == 411 && variant != 0) continue;   // Big Horn sub / holes
        if (type == 866 && variant == 0) continue;   // Dark Esau (player hazard, not room boss)
        if (type == 867 && variant == 0) continue;   // Mother's shadow
        if (type == 906 && variant == 1) continue;   // Hornfel decoy
        if (type == 912 && (variant == 30 || variant == 100)) continue; // Mother attacks
        if (type == 919 && variant == 1) continue;   // Raglich arm
        if (type == 964 && variant == 0) continue;   // Dummy NPC

        const BossBarInfo *info = FindBossInfo(type, variant);
        if (!info) continue; // ONLY real verified bosses get health bars!

        // Check phase replacement & segmented boss merging
        bool shouldMergeOrReplace = false;
        for (auto &existing : activeBosses) {
            // Segmented worm bosses: sum all segments into 1 unified health bar!
            if (isSegmentedWorm && existing.type == type && existing.variant == variant) {
                existing.currentHP += hp;
                existing.maxHP += maxHp;
                shouldMergeOrReplace = true;
                break;
            }

            if (type == 950 && existing.type == 950) {
                // Dogma Phase 2 (Angel) replaces Phase 1 (TV)
                if (variant == 2 && existing.variant == 1) {
                    existing.entityPtr = entity;
                    existing.variant = variant;
                    existing.currentHP = hp;
                    existing.maxHP = maxHp;
                    existing.flags = flags;
                    existing.name = info->name;
                    existing.iconRelPath = info->iconRelPath;
                    BossBarStyleInfo style = GetBarStyleInfo(info->barStyle);
                    existing.barRelPath = style.barRelPath;
                    existing.overlayRelPath = style.overlayRelPath ? style.overlayRelPath : "";
                    existing.isDefaultTint = style.isDefaultTint;
                    shouldMergeOrReplace = true;
                    break;
                }
            } else if (type == 951 && existing.type == 951) {
                // Beast sequence: active phase replaces previous
                if (variant != existing.variant) {
                    existing.entityPtr = entity;
                    existing.variant = variant;
                    existing.currentHP = hp;
                    existing.maxHP = maxHp;
                    existing.flags = flags;
                    existing.name = info->name;
                    existing.iconRelPath = info->iconRelPath;
                    BossBarStyleInfo style = GetBarStyleInfo(info->barStyle);
                    existing.barRelPath = style.barRelPath;
                    existing.overlayRelPath = style.overlayRelPath ? style.overlayRelPath : "";
                    existing.isDefaultTint = style.isDefaultTint;
                    shouldMergeOrReplace = true;
                    break;
                }
            } else if (type == 275 && existing.type == 274) {
                // Mega Satan Phase 2 replaces Phase 1
                existing.entityPtr = entity;
                existing.type = 275;
                existing.variant = variant;
                existing.currentHP = hp;
                existing.maxHP = maxHp;
                existing.flags = flags;
                existing.name = info->name;
                existing.iconRelPath = info->iconRelPath;
                BossBarStyleInfo style = GetBarStyleInfo(info->barStyle);
                existing.barRelPath = style.barRelPath;
                existing.overlayRelPath = style.overlayRelPath ? style.overlayRelPath : "";
                existing.isDefaultTint = style.isDefaultTint;
                shouldMergeOrReplace = true;
                break;
            }
        }
        if (shouldMergeOrReplace) {
            seenEntities.insert(entity);
            continue;
        }

        ActiveBossData b;
        b.entityPtr = entity;
        b.type = type;
        b.variant = variant;
        b.name = info->name;
        b.iconRelPath = info->iconRelPath;

        // Resolve authentic thematic bar style
        BossBarStyleInfo style = GetBarStyleInfo(info->barStyle);
        b.barRelPath = style.barRelPath;
        b.overlayRelPath = style.overlayRelPath ? style.overlayRelPath : "";
        b.isDefaultTint = style.isDefaultTint;

        b.currentHP = hp;
        b.maxHP = maxHp;
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

    // Visual sorting for Mega Satan fight: Left Hand (2), Head (0), Right Hand (1)
    bool hasMegaSatan = false;
    for (const auto &b : activeBosses) {
        if (b.type == 274) { hasMegaSatan = true; break; }
    }
    if (hasMegaSatan) {
        std::sort(activeBosses.begin(), activeBosses.end(), [](const ActiveBossData &a, const ActiveBossData &b) {
            if (a.type == 274 && b.type == 274) {
                auto rank = [](int32_t v) {
                    if (v == 2) return 0; // Left Hand
                    if (v == 0) return 1; // Head
                    if (v == 1) return 2; // Right Hand
                    return v + 3;
                };
                return rank(a.variant) < rank(b.variant);
            }
            return a.entityPtr < b.entityPtr;
        });
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
    size_t count = bosses.size();
    if (count == 0) return;

    // Dynamic horizontal scaling based on boss count:
    // 1 boss: scale 1.6  (256 pt width, single row at bottom)
    // 2 bosses: scale 1.25 (200 pt each, 14 pt spacing -> 414 pt total)
    // 3 bosses: scale 0.98 (156.8 pt each, 10 pt spacing -> 490.4 pt total)
    // 4 bosses: scale 0.82 (131.2 pt each, 8 pt spacing -> 548.8 pt total)
    CGFloat scale = 1.6;
    CGFloat spacing = 16.0;
    if (count == 2) {
        scale = 1.25;
        spacing = 14.0;
    } else if (count == 3) {
        scale = 0.98;
        spacing = 10.0;
    } else if (count >= 4) {
        scale = 0.82;
        spacing = 8.0;
    }

    CGFloat barW = 160.0 * scale;
    CGFloat barH = 32.0 * scale;
    CGFloat totalW = count * barW + (count - 1) * spacing;

    UIWindow *window = self.rootView.window ?: [self findGameWindow];
    CGFloat bottomInset = 16.0;
    if (@available(iOS 11.0, *)) {
        if (window) bottomInset = MAX(bottomInset, window.safeAreaInsets.bottom + 4.0);
    }

    CGRect newFrame = CGRectMake((window.bounds.size.width - totalW) / 2.0,
                                 window.bounds.size.height - barH - bottomInset,
                                 totalW, barH);
    self.containerView.frame = newFrame;

    // Adjust view count
    while (self.barViews.count < count) {
        SingleBossBarView *barView = [[SingleBossBarView alloc] initWithFrame:CGRectMake(0, 0, barW, barH)];
        [self.containerView addSubview:barView];
        [self.barViews addObject:barView];
    }
    while (self.barViews.count > count) {
        SingleBossBarView *last = [self.barViews lastObject];
        [last removeFromSuperview];
        [self.barViews removeLastObject];
    }

    // Lay out horizontally side-by-side from left to right on the bottom line
    for (size_t i = 0; i < count; ++i) {
        SingleBossBarView *view = self.barViews[i];
        [view applyScale:scale];
        CGFloat x = i * (barW + spacing);
        view.frame = CGRectMake(x, 0, barW, barH);
        [view updateWithData:bosses[i] bundle:self.modBundle];
    }
}

@end
