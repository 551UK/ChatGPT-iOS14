#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/message.h>

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

static UIView *CGDotFindFirstResponder(UIView *root) {
    if (!root) return nil;
    if (root.isFirstResponder) return root;
    for (UIView *subview in root.subviews) {
        UIView *found = CGDotFindFirstResponder(subview);
        if (found) return found;
    }
    return nil;
}

static BOOL CGDotIsDescendant(UIView *view, UIView *ancestor) {
    UIView *cursor = view;
    while (cursor) {
        if (cursor == ancestor) return YES;
        cursor = cursor.superview;
    }
    return NO;
}

static NSString *CGDotAXText(id element) {
    NSMutableArray *parts = [NSMutableArray array];
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

static BOOL CGDotLooksLikeComposer(id element) {
    NSString *text = CGDotAXText(element);
    if (!text.length) return NO;
    for (NSString *needle in @[@"ask chatgpt", @"ask anything", @"message chatgpt", @"prompt chatgpt"]) {
        if ([text rangeOfString:needle].location != NSNotFound) return YES;
    }
    return NO;
}

static id CGDotFindComposer(id node, NSMutableSet *visited, NSInteger depth) {
    if (!node || depth > 16) return nil;
    NSValue *key = [NSValue valueWithPointer:(__bridge const void *)node];
    if ([visited containsObject:key]) return nil;
    [visited addObject:key];

    NSArray *elements = [node accessibilityElements];
    if ([elements isKindOfClass:NSArray.class]) {
        for (id child in elements) {
            id found = CGDotFindComposer(child, visited, depth + 1);
            if (found) return found;
        }
    }

    NSInteger count = [node accessibilityElementCount];
    if (count != NSNotFound && count > 0 && count < 512) {
        for (NSInteger i = 0; i < count; i++) {
            id child = [node accessibilityElementAtIndex:i];
            id found = CGDotFindComposer(child, visited, depth + 1);
            if (found) return found;
        }
    }

    if ([node isKindOfClass:UIView.class]) {
        for (UIView *subview in [(UIView *)node subviews]) {
            id found = CGDotFindComposer(subview, visited, depth + 1);
            if (found) return found;
        }
    }
    return CGDotLooksLikeComposer(node) ? node : nil;
}

static void CGDotInsertWhenGeckoIsFocused(UIViewController *root, UIView *geckoView, NSInteger retry) {
    if (!root || !root.isViewLoaded || !geckoView || retry > 25) return;

    UIView *firstResponder = CGDotFindFirstResponder(root.view);
    if (firstResponder &&
        CGDotIsDescendant(firstResponder, geckoView) &&
        [firstResponder respondsToSelector:@selector(insertText:)]) {
        ((void (*)(id, SEL, NSString *))objc_msgSend)(firstResponder, @selector(insertText:), @".");

        // End editing immediately after the real Gecko input event. This keeps
        // the software keyboard from remaining on screen while leaving the dot
        // in ChatGPT so its genuine microphone control becomes available.
        [firstResponder resignFirstResponder];
        [root.view endEditing:YES];
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.02 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGDotInsertWhenGeckoIsFocused(root, geckoView, retry + 1);
    });
}

@implementation CGShellCoordinator (DotResponderFix)

- (void)typeDotForVoice {
    UIViewController *root = self.root;
    if (!root.isViewLoaded) return;

    UIView *geckoView = CGDotFindView(root.view, @"GeckoView");
    id composer = geckoView ? CGDotFindComposer(geckoView, [NSMutableSet set], 0) : nil;
    if (!composer) return;

    // This is the same focus path that previously produced the real caret in
    // ChatGPT. Once Gecko owns first-responder focus, send a literal dot to that
    // exact responder instead of guessing at an unfocused engine view.
    [composer accessibilityActivate];
    CGDotInsertWhenGeckoIsFocused(root, geckoView, 0);
}

@end
