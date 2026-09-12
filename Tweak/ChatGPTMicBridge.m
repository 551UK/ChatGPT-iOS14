#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

extern UIViewController *CGCurrentWebRoot(void);

static NSString *CGMBAXText(id element) {
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

static id CGMBFindAX(id node, BOOL (^match)(id), NSMutableSet<NSValue *> *seen, NSInteger depth) {
    if (!node || depth > 14) return nil;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)node];
    if ([seen containsObject:key]) return nil;
    [seen addObject:key];
    if (match(node)) return node;

    NSArray *elements = [node accessibilityElements];
    if ([elements isKindOfClass:NSArray.class]) {
        for (id child in elements) {
            id found = CGMBFindAX(child, match, seen, depth + 1);
            if (found) return found;
        }
    }

    NSInteger count = [node accessibilityElementCount];
    if (count != NSNotFound && count > 0 && count < 512) {
        for (NSInteger i = 0; i < count; i++) {
            id found = CGMBFindAX([node accessibilityElementAtIndex:i], match, seen, depth + 1);
            if (found) return found;
        }
    }

    if ([node isKindOfClass:UIView.class]) {
        for (UIView *subview in [(UIView *)node subviews]) {
            id found = CGMBFindAX(subview, match, seen, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

static UIView *CGMBFindGeckoView(UIView *root) {
    if (!root) return nil;
    NSString *name = NSStringFromClass(root.class);
    if ([name rangeOfString:@"GeckoView" options:NSCaseInsensitiveSearch].location != NSNotFound) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = CGMBFindGeckoView(subview);
        if (found) return found;
    }
    return nil;
}

static id CGMBFindComposer(UIView *geckoRoot) {
    return CGMBFindAX(geckoRoot, ^BOOL(id element) {
        NSString *text = CGMBAXText(element);
        return [text containsString:@"ask chatgpt"] ||
               [text containsString:@"ask anything"] ||
               [text containsString:@"message chatgpt"] ||
               [text containsString:@"prompt chatgpt"];
    }, [NSMutableSet set], 0);
}

static BOOL CGMBComposerLooksEmpty(id composer) {
    NSString *value = [composer accessibilityValue];
    if (!value.length) return YES;
    NSString *lower = value.lowercaseString;
    return [lower isEqualToString:@"ask chatgpt"] ||
           [lower isEqualToString:@"ask anything"] ||
           [lower isEqualToString:@"message chatgpt"] ||
           [lower isEqualToString:@"prompt chatgpt"];
}

static BOOL CGMBElementIsVisiblyOnScreen(id element) {
    CGRect frame = [element accessibilityFrame];
    if (CGRectIsEmpty(frame) || CGRectIsNull(frame) || CGRectIsInfinite(frame)) return NO;
    if (CGRectGetWidth(frame) < 4.0 || CGRectGetHeight(frame) < 4.0) return NO;
    CGRect screen = UIScreen.mainScreen.bounds;
    if (!CGRectIntersectsRect(frame, screen)) return NO;
    if ([element isKindOfClass:UIView.class]) {
        UIView *view = (UIView *)element;
        if (view.hidden || view.alpha < 0.05 || !view.window) return NO;
    }
    return YES;
}

static id CGMBFindVisibleWebMic(UIView *geckoRoot) {
    return CGMBFindAX(geckoRoot, ^BOOL(id element) {
        NSString *text = CGMBAXText(element);
        BOOL looksLikeMic = [text containsString:@"microphone"] ||
                            [text containsString:@"dictat"] ||
                            [text containsString:@"voice input"];
        return looksLikeMic && CGMBElementIsVisiblyOnScreen(element);
    }, [NSMutableSet set], 0);
}

static UIView *CGMBFindFirstResponder(UIView *root) {
    if (!root) return nil;
    if (root.isFirstResponder) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = CGMBFindFirstResponder(subview);
        if (found) return found;
    }
    return nil;
}

@interface CGMicBridge : NSObject
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL handingOff;
@end

@implementation CGMicBridge

- (instancetype)init {
    if ((self = [super init])) {
        _timer = [NSTimer timerWithTimeInterval:0.25 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
        [[NSRunLoop mainRunLoop] addTimer:_timer forMode:NSRunLoopCommonModes];
    }
    return self;
}

- (void)dealloc {
    [self.timer invalidate];
}

- (void)ensureButtonInRoot:(UIViewController *)root {
    if (!self.button) {
        self.button = [UIButton buttonWithType:UIButtonTypeSystem];
        self.button.tintColor = UIColor.labelColor;
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:21 weight:UIImageSymbolWeightRegular];
        UIImage *image = [[UIImage systemImageNamed:@"mic.fill"] imageByApplyingSymbolConfiguration:config];
        [self.button setImage:image forState:UIControlStateNormal];
        self.button.accessibilityLabel = @"Microphone";
        self.button.accessibilityIdentifier = @"ChatGPTMicBridge";
        self.button.frame = CGRectMake(0, 0, 44, 44);
        [self.button addTarget:self action:@selector(beginHandoff) forControlEvents:UIControlEventTouchUpInside];
    }
    if (self.button.superview != root.view) {
        [self.button removeFromSuperview];
        [root.view addSubview:self.button];
    }
}

- (void)refresh {
    UIViewController *root = CGCurrentWebRoot();
    if (!root || !root.isViewLoaded || !root.view.window || self.handingOff) {
        self.button.hidden = YES;
        return;
    }

    UIView *gecko = CGMBFindGeckoView(root.view);
    if (!gecko) {
        self.button.hidden = YES;
        return;
    }

    id composer = CGMBFindComposer(gecko);
    if (!composer || !CGMBComposerLooksEmpty(composer)) {
        self.button.hidden = YES;
        return;
    }

    // ChatGPT exposes a hidden microphone accessibility element even while the
    // guest composer is visually empty. Only suppress our bridge if the genuine
    // web mic is actually visible and has a real on-screen accessibility frame.
    if (CGMBFindVisibleWebMic(gecko)) {
        self.button.hidden = YES;
        return;
    }

    CGRect frame = [composer accessibilityFrame];
    if (CGRectIsEmpty(frame) || CGRectIsNull(frame) || CGRectIsInfinite(frame)) {
        self.button.hidden = YES;
        return;
    }

    [self ensureButtonInRoot:root];
    frame = [root.view convertRect:frame fromView:nil];
    self.button.center = CGPointMake(CGRectGetMaxX(frame) - 73.0, CGRectGetMidY(frame));
    self.button.hidden = NO;
    [root.view bringSubviewToFront:self.button];
}

- (void)beginHandoff {
    UIViewController *root = CGCurrentWebRoot();
    if (!root) return;
    UIView *gecko = CGMBFindGeckoView(root.view);
    if (!gecko) return;

    id composer = CGMBFindComposer(gecko);
    if (!composer || !CGMBComposerLooksEmpty(composer)) return;

    self.handingOff = YES;
    self.button.hidden = YES;
    if (![composer accessibilityActivate]) {
        self.handingOff = NO;
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *responder = CGMBFindFirstResponder(gecko);
        if (!responder || ![responder conformsToProtocol:@protocol(UIKeyInput)]) {
            weakSelf.handingOff = NO;
            return;
        }

        id<UIKeyInput> input = (id<UIKeyInput>)responder;
        [input insertText:@"."];
        [weakSelf waitForWebMicInRoot:root gecko:gecko input:input responder:responder attempt:0];
    });
}

- (void)waitForWebMicInRoot:(UIViewController *)root gecko:(UIView *)gecko input:(id<UIKeyInput>)input responder:(UIView *)responder attempt:(NSInteger)attempt {
    id mic = CGMBFindVisibleWebMic(gecko);
    if (mic) {
        BOOL activated = [mic accessibilityActivate];
        if (activated) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                [input deleteBackward];
                [responder resignFirstResponder];
                self.handingOff = NO;
            });
            return;
        }
    }

    if (attempt >= 24) {
        [input deleteBackward];
        [responder resignFirstResponder];
        self.handingOff = NO;
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf waitForWebMicInRoot:root gecko:gecko input:input responder:responder attempt:attempt + 1];
    });
}

@end

__attribute__((constructor))
static void CGInstallMicBridge(void) {
    @autoreleasepool {
        static CGMicBridge *bridge;
        dispatch_async(dispatch_get_main_queue(), ^{
            bridge = [CGMicBridge new];
        });
    }
}
