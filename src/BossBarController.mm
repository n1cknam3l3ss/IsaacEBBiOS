#import "BossBarController.h"
#import "BossBarData.h"
#import "BossBarMemory.h"
#import "BossBarLogger.h"

#import <QuartzCore/QuartzCore.h>
#import <vector>
#import <string>

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

// Entity Flags
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
    float currentHP;
    float maxHP;
    uint64_t flags;
};

// Passthrough view that ignores all touch events so Isaac's controls receive them
@interface BossBarPassthroughView : UIView
@end

@implementation BossBarPassthroughView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    return nil; // Always pass through
}
@end

// Single boss health bar view
@interface SingleBossBarView : UIView

@property (nonatomic, strong) UIImageView *iconView;
@property (nonatomic, strong) UIView *barContainer;
@property (nonatomic, strong) UIView *barDamageFill;
@property (nonatomic, strong) UIView *barFill;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UILabel *statusBadgeLabel;
@property (nonatomic, assign) float displayedHP;
@property (nonatomic, assign) float targetHP;
@property (nonatomic, assign) float maxHP;

- (void)updateWithData:(const ActiveBossData &)data bundle:(NSBundle *)bundle;

@end

@implementation SingleBossBarView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;

        // 1. Boss Icon
        _iconView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 26, 26)];
        _iconView.contentMode = UIViewContentModeScaleAspectFit;
        _iconView.layer.magnificationFilter = kCAFilterNearest;
        _iconView.layer.minificationFilter = kCAFilterNearest;
        _iconView.userInteractionEnabled = NO;
        [self addSubview:_iconView];

        // 2. Bar Frame Container
        CGFloat barX = 30.0;
        CGFloat barW = frame.size.width - barX;
        _barContainer = [[UIView alloc] initWithFrame:CGRectMake(barX, 4, barW, 18)];
        _barContainer.backgroundColor = [UIColor colorWithRed:0.12 green:0.12 blue:0.14 alpha:0.88];
        _barContainer.layer.borderColor = [UIColor colorWithRed:0.28 green:0.28 blue:0.32 alpha:0.95].CGColor;
        _barContainer.layer.borderWidth = 1.0;
        _barContainer.layer.cornerRadius = 3.0;
        _barContainer.clipsToBounds = YES;
        _barContainer.userInteractionEnabled = NO;
        [self addSubview:_barContainer];

        // 3. Delayed Damage Flash Fill (yellow/white)
        _barDamageFill = [[UIView alloc] initWithFrame:_barContainer.bounds];
        _barDamageFill.backgroundColor = [UIColor colorWithRed:0.95 green:0.85 blue:0.45 alpha:0.8];
        _barDamageFill.userInteractionEnabled = NO;
        [_barContainer addSubview:_barDamageFill];

        // 4. Main HP Fill (crimson / red)
        _barFill = [[UIView alloc] initWithFrame:_barContainer.bounds];
        _barFill.backgroundColor = [UIColor colorWithRed:0.88 green:0.18 blue:0.22 alpha:0.95];
        _barFill.userInteractionEnabled = NO;
        [_barContainer addSubview:_barFill];

        // 5. Title & HP Percentage Label
        _titleLabel = [[UILabel alloc] initWithFrame:_barContainer.bounds];
        _titleLabel.textColor = UIColor.whiteColor;
        _titleLabel.font = [UIFont boldSystemFontOfSize:10.0];
        _titleLabel.textAlignment = NSTextAlignmentCenter;
        _titleLabel.shadowColor = [UIColor colorWithWhite:0.0 alpha:0.9];
        _titleLabel.shadowOffset = CGSizeMake(1.0, 1.0);
        _titleLabel.userInteractionEnabled = NO;
        [_barContainer addSubview:_titleLabel];

        // 6. Status Effects badge label (Poison, Burn, Freeze, etc.)
        _statusBadgeLabel = [[UILabel alloc] initWithFrame:CGRectMake(barX, -10, barW, 12)];
        _statusBadgeLabel.textColor = UIColor.whiteColor;
        _statusBadgeLabel.font = [UIFont systemFontOfSize:8.5 weight:UIFontWeightMedium];
        _statusBadgeLabel.textAlignment = NSTextAlignmentRight;
        _statusBadgeLabel.shadowColor = [UIColor colorWithWhite:0 alpha:0.8];
        _statusBadgeLabel.shadowOffset = CGSizeMake(1.0, 1.0);
        _statusBadgeLabel.userInteractionEnabled = NO;
        [self addSubview:_statusBadgeLabel];
    }
    return self;
}

