#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const CGBundleID = @"com.551.chatgpt14";
static const void *CGCoordinatorKey = &CGCoordinatorKey;
static const void *CGLayoutKey = &CGLayoutKey;
static __weak UIViewController *CGWebRoot = nil;

extern void CGPresentUnifiedMenu(UIViewController *presenter, BOOL nativeMode, id nativeChatController);
extern void CGCaptureWebRecentsFromRoot(UIViewController *root);
extern void CGResetLocalPromptCapture(void);
extern NSString *CGStoredSelectedWebURL(void);

UIViewController *CGCurrentWebRoot(void) {
    return CGWebRoot;
}

static BOOL CGClassNameContains(id object, NSString *needle) {
    if (!object) return NO;
    NSString *name = NSStringFromClass([object class]);
    return [name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound;
}

static UIView *CGFindView(UIView *root, NSString *needle) {
    if (!root) return nil;
    if (CGClassNameContains(root, needle)) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = CGFindView(subview, needle);
        if (found) return found;
    }
    return nil;
}

static UIView *CGFindFirstResponderView(UIView *root) {
    if (!root) return nil;
    if (root.isFirstResponder) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = CGFindFirstResponderView(subview);
        if (found) return found;
    }
    return nil;
}

static NSString *CGAXCombinedText(id element) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    NSString *label = [element accessibilityLabel];
    NSString *value = [element accessibilityValue];
    NSString *hint = [element accessibilityHint];
    NSString *identifier = [element accessibilityIdentifier];
    if (label.length) [parts addObject:label];
    if (value.length) [parts addObject:value];
    if (hint.length) [parts addObject:hint];
    if (identifier.length) [parts addObject:identifier];
    return [[parts componentsJoinedByString:@" "] lowercaseString];
}

static BOOL CGAXLooksLikeChatGPTComposer(id element) {
    NSString *text = CGAXCombinedText(element);
    if (!text.length) return NO;

    BOOL textMatches = NO;
    NSArray<NSString *> *needles = @[@"ask chatgpt", @"ask anything", @"message chatgpt", @"prompt chatgpt"];
    for (NSString *needle in needles) {
        if ([text rangeOfString:needle].location != NSNotFound) {
            textMatches = YES;
            break;
        }
    }
    if (!textMatches) return NO;

    CGRect frame = [element accessibilityFrame];
    if (CGRectIsEmpty(frame) || CGRectIsNull(frame) || CGRectIsInfinite(frame)) return NO;
    if (CGRectGetWidth(frame) < 120.0 || CGRectGetHeight(frame) < 24.0 || CGRectGetHeight(frame) > 180.0) return NO;
    return YES;
}

static id CGFindComposerAccessibilityElement(id node, NSMutableSet<NSValue *> *visited, NSInteger depth) {
    if (!node || depth > 16) return nil;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)node];
    if ([visited containsObject:key]) return nil;
    [visited addObject:key];

    // Search children before their container. Gecko often exposes both a large
    // composer container and the actual editable element with the same label;
    // the deepest matching element is the one that can really take focus.
    NSArray *elements = [node accessibilityElements];
    if ([elements isKindOfClass:NSArray.class]) {
        for (id child in elements) {
            id found = CGFindComposerAccessibilityElement(child, visited, depth + 1);
            if (found) return found;
        }
    }

    NSInteger count = [node accessibilityElementCount];
    if (count != NSNotFound && count > 0 && count < 512) {
        for (NSInteger index = 0; index < count; index++) {
            id child = [node accessibilityElementAtIndex:index];
            id found = CGFindComposerAccessibilityElement(child, visited, depth + 1);
            if (found) return found;
        }
    }

    if ([node isKindOfClass:UIView.class]) {
        for (UIView *subview in [(UIView *)node subviews]) {
            id found = CGFindComposerAccessibilityElement(subview, visited, depth + 1);
            if (found) return found;
        }
    }

    return CGAXLooksLikeChatGPTComposer(node) ? node : nil;
}

static id CGFindChatGPTComposerAX(UIView *root) {
    if (!root) return nil;
    return CGFindComposerAccessibilityElement(root, [NSMutableSet set], 0);
}

