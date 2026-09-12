#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

extern UIViewController *CGCurrentWebRoot(void);

static NSString *CGAXText(id element) {
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

static id CGFindAX(id node, BOOL (^match)(id), NSMutableSet<NSValue *> *seen, NSInteger depth) {
    if (!node || depth > 14) return nil;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)node];
    if ([seen containsObject:key]) return nil;
    [seen addObject:key];
    if (match(node)) return node;

    NSArray *elements = [node accessibilityElements];
    if ([elements isKindOfClass:NSArray.class]) {
        for (id child in elements) {
            id found = CGFindAX(child, match, seen, depth + 1);
            if (found) return found;
        }
    }

    NSInteger count = [node accessibilityElementCount];
    if (count != NSNotFound && count > 0 && count < 512) {
        for (NSInteger i = 0; i < count; i++) {
            id found = CGFindAX([node accessibilityElementAtIndex:i], match, seen, depth + 1);
            if (found) return found;
        }
    }

    if ([node isKindOfClass:UIView.class]) {
        for (UIView *subview in [(UIView *)node subviews]) {
            id found = CGFindAX(subview, match, seen, depth + 1);
            if (found) return found;
        }
    }
    return nil;
}

static id CGFindComposer(UIView *root) {
    return CGFindAX(root, ^BOOL(id element) {
        NSString *text = CGAXText(element);
        return [text containsString:@"ask chatgpt"] ||
               [text containsString:@"ask anything"] ||
               [text containsString:@"message chatgpt"] ||
               [text containsString:@"prompt chatgpt"];
    }, [NSMutableSet set], 0);
}

static BOOL CGComposerLooksEmpty(id composer) {
    NSString *value = [composer accessibilityValue];
    if (!value.length) return YES;
    NSString *lower = value.lowercaseString;
    return [lower isEqualToString:@"ask chatgpt"] ||
           [lower isEqualToString:@"ask anything"] ||
           [lower isEqualToString:@"message chatgpt"] ||
           [lower isEqualToString:@"prompt chatgpt"];
}

static id CGFindWebMic(UIView *root) {
    return CGFindAX(root, ^BOOL(id element) {
        NSString *text = CGAXText(element);
        return [text containsString:@"microphone"] ||
               [text containsString:@"dictat"] ||
               [text containsString:@"voice input"];
    }, [NSMutableSet set], 0);
}

static id CGFindSendButton(UIView *root) {
    return CGFindAX(root, ^BOOL(id element) {
        NSString *text = CGAXText(element);
        return [text isEqualToString:@"send"] || [text containsString:@"send message"];
    }, [NSMutableSet set], 0);
}

static UIView *CGFindFirstResponder(UIView *root) {
    if (root.isFirstResponder) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = CGFindFirstResponder(subview);
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
        _timer = [NSTimer timerWithTimeInterval:0.35 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
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
    self.button = [UIButton buttonWithType:UIButtonTypeSystem];
    self.button.tintColor = UIColor.labelColor;
    [self.button setImage:[UIImage systemImageNamed:@"mic"] forState:UIControlStateNormal];
    self.button.accessibilityLabel = @"Voice input";
    self.button.accessibilityIdentifier = @"ChatGPTMicBridge";
    self.button.frame = CGRectMake(0, 0, 44, 44);
    [self.button addTarget:self action:@selector(beginHandoff) forControlEvents:UIControlEventTouchUpInside];
    [root.view addSubview:self.button];
}

- (void)refresh {
    UIViewController *root = CGCurrentWebRoot();
    if (!root || !root.isViewLoaded || !root.view.window || self.handingOff) {
        self.button.hidden = YES;
        return;
    }

    id composer = CGFindComposer(root.view);
    if (!composer || !CGComposerLooksEmpty(composer) || CGFindWebMic(root.view)) {
        self.button.hidden = YES;
        return;
    }

    [self ensureButtonInRoot:root];

    CGRect frame = [composer accessibilityFrame];
    if (!CGRectIsEmpty(frame)) frame = [root.view convertRect:frame fromView:nil];

    id send = CGFindSendButton(root.view);
    CGRect sendFrame = [send accessibilityFrame];
    if (send && !CGRectIsEmpty(sendFrame)) {
        sendFrame = [root.view convertRect:sendFrame fromView:nil];
        self.button.center = CGPointMake(CGRectGetMinX(sendFrame) - 28.0, CGRectGetMidY(sendFrame));
    } else if (!CGRectIsEmpty(frame)) {
        self.button.center = CGPointMake(CGRectGetMaxX(frame) - 88.0, CGRectGetMidY(frame));
    } else {
        self.button.center = CGPointMake(CGRectGetWidth(root.view.bounds) - 105.0, CGRectGetMidY(root.view.bounds));
    }

    self.button.hidden = NO;
    [root.view bringSubviewToFront:self.button];
}

- (void)beginHandoff {
    UIViewController *root = CGCurrentWebRoot();
    if (!root) return;
    id composer = CGFindComposer(root.view);
    if (!composer || !CGComposerLooksEmpty(composer)) return;

    self.handingOff = YES;
    self.button.hidden = YES;
    if (![composer accessibilityActivate]) {
        self.handingOff = NO;
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        UIView *responder = CGFindFirstResponder(root.view);
        if (!responder || ![responder conformsToProtocol:@protocol(UIKeyInput)]) {
            weakSelf.handingOff = NO;
            return;
        }

        id<UIKeyInput> input = (id<UIKeyInput>)responder;
        [input insertText:@"."];
        [weakSelf waitForWebMicInRoot:root input:input responder:responder attempt:0];
    });
}

- (void)waitForWebMicInRoot:(UIViewController *)root input:(id<UIKeyInput>)input responder:(UIView *)responder attempt:(NSInteger)attempt {
    id mic = CGFindWebMic(root.view);
    if (mic) {
        [mic accessibilityActivate];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [input deleteBackward];
            [responder resignFirstResponder];
            self.handingOff = NO;
        });
        return;
    }

    if (attempt >= 12) {
        [input deleteBackward];
        [responder resignFirstResponder];
        self.handingOff = NO;
        return;
    }

    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf waitForWebMicInRoot:root input:input responder:responder attempt:attempt + 1];
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
