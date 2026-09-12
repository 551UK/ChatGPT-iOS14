#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

static NSString * const CGBundleID = @"com.551.chatgpt14";
static NSString * const CGChatGPTWebURL = @"https://chatgpt.com/";
static NSString * const CGChatGPTVoiceURL = @"https://chatgpt.com/?mode=voice";
static NSString * const CGCustomNewTabURLKey = @"default.NewTabSettings.customNewTabURL";
static NSString * const CGRequestDesktopWebsiteKey = @"default.BrowsingSettings.requestDesktopWebsite";
static NSString * const CGDefaultPageZoomKey = @"default.BrowsingSettings.defaultPageZoomLevel";
static const NSInteger CGVoicePhoneZoom = 175;
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
@property (nonatomic, strong) UIButton *voiceButton;
@property (nonatomic, strong) UIButton *composeButton;
@property (nonatomic, strong) UILabel *titleLabel;
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

    self.voiceButton = [self buttonWithSymbol:@"mic.fill" action:@selector(openWebVoice)];
    self.voiceButton.accessibilityLabel = @"ChatGPT Voice";
    [header addSubview:self.voiceButton];

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

- (void)openWebVoice {
    CGCaptureWebRecentsFromRoot(self.root);
    CGResetLocalPromptCapture();

    UIButton *button = CGFindButtonForAction(self.root.view, @"newTabTapped");
    if (!button) {
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Voice is still loading"
                                                                       message:@"Wait a moment for ChatGPT Web to finish loading, then tap the microphone again."
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self.root presentViewController:alert animated:YES completion:nil];
        return;
    }

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    id previousURL = [defaults objectForKey:CGCustomNewTabURLKey];
    id previousDesktopMode = [defaults objectForKey:CGRequestDesktopWebsiteKey];
    id previousZoom = [defaults objectForKey:CGDefaultPageZoomKey];

    // ChatGPT currently exposes its full web Voice UI to Reynard in desktop
    // website mode. Keep that known-working mode, but create only the Voice tab
    // at a much larger Gecko full-page zoom. Full zoom also gives responsive
    // sites less CSS width, so ChatGPT lays itself out like a phone instead of a
    // tiny desktop page with a permanent sidebar. The mic/send controls and the
    // Voice cancel/confirm controls are enlarged together because they are part
    // of the real ChatGPT page, not replacement buttons drawn by this app.
    [defaults setObject:CGChatGPTVoiceURL forKey:CGCustomNewTabURLKey];
    [defaults setBool:YES forKey:CGRequestDesktopWebsiteKey];
    [defaults setInteger:CGVoicePhoneZoom forKey:CGDefaultPageZoomKey];
    [defaults synchronize];

    [button sendActionsForControlEvents:UIControlEventTouchUpInside];

    // New-tab creation reads these settings synchronously. Restore the normal
    // defaults afterwards so ordinary text tabs keep their existing layout.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (previousURL) [defaults setObject:previousURL forKey:CGCustomNewTabURLKey];
        else [defaults setObject:CGChatGPTWebURL forKey:CGCustomNewTabURLKey];

        if (previousDesktopMode) [defaults setObject:previousDesktopMode forKey:CGRequestDesktopWebsiteKey];
        else [defaults removeObjectForKey:CGRequestDesktopWebsiteKey];

        if (previousZoom) [defaults setObject:previousZoom forKey:CGDefaultPageZoomKey];
        else [defaults removeObjectForKey:CGDefaultPageZoomKey];
        [defaults synchronize];
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
    self.voiceButton.frame = CGRectMake(width - 95, 2, 44, 40);
    self.composeButton.frame = CGRectMake(width - 51, 2, 44, 40);
    self.titleLabel.frame = CGRectMake(58, 0, MAX(0, width - 160), headerHeight);

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