static UIButton *CGFindButtonForAction(UIView *root, NSString *needle) {
    if (!root) return nil;
    if ([root isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)root;
        for (id target in button.allTargets) {
            for (NSString *action in [button actionsForTarget:target forControlEvent:UIControlEventTouchUpInside]) {
                if ([action rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) return button;
            }
        }
    }
    for (UIView *subview in root.subviews) {
        UIButton *found = CGFindButtonForAction(subview, needle);
        if (found) return found;
    }
    return nil;
}

static BOOL CGURLIsChatGPT(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    NSString *host = url.host.lowercaseString ?: @"";
    return [host isEqualToString:@"chatgpt.com"] || [host isEqualToString:@"www.chatgpt.com"];
}

@interface CGShellCoordinator : NSObject
@property (nonatomic, weak) UIViewController *root;
@property (nonatomic, strong) UIView *header;
@property (nonatomic, strong) UIButton *menuButton;
@property (nonatomic, strong) UIButton *micButton;
@property (nonatomic, strong) UIButton *composeButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIImageView *webMenuRepairIcon;
@property (nonatomic, strong) UIImageView *composerPlusRepairIcon;
@property (nonatomic, strong) NSTimer *webIconRepairTimer;
@property (nonatomic, assign) BOOL didSeedWebChat;
- (instancetype)initWithRoot:(UIViewController *)root;
- (void)install;
- (void)layoutShell;
@end

@implementation CGShellCoordinator

- (instancetype)initWithRoot:(UIViewController *)root {
    if ((self = [super init])) _root = root;
    return self;
}

- (void)dealloc {
    [self.webIconRepairTimer invalidate];
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = UIColor.labelColor;
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
}

- (UIImageView *)repairIconWithSymbol:(NSString *)symbol pointSize:(CGFloat)pointSize {
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:pointSize weight:UIImageSymbolWeightRegular];
    UIImage *image = [[UIImage systemImageNamed:symbol] imageByApplyingSymbolConfiguration:config];
    UIImageView *view = [[UIImageView alloc] initWithImage:image];
    view.tintColor = UIColor.labelColor;
    view.contentMode = UIViewContentModeCenter;
    view.userInteractionEnabled = NO;
    view.backgroundColor = UIColor.clearColor;
    return view;
}

- (void)install {
    if (!self.root.isViewLoaded || self.header) return;
    CGWebRoot = self.root;

    UIView *header = [UIView new];
    header.backgroundColor = UIColor.systemBackgroundColor;
    header.layer.shadowColor = UIColor.separatorColor.CGColor;
    header.layer.shadowOpacity = 0.35;
    header.layer.shadowRadius = 0;
    header.layer.shadowOffset = CGSizeMake(0, 0.5);
    self.header = header;

    self.menuButton = [self buttonWithSymbol:@"line.horizontal.3" action:@selector(openMenu)];
    self.menuButton.accessibilityLabel = @"ChatGPT menu";
    [header addSubview:self.menuButton];

    self.micButton = [self buttonWithSymbol:@"mic.fill" action:@selector(typeDotForVoice)];
    self.micButton.accessibilityLabel = @"Show ChatGPT microphone";
    [header addSubview:self.micButton];

    self.composeButton = [self buttonWithSymbol:@"square.and.pencil" action:@selector(newWebChat)];
    self.composeButton.accessibilityLabel = @"New chat";
    [header addSubview:self.composeButton];

    UILabel *title = [UILabel new];
    title.text = @"ChatGPT";
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = UIColor.labelColor;
    title.textAlignment = NSTextAlignmentCenter;
    self.titleLabel = title;
    [header addSubview:title];

    // Old Gecko occasionally leaves ChatGPT's SVG symbols blank until they are
    // interacted with. These transparent native symbols sit over the genuine
    // web buttons; touches still go straight through to ChatGPT underneath.
    self.webMenuRepairIcon = [self repairIconWithSymbol:@"line.horizontal.3" pointSize:18.0];
    self.composerPlusRepairIcon = [self repairIconWithSymbol:@"plus" pointSize:20.0];
    [self.root.view addSubview:self.webMenuRepairIcon];
    [self.root.view addSubview:self.composerPlusRepairIcon];

    [self.root.view addSubview:header];
    [self.root.view bringSubviewToFront:header];
    [self layoutShell];
    [self seedWebChatIfNeeded];

    self.webIconRepairTimer = [NSTimer timerWithTimeInterval:0.35
                                                      target:self
                                                    selector:@selector(updateWebIconRepairs)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.webIconRepairTimer forMode:NSRunLoopCommonModes];
}

