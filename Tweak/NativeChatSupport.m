#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <Security/Security.h>
#import <Speech/Speech.h>
#import <AVFoundation/AVFoundation.h>
#import <WebKit/WebKit.h>
#import <objc/runtime.h>

// Reuse the original v1 native ChatGPT UI as the optional second section of the
// app. Rename its standalone main() so these classes can live inside the shell
// dylib without trying to start a second UIApplication.
#include "../App/Parts/Core.inc"
#include "../App/Parts/API.inc"
#include "../App/Parts/Views.inc"
#include "../App/Parts/ChatA.inc"
#define main CGUnusedNativeChatMain
#include "../App/Parts/ChatB.inc"
#undef main

#pragma mark - iOS 14 keyboard-safe native composer

static const void *CGNativeComposerBottomConstraintKey = &CGNativeComposerBottomConstraintKey;
static IMP CGNativeOriginalViewDidLoad = NULL;

static NSLayoutConstraint *CGNativeFindComposerBottomConstraint(CGChatViewController *chat) {
    NSLayoutConstraint *cached = objc_getAssociatedObject(chat, CGNativeComposerBottomConstraintKey);
    if (cached) return cached;

    UIView *composer = chat.composer;
    if (!composer) return nil;

    for (NSLayoutConstraint *constraint in chat.view.constraints) {
        if (constraint.firstItem == composer && constraint.firstAttribute == NSLayoutAttributeBottom) {
            objc_setAssociatedObject(chat, CGNativeComposerBottomConstraintKey, constraint, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
            return constraint;
        }
    }
    return nil;
}

@interface CGChatViewController (CGKeyboardSafeComposer)
- (void)cg_nativeKeyboardFrameChanged:(NSNotification *)notification;
@end

@implementation CGChatViewController (CGKeyboardSafeComposer)

- (void)cg_nativeKeyboardFrameChanged:(NSNotification *)notification {
    NSLayoutConstraint *bottom = CGNativeFindComposerBottomConstraint(self);
    if (!bottom || !self.view.window) return;

    NSDictionary *info = notification.userInfo;
    NSValue *frameValue = info[UIKeyboardFrameEndUserInfoKey];
    CGRect keyboardFrame = frameValue ? [frameValue CGRectValue] : CGRectZero;
    keyboardFrame = [self.view convertRect:keyboardFrame fromView:nil];

    CGRect overlapRect = CGRectIntersection(self.view.bounds, keyboardFrame);
    CGFloat overlap = CGRectIsNull(overlapRect) ? 0.0 : CGRectGetHeight(overlapRect);
    CGFloat shift = MAX(0.0, overlap - self.view.safeAreaInsets.bottom);
    bottom.constant = -shift;

    NSTimeInterval duration = [info[UIKeyboardAnimationDurationUserInfoKey] doubleValue];
    if (duration <= 0.0) duration = 0.25;
    NSInteger curve = [info[UIKeyboardAnimationCurveUserInfoKey] integerValue];
    UIViewAnimationOptions options = UIViewAnimationOptionBeginFromCurrentState | (UIViewAnimationOptions)(curve << 16);

    [UIView animateWithDuration:duration delay:0 options:options animations:^{
        [self.view layoutIfNeeded];
    } completion:nil];
}

@end

static void CGNativeViewDidLoad(id self, SEL _cmd) {
    if (CGNativeOriginalViewDidLoad) {
        ((void (*)(id, SEL))CGNativeOriginalViewDidLoad)(self, _cmd);
    }

    CGChatViewController *chat = (CGChatViewController *)self;
    CGNativeFindComposerBottomConstraint(chat);

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserver:chat selector:@selector(cg_nativeKeyboardFrameChanged:) name:UIKeyboardWillChangeFrameNotification object:nil];
    [center addObserver:chat selector:@selector(cg_nativeKeyboardFrameChanged:) name:UIKeyboardWillHideNotification object:nil];
}

__attribute__((constructor))
static void CGInstallNativeKeyboardFix(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.551.chatgpt14"]) return;
        Class chatClass = NSClassFromString(@"CGChatViewController");
        Method method = chatClass ? class_getInstanceMethod(chatClass, @selector(viewDidLoad)) : NULL;
        if (!method) return;
        CGNativeOriginalViewDidLoad = method_getImplementation(method);
        method_setImplementation(method, (IMP)CGNativeViewDidLoad);
    }
}
