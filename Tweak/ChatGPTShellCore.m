#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>

static NSString * const CGBundleID = @"com.551.chatgpt14";
static NSString * const CGComposerMicSeed = @".";
static const void *CGCoordinatorKey = &CGCoordinatorKey;
static const void *CGLayoutKey = &CGLayoutKey;
static __weak UIViewController *CGWebRoot = nil;

extern void CGPresentUnifiedMenu(UIViewController *presenter, BOOL nativeMode, id nativeChatController);
extern void CGCaptureWebRecentsFromRoot(UIViewController *root);
extern void CGResetLocalPromptCapture(void);
extern NSString *CGStoredSelectedWebURL(void);

UIViewController *CGCurrentWebRoot(void) { return CGWebRoot; }

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
    for (NSString *needle in @[@"ask chatgpt", @"ask anything", @"message chatgpt", @"prompt chatgpt"]) {
        if ([text rangeOfString:needle].location != NSNotFound) return YES;
    }
    return NO;
}

static id CGFindComposerAccessibilityElement(id node, NSMutableSet<NSValue *> *visited, NSInteger depth) {
    if (!node || depth > 14) return nil;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)node];
    if ([visited containsObject:key]) return nil;
    [visited addObject:key];

    // Keep the older search order that was proven to focus the real composer.
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
            id found = CGFindComposerAccessibilityElement([node accessibilityElementAtIndex:index], visited, depth + 1);
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
    return root ? CGFindComposerAccessibilityElement(root, [NSMutableSet set], 0) : nil;
}

static BOOL CGComposerAccessibilityValueLooksEmpty(id composer) {
    NSString *value = [composer accessibilityValue];
    if (!value.length) return YES;
    NSString *lower = value.lowercaseString;
    return [lower isEqualToString:@"ask chatgpt"] ||
           [lower isEqualToString:@"ask anything"] ||
           [lower isEqualToString:@"message chatgpt"] ||
           [lower isEqualToString:@"prompt chatgpt"];
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

    self.composerAssistTimer = [NSTimer timerWithTimeInterval:1.0
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

- (id)activeKeyboardImpl {
    Class keyboardClass = NSClassFromString(@"UIKeyboardImpl");
    if (!keyboardClass) return nil;

    id keyboard = nil;
    SEL activeSelector = NSSelectorFromString(@"activeInstance");
    if ([keyboardClass respondsToSelector:activeSelector]) {
        keyboard = ((id (*)(id, SEL))objc_msgSend)(keyboardClass, activeSelector);
    }

    if (!keyboard) {
        SEL sharedSelector = NSSelectorFromString(@"sharedInstance");
        if ([keyboardClass respondsToSelector:sharedSelector]) {
            keyboard = ((id (*)(id, SEL))objc_msgSend)(keyboardClass, sharedSelector);
        }
    }
    return keyboard;
}

- (void)insertDotThroughKeyboardImplInto:(UIView *)geckoView retry:(NSInteger)retry {
    if (retry > 18) {
        [self.root.view endEditing:YES];
        return;
    }

    id composer = CGFindChatGPTComposerAX(geckoView);
    if (composer && !CGComposerAccessibilityValueLooksEmpty(composer)) {
        [self.root.view endEditing:YES];
        return;
    }

    id keyboard = [self activeKeyboardImpl];
    SEL insertSelector = NSSelectorFromString(@"insertText:");
    if (keyboard && [keyboard respondsToSelector:insertSelector]) {
        ((void (*)(id, SEL, id))objc_msgSend)(keyboard, insertSelector, CGComposerMicSeed);
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.055 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;

        UIView *currentGecko = CGFindView(strongSelf.root.view, @"GeckoView");
        id currentComposer = currentGecko ? CGFindChatGPTComposerAX(currentGecko) : nil;
        if (currentComposer && !CGComposerAccessibilityValueLooksEmpty(currentComposer)) {
            [strongSelf.root.view endEditing:YES];
            return;
        }

        // Gecko can take a few ticks to attach its web editor as UIKit's keyboard
        // delegate. Re-activate the composer and retry UIKeyboardImpl rather than
        // trying to discover a responder hidden inside Gecko's native engine.
        if (currentComposer) [currentComposer accessibilityActivate];
        [strongSelf insertDotThroughKeyboardImplInto:currentGecko retry:retry + 1];
    });
}

- (void)maintainEmptyComposerMic {
    if (!self.root.isViewLoaded || !self.root.view.window) return;
    if (UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;
    if (self.root.presentedViewController) return;

    UIView *geckoView = CGFindView(self.root.view, @"GeckoView");
    if (!geckoView) return;

    id composer = CGFindChatGPTComposerAX(geckoView);
    if (!composer || !CGComposerAccessibilityValueLooksEmpty(composer)) return;

    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (now - self.lastComposerAssistAttempt < 3.0) return;
    self.lastComposerAssistAttempt = now;

    if (![composer accessibilityActivate]) return;

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.035 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf insertDotThroughKeyboardImplInto:geckoView retry:0];
    });
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
