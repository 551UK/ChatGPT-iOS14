#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const CGBundleID = @"com.551.chatgpt14";
static NSString * const CGComposerMicSeed = @"\u2060"; // WORD JOINER: zero-width, but a real input character.
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

static BOOL CGViewIsDescendantOfView(UIView *view, UIView *ancestor) {
    if (!view || !ancestor) return NO;
    UIView *cursor = view;
    while (cursor) {
        if (cursor == ancestor) return YES;
        cursor = cursor.superview;
    }
    return NO;
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
    NSArray<NSString *> *needles = @[@"ask chatgpt", @"ask anything", @"message chatgpt", @"prompt chatgpt"];
    for (NSString *needle in needles) {
        if ([text rangeOfString:needle].location != NSNotFound) return YES;
    }
    return NO;
}

static id CGFindComposerAccessibilityElement(id node, NSMutableSet<NSValue *> *visited, NSInteger depth) {
    if (!node || depth > 14) return nil;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)node];
    if ([visited containsObject:key]) return nil;
    [visited addObject:key];

    if (CGAXLooksLikeChatGPTComposer(node)) return node;

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
    return nil;
}

static id CGFindChatGPTComposerAX(UIView *root) {
    if (!root) return nil;
    return CGFindComposerAccessibilityElement(root, [NSMutableSet set], 0);
}

static BOOL CGComposerAccessibilityValueLooksEmpty(id composer) {
    NSString *value = [composer accessibilityValue];
    if (!value.length) return YES;

    NSString *lower = value.lowercaseString;
    if ([lower isEqualToString:@"ask chatgpt"] ||
        [lower isEqualToString:@"ask anything"] ||
        [lower isEqualToString:@"message chatgpt"] ||
        [lower isEqualToString:@"prompt chatgpt"]) {
        return YES;
    }
    return NO;
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
@property (nonatomic, strong) UIButton *composeButton;
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) NSTimer *composerAssistTimer;
@property (nonatomic, assign) NSTimeInterval lastComposerAssistAttempt;
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
    [self.composerAssistTimer invalidate];
}

- (UIButton *)buttonWithSymbol:(NSString *)symbol action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.tintColor = UIColor.labelColor;
    [button setImage:[UIImage systemImageNamed:symbol] forState:UIControlStateNormal];
    [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return button;
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

    [self.root.view addSubview:header];
    [self.root.view bringSubviewToFront:header];
    [self layoutShell];

    [self seedWebChatIfNeeded];

    // ChatGPT's guest composer on this old Gecko build does not expose the
    // dictation mic until it has received a real text-input event. Poll for a
    // genuinely empty ChatGPT composer and seed it through Gecko's UIKeyInput
    // path, rather than faking a query parameter in the URL.
    self.composerAssistTimer = [NSTimer timerWithTimeInterval:1.25
                                                       target:self
                                                     selector:@selector(maintainEmptyComposerMic)
                                                     userInfo:nil
                                                      repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.composerAssistTimer forMode:NSRunLoopCommonModes];
}

- (void)openMenu {
    CGCaptureWebRecentsFromRoot(self.root);
    CGPresentUnifiedMenu(self.root, NO, nil);
}

- (void)newWebChat {
    CGCaptureWebRecentsFromRoot(self.root);
    CGResetLocalPromptCapture();
    self.lastComposerAssistAttempt = 0;
    UIButton *button = CGFindButtonForAction(self.root.view, @"newTabTapped");
    if (button) [button sendActionsForControlEvents:UIControlEventTouchUpInside];
}

- (void)seedWordJoinerIntoFocusedComposerInside:(UIView *)geckoView retry:(NSInteger)retry {
    UIView *firstResponder = CGFindFirstResponderView(self.root.view);
    if (!firstResponder && retry < 5) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.025 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [weakSelf seedWordJoinerIntoFocusedComposerInside:geckoView retry:retry + 1];
        });
        return;
    }

    if (!firstResponder || ![firstResponder conformsToProtocol:@protocol(UIKeyInput)]) return;
    if (geckoView && !CGViewIsDescendantOfView(firstResponder, geckoView)) return;

    id<UIKeyInput> input = (id<UIKeyInput>)firstResponder;
    [input insertText:CGComposerMicSeed];

    // Drop focus immediately so the keyboard should not remain on screen. The
    // zero-width character stays in the web composer and keeps React in the same
    // state produced by typing a normal digit, making ChatGPT's real mic visible.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.015 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [firstResponder resignFirstResponder];
    });
}

- (void)maintainEmptyComposerMic {
    if (!self.root.isViewLoaded || !self.root.view.window) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (self.root.presentedViewController) return;

    UIView *geckoView = CGFindView(self.root.view, @"GeckoView");
    if (!geckoView) return;

    // Never interfere while the user is already typing into the page.
    UIView *existingFirstResponder = CGFindFirstResponderView(self.root.view);
    if (existingFirstResponder) return;

    id composer = CGFindChatGPTComposerAX(geckoView);
    if (!composer || !CGComposerAccessibilityValueLooksEmpty(composer)) return;

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - self.lastComposerAssistAttempt < 8.0) return;
    self.lastComposerAssistAttempt = now;

    if (![composer accessibilityActivate]) return;
    [self seedWordJoinerIntoFocusedComposerInside:geckoView retry:0];
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
    self.composeButton.frame = CGRectMake(width - 51, 2, 44, 40);
    self.titleLabel.frame = CGRectMake(58, 0, MAX(0, width - 116), headerHeight);

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
