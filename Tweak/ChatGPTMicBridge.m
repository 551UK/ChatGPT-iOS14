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

static id CGMBFindAnyWebMic(UIView *geckoRoot) {
    return CGMBFindAX(geckoRoot, ^BOOL(id element) {
        NSString *text = CGMBAXText(element);
        return [text containsString:@"microphone"] ||
               [text containsString:@"dictat"] ||
               [text containsString:@"voice input"];
    }, [NSMutableSet set], 0);
}

@interface CGMicBridge : NSObject
@property (nonatomic, strong) UIButton *button;
@property (nonatomic, strong) NSTimer *timer;
@end

@implementation CGMicBridge

- (instancetype)init {
    if ((self = [super init])) {
        _timer = [NSTimer timerWithTimeInterval:0.20 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
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
        UIImageSymbolConfiguration *config = [UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightRegular];
        UIImage *image = [[UIImage systemImageNamed:@"mic.fill"] imageByApplyingSymbolConfiguration:config];
        [self.button setImage:image forState:UIControlStateNormal];
        self.button.backgroundColor = UIColor.systemBackgroundColor;
        self.button.frame = CGRectMake(0, 0, 44, 44);
        self.button.layer.cornerRadius = 22.0;
        self.button.accessibilityLabel = @"Microphone";
        self.button.accessibilityIdentifier = @"ChatGPTMicBridge";
        [self.button addTarget:self action:@selector(openWebMic) forControlEvents:UIControlEventTouchUpInside];
    }
    if (self.button.superview != root.view) {
        [self.button removeFromSuperview];
        [root.view addSubview:self.button];
    }
}

- (void)refresh {
    UIViewController *root = CGCurrentWebRoot();
    if (!root || !root.isViewLoaded || !root.view.window) {
        self.button.hidden = YES;
        return;
    }

    [self ensureButtonInRoot:root];
    CGFloat width = CGRectGetWidth(root.view.bounds);
    CGFloat height = CGRectGetHeight(root.view.bounds);
    self.button.center = CGPointMake(MAX(24.0, width - 79.0), height * 0.495);
    self.button.hidden = NO;
    [root.view bringSubviewToFront:self.button];
}

- (void)openWebMic {
    UIViewController *root = CGCurrentWebRoot();
    if (!root) return;
    UIView *gecko = CGMBFindGeckoView(root.view);
    if (!gecko) return;
    id mic = CGMBFindAnyWebMic(gecko);
    if (mic) [mic accessibilityActivate];
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
