#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>


#include "Parts/Core.inc"
#include "Parts/API.inc"
#include "Parts/Views.inc"
#include "Parts/ChatA.inc"
#include "Parts/ChatB.inc"

#pragma mark - Reynard-backed first-party ChatGPT

@interface CGReynardChatViewController : UIViewController
@property (nonatomic, assign) BOOL didAttemptAutomaticOpen;
@property (nonatomic, strong) UILabel *statusLabel;
@property (nonatomic, strong) UIButton *openButton;
@end

@implementation CGReynardChatViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"ChatGPT";
    self.view.backgroundColor = UIColor.systemBackgroundColor;

    UIImageView *icon = [[UIImageView alloc] initWithImage:[UIImage systemImageNamed:@"globe"]];
    icon.translatesAutoresizingMaskIntoConstraints = NO;
    icon.contentMode = UIViewContentModeScaleAspectFit;
    icon.tintColor = UIColor.labelColor;

    UILabel *title = [UILabel new];
    title.translatesAutoresizingMaskIntoConstraints = NO;
    title.text = @"ChatGPT Web";
    title.font = [UIFont systemFontOfSize:28 weight:UIFontWeightBold];
    title.textAlignment = NSTextAlignmentCenter;

    UILabel *detail = [UILabel new];
    detail.translatesAutoresizingMaskIntoConstraints = NO;
    detail.text = @"Uses Reynard's Gecko engine so the real ChatGPT website works on iOS 14. Sign in with your normal ChatGPT account — no OpenAI API key is needed.";
    detail.font = [UIFont systemFontOfSize:15 weight:UIFontWeightRegular];
    detail.textColor = UIColor.secondaryLabelColor;
    detail.textAlignment = NSTextAlignmentCenter;
    detail.numberOfLines = 0;

    self.statusLabel = [UILabel new];
    self.statusLabel.translatesAutoresizingMaskIntoConstraints = NO;
    self.statusLabel.text = @"Opening ChatGPT in Reynard…";
    self.statusLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    self.statusLabel.textColor = UIColor.secondaryLabelColor;
    self.statusLabel.textAlignment = NSTextAlignmentCenter;
    self.statusLabel.numberOfLines = 0;

    self.openButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.openButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self.openButton setTitle:@"Open ChatGPT" forState:UIControlStateNormal];
    self.openButton.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    self.openButton.backgroundColor = UIColor.labelColor;
    [self.openButton setTitleColor:UIColor.systemBackgroundColor forState:UIControlStateNormal];
    self.openButton.layer.cornerRadius = 13.0;
    self.openButton.contentEdgeInsets = UIEdgeInsetsMake(13, 24, 13, 24);
    [self.openButton addTarget:self action:@selector(openChatGPT) forControlEvents:UIControlEventTouchUpInside];

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[icon, title, detail, self.openButton, self.statusLabel]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisVertical;
    stack.alignment = UIStackViewAlignmentCenter;
    stack.spacing = 14.0;
    [self.view addSubview:stack];

    [NSLayoutConstraint activateConstraints:@[
        [icon.widthAnchor constraintEqualToConstant:48],
        [icon.heightAnchor constraintEqualToConstant:48],
        [detail.widthAnchor constraintLessThanOrEqualToConstant:340],
        [self.statusLabel.widthAnchor constraintLessThanOrEqualToConstant:340],
        [stack.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-24],
        [stack.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [stack.centerYAnchor constraintEqualToAnchor:self.view.centerYAnchor constant:-24]
    ]];

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"info.circle"] style:UIBarButtonItemStylePlain target:self action:@selector(showInfo)];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    if (self.didAttemptAutomaticOpen) return;
    self.didAttemptAutomaticOpen = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self openChatGPT];
    });
}

- (NSURL *)reynardChatGPTURL {
    NSURLComponents *components = [NSURLComponents componentsWithString:@"reynard://open"];
    components.queryItems = @[[NSURLQueryItem queryItemWithName:@"url" value:@"https://chatgpt.com/"]];
    return components.URL;
}

- (void)openChatGPT {
    NSURL *url = [self reynardChatGPTURL];
    if (!url) return;

    self.statusLabel.text = @"Opening ChatGPT in Reynard…";
    self.openButton.enabled = NO;

    [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:^(BOOL success) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.openButton.enabled = YES;
            if (success) {
                self.statusLabel.text = @"ChatGPT is using your normal account in Reynard. No API key is required.";
            } else {
                self.statusLabel.text = @"Reynard could not be opened.";
                [self showReynardRequired];
            }
        });
    }];
}

- (void)showReynardRequired {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Reynard required"
                                                                   message:@"iOS 14's built-in WebKit is too old for the current ChatGPT website. Install Reynard Browser, then open this ChatGPT app again. Reynard uses a current Gecko engine instead of the old iOS WebKit engine."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Copy Reynard GitHub link" style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction *action) {
        UIPasteboard.generalPasteboard.string = @"https://github.com/minh-ton/reynard-browser";
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)showInfo {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"How this works"
                                                                   message:@"This build no longer uses the OpenAI developer API for the main chat. It opens the first-party ChatGPT website in Reynard, so your normal ChatGPT login and account features are used without an API key."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

@end

#pragma mark - Make Reynard ChatGPT the default app screen

@implementation CGAppDelegate (CGReynardDefault)

+ (void)load {
    Method original = class_getInstanceMethod(self, @selector(application:didFinishLaunchingWithOptions:));
    Method replacement = class_getInstanceMethod(self, @selector(cg_reynard_application:didFinishLaunchingWithOptions:));
    if (original && replacement) method_exchangeImplementations(original, replacement);
}

- (BOOL)cg_reynard_application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    self.window = [[UIWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    CGReynardChatViewController *web = [CGReynardChatViewController new];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:web];
    nav.navigationBar.prefersLargeTitles = NO;
    self.window.rootViewController = nav;
    [self.window makeKeyAndVisible];
    return YES;
}

@end