- (void)updateWithData:(const ActiveBossData &)data bundle:(NSBundle *)bundle {
    _targetHP = data.currentHP;
    _maxHP = data.maxHP > 0.0f ? data.maxHP : 1.0f;

    // Load Icon
    NSString *iconRel = [NSString stringWithUTF8String:data.iconRelPath.c_str()];
    UIImage *icon = nil;
    if (bundle) {
        NSString *fullPath = [bundle.resourcePath stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"bosshp_icons/%@", iconRel]];
        icon = [UIImage imageWithContentsOfFile:fullPath];
        if (!icon) {
            fullPath = [bundle.resourcePath stringByAppendingPathComponent:iconRel];
            icon = [UIImage imageWithContentsOfFile:fullPath];
        }
    }
    if (!icon) {
        // Fallback search in app bundle
        NSString *fullPath = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:
                              [NSString stringWithFormat:@"bosshp_icons/%@", iconRel]];
        icon = [UIImage imageWithContentsOfFile:fullPath];
    }
    _iconView.image = icon;

    // Smooth HP animation
    float ratio = MAX(0.0f, MIN(1.0f, data.currentHP / _maxHP));
    CGFloat totalW = _barContainer.bounds.size.width;
    CGFloat targetW = totalW * ratio;

    [UIView animateWithDuration:0.15 delay:0 options:UIViewAnimationOptionCurveEaseOut animations:^{
        self.barFill.frame = CGRectMake(0, 0, targetW, self.barContainer.bounds.size.height);
    } completion:nil];

    [UIView animateWithDuration:0.45 delay:0.1 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.barDamageFill.frame = CGRectMake(0, 0, targetW, self.barContainer.bounds.size.height);
    } completion:nil];

    // Label Text
    int percent = (int)ceil(ratio * 100.0f);
    int curHP = (int)ceil(data.currentHP);
    int maxHP = (int)ceil(data.maxHP);
    NSString *bossName = [NSString stringWithUTF8String:data.name.c_str()];
    _titleLabel.text = [NSString stringWithFormat:@"%@  %d%% (%d/%d)", bossName, percent, curHP, maxHP];

    // Status Badges
    NSMutableArray<NSString *> *statusBadges = [NSMutableArray array];
    if (data.flags & FLAG_POISON) [statusBadges addObject:@"☠ Poison"];
    if (data.flags & FLAG_BURN) [statusBadges addObject:@"🔥 Burn"];
    if (data.flags & FLAG_FREEZE) [statusBadges addObject:@"❄ Freeze"];
    if (data.flags & FLAG_SLOW) [statusBadges addObject:@"⏱ Slow"];
    if (data.flags & FLAG_CHARM) [statusBadges addObject:@"💖 Charm"];
    if (data.flags & FLAG_FEAR) [statusBadges addObject:@"👻 Fear"];

    if (statusBadges.count > 0) {
        _statusBadgeLabel.text = [statusBadges componentsJoinedByString:@" "];
        _statusBadgeLabel.hidden = NO;
    } else {
        _statusBadgeLabel.hidden = YES;
    }
}

@end

// Master Controller
@interface BossBarController ()

@property (nonatomic, strong) BossBarPassthroughView *rootView;
@property (nonatomic, strong) UIView *containerView;
@property (nonatomic, strong) NSMutableArray<SingleBossBarView *> *barViews;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, assign) uintptr_t baseAddress;
@property (nonatomic, strong) NSBundle *modBundle;

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
    return fallback;
}

- (void)setupOverlayIfNeeded {
    UIWindow *window = [self findGameWindow];
    if (!window || CGRectIsEmpty(window.bounds)) return;
    if (self.rootView.superview == window) return;

    [self.rootView removeFromSuperview];

    self.rootView = [[BossBarPassthroughView alloc] initWithFrame:window.bounds];
    self.rootView.backgroundColor = UIColor.clearColor;
    self.rootView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.rootView.userInteractionEnabled = NO;

    CGFloat barW = 280.0;
    CGFloat barH = 34.0;
    CGFloat maxW = MIN(barW, window.bounds.size.width - 40.0);
    CGFloat bottomInset = 16.0;
    if (@available(iOS 11.0, *)) {
        bottomInset = MAX(bottomInset, window.safeAreaInsets.bottom + 8.0);
    }

    self.containerView = [[UIView alloc] initWithFrame:CGRectMake((window.bounds.size.width - maxW) / 2.0,
                                                                  window.bounds.size.height - barH - bottomInset,
                                                                  maxW, barH)];
    self.containerView.backgroundColor = UIColor.clearColor;
    self.containerView.userInteractionEnabled = NO;
    self.containerView.alpha = 0.0;
    self.containerView.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin |
                                          UIViewAutoresizingFlexibleRightMargin |
                                          UIViewAutoresizingFlexibleTopMargin;
    [self.rootView addSubview:self.containerView];
    [window addSubview:self.rootView];

    BossBarLog(@"Attached Enhanced Boss Bars overlay to game window (frame: %@)", NSStringFromCGRect(window.bounds));
}