- (void)openMenu {
    CGCaptureWebRecentsFromRoot(self.root);
    CGPresentUnifiedMenu(self.root, NO, nil);
}

- (void)newWebChat {
    CGCaptureWebRecentsFromRoot(self.root);
    CGResetLocalPromptCapture();
    UIButton *button = CGFindButtonForAction(self.root.view, @"newTabTapped");
    if (button) [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (BOOL)insertDotIntoResponder:(UIView *)responder {
    if (!responder) return NO;

    if ([responder respondsToSelector:@selector(insertText:)]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(responder, @selector(insertText:), @".");
        return YES;
    }

    if ([responder conformsToProtocol:@protocol(UIKeyInput)]) {
        [(id<UIKeyInput>)responder insertText:@"."];
        return YES;
    }

    return NO;
}

- (void)forceDotIntoComposerInside:(UIView *)geckoView retry:(NSInteger)retry {
    if (!geckoView || retry > 50) return;

    UIView *firstResponder = CGFindFirstResponderView(geckoView);
    if ([self insertDotIntoResponder:firstResponder]) return;

    // GeckoView is only a wrapper. Its first child is the native Gecko engine
    // view returned by GeckoSession.window.view(). Make that view first
    // responder as a fallback, then send the same insertText: action used by a
    // physical keyboard key.
    UIView *engineView = geckoView.subviews.firstObject;
    if (engineView) {
        if (!engineView.isFirstResponder) [engineView becomeFirstResponder];
        firstResponder = CGFindFirstResponderView(geckoView);
        if ([self insertDotIntoResponder:firstResponder]) return;
        if (engineView.isFirstResponder && [self insertDotIntoResponder:engineView]) return;
    }

    // Last responder-chain fallback. If Gecko has acquired text focus but its
    // native view is not discoverable as a normal UIView first responder, UIKit
    // will still route insertText: down the active responder chain.
    BOOL sent = [UIApplication.sharedApplication sendAction:@selector(insertText:)
                                                         to:nil
                                                       from:@"."
                                                   forEvent:nil];
    if (sent) return;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf forceDotIntoComposerInside:geckoView retry:retry + 1];
    });
}

- (void)typeDotForVoice {
    UIView *geckoView = CGFindView(self.root.view, @"GeckoView");
    if (!geckoView) return;

    id composer = CGFindChatGPTComposerAX(geckoView);
    if (!composer) return;

    // A printable character is the state transition we know makes the genuine
    // ChatGPT dictation mic appear. Activate the deepest editable accessibility
    // element, then keep trying the real Gecko text-input path until focus has
    // finished moving from the native header back into web content.
    [composer accessibilityActivate];
    if ([composer isKindOfClass:UIView.class]) {
        [(UIView *)composer becomeFirstResponder];
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf forceDotIntoComposerInside:geckoView retry:0];
    });
}

- (void)updateWebIconRepairs {
    if (!self.root.isViewLoaded || !self.root.view.window) {
        self.webMenuRepairIcon.hidden = YES;
        self.composerPlusRepairIcon.hidden = YES;
        return;
    }

    UIView *content = CGFindView(self.root.view, @"ContentView");
    if (content) {
        // ChatGPT's own top-left circular menu button sits about 36 pt into the
        // web viewport. Draw only the glyph; the real web circle/button remains
        // underneath and handles the tap.
        self.webMenuRepairIcon.frame = CGRectMake(20.0, CGRectGetMinY(content.frame) + 20.0, 34.0, 34.0);
        self.webMenuRepairIcon.hidden = NO;
        [self.root.view bringSubviewToFront:self.webMenuRepairIcon];
    } else {
        self.webMenuRepairIcon.hidden = YES;
    }

    UIView *geckoView = CGFindView(self.root.view, @"GeckoView");
    id composer = geckoView ? CGFindChatGPTComposerAX(geckoView) : nil;
    if (composer) {
        CGRect frame = [composer accessibilityFrame];
        if (!CGRectIsEmpty(frame) && !CGRectIsNull(frame) && !CGRectIsInfinite(frame)) {
            frame = [self.root.view convertRect:frame fromView:nil];
            self.composerPlusRepairIcon.frame = CGRectMake(CGRectGetMinX(frame) + 10.0,
                                                           CGRectGetMidY(frame) - 17.0,
                                                           34.0,
                                                           34.0);
            self.composerPlusRepairIcon.hidden = NO;
            [self.root.view bringSubviewToFront:self.composerPlusRepairIcon];
        } else {
            self.composerPlusRepairIcon.hidden = YES;
        }
    } else {
        self.composerPlusRepairIcon.hidden = YES;
    }

    [self.root.view bringSubviewToFront:self.header];
}

