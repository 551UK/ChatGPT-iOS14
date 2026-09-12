#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

extern UIViewController *CGCurrentWebRoot(void);

static NSString *CGVMBText(id e) {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *s in @[[e accessibilityLabel] ?: @"", [e accessibilityValue] ?: @"", [e accessibilityHint] ?: @"", [e accessibilityIdentifier] ?: @""]) {
        if (s.length) [parts addObject:s];
    }
    return [[parts componentsJoinedByString:@" "] lowercaseString];
}

static id CGVMBFind(id node, BOOL (^match)(id), NSMutableSet<NSValue *> *seen, NSInteger depth) {
    if (!node || depth > 14) return nil;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)node];
    if ([seen containsObject:key]) return nil;
    [seen addObject:key];
    if (match(node)) return node;

    NSArray *elements = [node accessibilityElements];
    if ([elements isKindOfClass:NSArray.class]) {
        for (id child in elements) {
            id found = CGVMBFind(child, match, seen, depth + 1);
            if (found) return found;
        }
    }

    NSInteger count = [node accessibilityElementCount];
    if (count != NSNotFound && count > 0 && count < 512) {
        for (NSInteger i = 0; i < count; i++) {
            id found = CGVMBFind([node accessibilityElementAtIndex:i], match, seen, depth + 1);
            if (found) return found;
        }
    }

    if ([node isKindOfClass:UIView.class]) {
        for (UIView *subview in [(UIView *)node subviews]) {
            id found = CGVMBFind(subview, match, seen, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

static id CGVMBComposer(UIView *root) {
    return CGVMBFind(root, ^BOOL(id e) {
        NSString *t = CGVMBText(e);
        return [t containsString:@"ask chatgpt"] ||
               [t containsString:@"ask anything"] ||
               [t containsString:@"message chatgpt"] ||
               [t containsString:@"prompt chatgpt"];
    }, [NSMutableSet set], 0);
}

static BOOL CGVMBComposerEmpty(id composer) {
    NSString *value = [[composer accessibilityValue] lowercaseString];
    return !value.length ||
           [value isEqualToString:@"ask chatgpt"] ||
           [value isEqualToString:@"ask anything"] ||
           [value isEqualToString:@"message chatgpt"] ||
           [value isEqualToString:@"prompt chatgpt"];
}

static id CGVMBSend(UIView *root) {
    return CGVMBFind(root, ^BOOL(id e) {
        NSString *t = CGVMBText(e);
        return [t isEqualToString:@"send"] || [t containsString:@"send message"];
    }, [NSMutableSet set], 0);
}

static BOOL CGVMBAXElementVisible(id element, UIViewController *root) {
    if (!element || !root) return NO;
    if ([element accessibilityElementsHidden]) return NO;
    CGRect frame = [element accessibilityFrame];
    if (CGRectIsEmpty(frame) || CGRectIsNull(frame) || CGRectIsInfinite(frame)) return NO;
    CGRect local = [root.view convertRect:frame fromView:nil];
    CGRect visible = CGRectInset(root.view.bounds, -8.0, -8.0);
    return CGRectIntersectsRect(local, visible) && CGRectGetWidth(local) > 4.0 && CGRectGetHeight(local) > 4.0;
}

static id CGVMBVisibleWebMic(UIView *root, UIViewController *vc) {
    return CGVMBFind(root, ^BOOL(id e) {
        NSString *identifier = [[e accessibilityIdentifier] lowercaseString];
        if ([identifier containsString:@"chatgptemptymicoverlay"]) return NO;
        NSString *t = CGVMBText(e);
        BOOL looksLikeMic = [t containsString:@"microphone"] ||
                            [t containsString:@"dictat"] ||
                            [t containsString:@"voice input"] ||
                            [t isEqualToString:@"voice"] ||
                            [t containsString:@"start voice"];
        return looksLikeMic && CGVMBAXElementVisible(e, vc);
    }, [NSMutableSet set], 0);
}

static UIView *CGVMBFirstResponder(UIView *root) {
    if (!root) return nil;
    if (root.isFirstResponder) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = CGVMBFirstResponder(subview);
        if (found) return found;
    }
    return nil;
}

@interface CGVisibleMicBridge : NSObject
@property(nonatomic,strong) UIButton *button;
@property(nonatomic,strong) NSTimer *timer;
@property(nonatomic,assign) BOOL handingOff;
@end

@implementation CGVisibleMicBridge

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
    if (self.button.superview == root.view) return;
    [self.button removeFromSuperview];

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.frame = CGRectMake(0, 0, 44, 44);
    button.tintColor = UIColor.labelColor;
    UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:18 weight:UIImageSymbolWeightRegular];
    [button setImage:[[UIImage systemImageNamed:@"mic"] imageByApplyingSymbolConfiguration:config] forState:UIControlStateNormal];
    button.accessibilityLabel = @"Voice input";
    button.accessibilityIdentifier = @"ChatGPTEmptyMicOverlay";
    [button addTarget:self action:@selector(beginHandoff) forControlEvents:UIControlEventTouchUpInside];
    self.button = button;
    [root.view addSubview:button];
}

