#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>

extern int CGRunChatGPTDotScript(void *rawView);

@interface CGShellCoordinator : NSObject
@property (nonatomic, weak) UIViewController *root;
- (void)typeDotForVoice;
@end

static UIView *CGDotFindView(UIView *root, NSString *needle) {
    if (!root) return nil;
    NSString *name = NSStringFromClass(root.class);
    if ([name rangeOfString:needle options:NSCaseInsensitiveSearch].location != NSNotFound) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = CGDotFindView(subview, needle);
        if (found) return found;
    }
    return nil;
}

@implementation CGShellCoordinator (DotScriptFix)

- (void)typeDotForVoice {
    UIViewController *root = self.root;
    if (!root.isViewLoaded) return;

    UIView *geckoView = CGDotFindView(root.view, @"GeckoView");
    if (!geckoView) return;

    // Execute inside the actual ChatGPT page through Gecko instead of trying to
    // fake a hardware/software keyboard event from UIKit.
    CGRunChatGPTDotScript((__bridge void *)geckoView);
}

@end