- (void)seedWebChatIfNeeded {
    if (self.didSeedWebChat) return;

    NSString *restoredURL = CGStoredSelectedWebURL();
    if (CGURLIsChatGPT(restoredURL)) {
        self.didSeedWebChat = YES;
        return;
    }

    UIButton *button = CGFindButtonForAction(self.root.view, @"newTabTapped");
    if (!button) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf seedWebChatIfNeeded];
        });
        return;
    }

    self.didSeedWebChat = YES;
    [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (void)layoutShell {
    if (!self.root.isViewLoaded) return;

    UIView *content = CGFindView(self.root.view, @"ContentView");
    UIView *chrome = CGFindView(self.root.view, @"BrowserChrome");
    UIView *overview = CGFindView(self.root.view, @"TabOverview");

    chrome.hidden = YES;
    chrome.userInteractionEnabled = NO;
    overview.hidden = YES;
    overview.userInteractionEnabled = NO;

    if (content && ![objc_getAssociatedObject(self.root.view, CGLayoutKey) boolValue]) {
        for (NSLayoutConstraint *constraint in self.root.view.constraints.copy) {
            id first = constraint.firstItem;
            id second = constraint.secondItem;
            if (first == content || second == content || first == chrome || second == chrome || first == overview || second == overview) {
                constraint.active = NO;
            }
        }
        content.translatesAutoresizingMaskIntoConstraints = YES;
        content.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        objc_setAssociatedObject(self.root.view, CGLayoutKey, @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    CGFloat width = CGRectGetWidth(self.root.view.bounds);
    CGFloat height = CGRectGetHeight(self.root.view.bounds);
    UIEdgeInsets safe = self.root.view.safeAreaInsets;
    CGFloat headerHeight = 44.0;
    self.header.frame = CGRectMake(0, safe.top, width, headerHeight);
    self.menuButton.frame = CGRectMake(7, 2, 44, 40);
    self.micButton.frame = CGRectMake(width - 95, 2, 44, 40);
    self.composeButton.frame = CGRectMake(width - 51, 2, 44, 40);
    self.titleLabel.frame = CGRectMake(MAX(58.0, (width - 160.0) / 2.0), 0, 160.0, headerHeight);

    if (content) {
        CGFloat top = safe.top + headerHeight;
        content.frame = CGRectMake(0, top, width, MAX(0, height - top - safe.bottom));
    }
    [self.root.view bringSubviewToFront:self.header];
}

@end

static IMP CGOriginalLayout = NULL;

static void CGBrowserDidLayout(id self, SEL _cmd) {
    if (CGOriginalLayout) ((void (*)(id, SEL))CGOriginalLayout)(self, _cmd);
    UIViewController *root = (UIViewController *)self;
    CGWebRoot = root;
    CGShellCoordinator *coordinator = objc_getAssociatedObject(root, CGCoordinatorKey);
    if (!coordinator) {
        coordinator = [[CGShellCoordinator alloc] initWithRoot:root];
        objc_setAssociatedObject(root, CGCoordinatorKey, coordinator, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [coordinator install];
    }
    [coordinator layoutShell];
}

__attribute__((constructor))
static void CGInstallShellHook(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:CGBundleID]) return;
        Class browserClass = NSClassFromString(@"Reynard.BrowserViewController");
        if (!browserClass) browserClass = objc_getClass("_TtC7Reynard21BrowserViewController");
        Method method = browserClass ? class_getInstanceMethod(browserClass, @selector(viewDidLayoutSubviews)) : NULL;
        if (!method) return;
        CGOriginalLayout = method_getImplementation(method);
        method_setImplementation(method, (IMP)CGBrowserDidLayout);
    }
}