- (void)refresh {
    UIViewController *root = CGCurrentWebRoot();
    if (!root || !root.isViewLoaded || !root.view.window || self.handingOff) {
        self.button.hidden = YES;
        return;
    }

    id composer = CGVMBComposer(root.view);
    if (!composer || !CGVMBComposerEmpty(composer)) {
        self.button.hidden = YES;
        return;
    }

    [self ensureButtonInRoot:root];

    CGRect composerFrame = [composer accessibilityFrame];
    if (!CGRectIsEmpty(composerFrame)) composerFrame = [root.view convertRect:composerFrame fromView:nil];

    id send = CGVMBSend(root.view);
    CGRect sendFrame = [send accessibilityFrame];
    if (send && !CGRectIsEmpty(sendFrame)) {
        sendFrame = [root.view convertRect:sendFrame fromView:nil];
        self.button.center = CGPointMake(CGRectGetMinX(sendFrame) - 30.0, CGRectGetMidY(sendFrame));
    } else if (!CGRectIsEmpty(composerFrame)) {
        self.button.center = CGPointMake(CGRectGetMaxX(composerFrame) - 92.0, CGRectGetMidY(composerFrame));
    } else {
        self.button.center = CGPointMake(CGRectGetWidth(root.view.bounds) - 110.0, CGRectGetHeight(root.view.bounds) * 0.50);
    }

    self.button.hidden = NO;
    [root.view bringSubviewToFront:self.button];
}

- (void)beginHandoff {
    UIViewController *root = CGCurrentWebRoot();
    id composer = root ? CGVMBComposer(root.view) : nil;
    if (!root || !composer || !CGVMBComposerEmpty(composer)) return;

    self.handingOff = YES;
    self.button.hidden = YES;
    [composer accessibilityActivate];
    [self acquireResponderInRoot:root attempt:0];
}

- (void)acquireResponderInRoot:(UIViewController *)root attempt:(NSInteger)attempt {
    UIView *responder = CGVMBFirstResponder(root.view);
    if (responder && [responder conformsToProtocol:@protocol(UIKeyInput)]) {
        id<UIKeyInput> input = (id<UIKeyInput>)responder;
        [input insertText:@"."];
        [self waitForVisibleMicInRoot:root input:input responder:responder attempt:0];
        return;
    }

    if (attempt >= 10) {
        self.handingOff = NO;
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf acquireResponderInRoot:root attempt:attempt + 1];
    });
}

- (void)waitForVisibleMicInRoot:(UIViewController *)root input:(id<UIKeyInput>)input responder:(UIView *)responder attempt:(NSInteger)attempt {
    id mic = CGVMBVisibleWebMic(root.view, root);
    if (mic) {
        BOOL activated = [mic accessibilityActivate];
        if (activated) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.22 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if ([responder conformsToProtocol:@protocol(UIKeyInput)]) [input deleteBackward];
                [responder resignFirstResponder];
                self.handingOff = NO;
            });
            return;
        }
    }

    if (attempt >= 20) {
        if ([responder conformsToProtocol:@protocol(UIKeyInput)]) [input deleteBackward];
        [responder resignFirstResponder];
        self.handingOff = NO;
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf waitForVisibleMicInRoot:root input:input responder:responder attempt:attempt + 1];
    });
}

@end

__attribute__((constructor))
static void CGInstallVisibleMicBridge(void) {
    @autoreleasepool {
        dispatch_async(dispatch_get_main_queue(), ^{
            static CGVisibleMicBridge *bridge;
            bridge = [CGVisibleMicBridge new];
        });
    }
}