- (void)start {
    BossBarLog(@"Starting Enhanced Boss Bars controller...");
    [self setupOverlayIfNeeded];

    if (!self.displayLink) {
        self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(tick:)];
        if (@available(iOS 15.0, *)) {
            self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(30, 60, 60);
        }
        [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
    }
}

- (void)stop {
    [self.displayLink invalidate];
    self.displayLink = nil;
    [self.rootView removeFromSuperview];
    self.rootView = nil;
}

- (void)tick:(CADisplayLink *)link {
    if (!self.baseAddress) {
        self.baseAddress = BossBarGetBaseAddress();
        if (!self.baseAddress) return;
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

    for (int32_t i = 0; i < count; ++i) {
        uintptr_t entity = 0;
        if (!SafeRead(entitiesArrayPtr + i * sizeof(uintptr_t), entity) || !entity) continue;

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

        const BossBarInfo *info = FindBossInfo(type, variant);
        // Eligible if in database OR in a boss room with significant HP
        if (info || (roomType == 5 && maxHp >= 80.0f)) {
            ActiveBossData b;
            b.entityPtr = entity;
            b.type = type;
            b.variant = variant;
            b.name = info ? info->name : "Boss";
            b.iconRelPath = info ? info->iconRelPath : "boss.png";
            b.currentHP = hp;
            b.maxHP = maxHp;

            uint64_t flags = 0;
            SafeRead(entity + kEntityFlagsOffset, flags);
            b.flags = flags;

            activeBosses.push_back(b);
            if (activeBosses.size() >= 4) break; // Limit to 4 bars max
        }
    }

    if (activeBosses.empty()) {
        [self setOverlayVisible:NO];
        return;
    }

    [self updateBarsWithBosses:activeBosses];
    [self setOverlayVisible:YES];
}

- (void)setOverlayVisible:(BOOL)visible {
    if ((self.containerView.alpha > 0.0) == visible) return;

    [UIView animateWithDuration:0.25 delay:0 options:UIViewAnimationOptionCurveEaseInOut animations:^{
        self.containerView.alpha = visible ? 1.0 : 0.0;
    } completion:nil];
}

- (void)updateBarsWithBosses:(const std::vector<ActiveBossData> &)bosses {
    CGFloat barH = 30.0;
    CGFloat spacing = 6.0;
    CGFloat totalH = bosses.size() * barH + (bosses.size() - 1) * spacing;

    UIWindow *window = self.rootView.window;
    if (!window) window = [self findGameWindow];
    CGFloat bottomInset = 16.0;
    if (@available(iOS 11.0, *)) {
        if (window) bottomInset = MAX(bottomInset, window.safeAreaInsets.bottom + 8.0);
    }

    CGFloat maxW = self.containerView.bounds.size.width;
    CGRect newFrame = CGRectMake((window.bounds.size.width - maxW) / 2.0,
                                 window.bounds.size.height - totalH - bottomInset,
                                 maxW, totalH);
    self.containerView.frame = newFrame;

    // Adjust view count
    while (self.barViews.count < bosses.size()) {
        SingleBossBarView *barView = [[SingleBossBarView alloc] initWithFrame:CGRectMake(0, 0, maxW, barH)];
        [self.containerView addSubview:barView];
        [self.barViews addObject:barView];
    }
    while (self.barViews.count > bosses.size()) {
        SingleBossBarView *last = [self.barViews lastObject];
        [last removeFromSuperview];
        [self.barViews removeLastObject];
    }

    // Layout each bar view
    for (size_t i = 0; i < bosses.size(); ++i) {
        SingleBossBarView *view = self.barViews[i];
        CGFloat y = (bosses.size() - 1 - i) * (barH + spacing); // main boss at bottom, helpers stacked upward
        view.frame = CGRectMake(0, y, maxW, barH);
        [view updateWithData:bosses[i] bundle:self.modBundle];
    }
}

@end
