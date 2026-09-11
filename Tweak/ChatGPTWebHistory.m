#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>

UIViewController *CGCurrentWebRoot(void);

static NSString * const CGRecentsDefaultsKey = @"CGWebRecentsV4";
static NSString * const CGLegacyRecentsDefaultsKey = @"CGWebRecentsV3";
static NSUInteger const CGRecentsLimit = 120;

static __weak id CGActiveEditable = nil;
static NSString *CGCurrentDraft = nil;
static NSTimer *CGDraftMonitorTimer = nil;
static IMP CGOriginalInsertText = NULL;
static IMP CGOriginalDeleteBackward = NULL;
static BOOL CGChildViewHooksInstalled = NO;
static NSInteger CGChildViewHookAttempts = 0;

static BOOL CGIsChatGPTURLString(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    return [host isEqualToString:@"chatgpt.com"] || [host isEqualToString:@"www.chatgpt.com"];
}

static BOOL CGIsChatConversationURLString(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (!url || !CGIsChatGPTURLString(urlString)) return NO;
    NSString *path = url.path.lowercaseString ?: @"";
    return [path hasPrefix:@"/c/"] || [path containsString:@"/c/"] ||
           [path hasPrefix:@"/conversation/"] || [path containsString:@"/conversation/"];
}

static id CGSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static NSString *CGSelectedWebURL(UIViewController *root) {
    if (!root) return nil;
    id manager = CGSafeValueForKey(root, @"tabManager");
    id selected = CGSafeValueForKey(manager, @"selectedTab");
    id rawURL = CGSafeValueForKey(selected, @"url");
    if ([rawURL isKindOfClass:NSString.class]) return rawURL;
    if ([rawURL isKindOfClass:NSURL.class]) return [(NSURL *)rawURL absoluteString];
    return nil;
}

static NSString *CGPromptTitle(NSString *prompt) {
    if (!prompt.length) return @"Recent chat";
    NSMutableString *value = [prompt mutableCopy];
    NSRegularExpression *spaces = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
    [spaces replaceMatchesInString:value options:0 range:NSMakeRange(0, value.length) withTemplate:@" "];
    NSString *trimmed = [value stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length > 80) trimmed = [[trimmed substringToIndex:77] stringByAppendingString:@"..."];
    return trimmed.length ? trimmed : @"Recent chat";
}

static NSArray<NSDictionary *> *CGReadStoredRecents(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:CGRecentsDefaultsKey];
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *valid = [NSMutableArray array];
    for (id raw in (NSArray *)value) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSString *title = [raw[@"title"] isKindOfClass:NSString.class] ? raw[@"title"] : @"";
        if (!title.length) continue;
        [valid addObject:raw];
    }
    return valid;
}

static void CGWriteRecents(NSArray<NSDictionary *> *items) {
    NSArray *limited = items;
    if (limited.count > CGRecentsLimit) limited = [limited subarrayWithRange:NSMakeRange(0, CGRecentsLimit)];
    [NSUserDefaults.standardUserDefaults setObject:limited forKey:CGRecentsDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

static BOOL CGEditableLooksSensitive(id editable) {
    if (!editable) return YES;
    if ([editable respondsToSelector:@selector(isSecureTextEntry)]) {
        BOOL secure = ((BOOL (*)(id, SEL))objc_msgSend)(editable, @selector(isSecureTextEntry));
        if (secure) return YES;
    }
    if ([editable respondsToSelector:@selector(textContentType)]) {
        NSString *type = ((id (*)(id, SEL))objc_msgSend)(editable, @selector(textContentType));
        if ([type isKindOfClass:NSString.class]) {
            NSArray *blocked = @[UITextContentTypeUsername, UITextContentTypePassword, UITextContentTypeNewPassword, UITextContentTypeEmailAddress, UITextContentTypeOneTimeCode];
            for (NSString *candidate in blocked) {
                if (candidate && [type isEqualToString:candidate]) return YES;
            }
        }
    }
    if ([editable respondsToSelector:@selector(keyboardType)]) {
        UIKeyboardType keyboardType = ((UIKeyboardType (*)(id, SEL))objc_msgSend)(editable, @selector(keyboardType));
        if (keyboardType == UIKeyboardTypeEmailAddress) return YES;
    }
    return NO;
}

static NSString *CGEditableText(id editable) {
    if (!editable || CGEditableLooksSensitive(editable)) return nil;
    if (![editable conformsToProtocol:@protocol(UITextInput)]) return nil;
    id<UITextInput> input = (id<UITextInput>)editable;
    UITextPosition *begin = input.beginningOfDocument;
    UITextPosition *end = input.endOfDocument;
    if (!begin || !end) return nil;
    UITextRange *range = [input textRangeFromPosition:begin toPosition:end];
    if (!range) return nil;
    NSString *text = [input textInRange:range];
    if (![text isKindOfClass:NSString.class]) return nil;
    if (text.length > 8000) return nil;
    return text;
}

static void CGSaveLocalPrompt(NSString *prompt) {
    NSString *title = CGPromptTitle(prompt);
    if (!title.length || [title isEqualToString:@"Recent chat"]) return;

    NSString *selectedURL = CGSelectedWebURL(CGCurrentWebRoot());
    NSString *storedURL = CGIsChatGPTURLString(selectedURL) ? selectedURL : @"https://chatgpt.com/";
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSString *identifier = [NSString stringWithFormat:@"local:%.3f:%@", now, NSUUID.UUID.UUIDString];

    NSMutableArray<NSDictionary *> *items = [CGReadStoredRecents() mutableCopy];
    NSDictionary *record = @{
        @"id": identifier,
        @"url": storedURL,
        @"title": title,
        @"date": @(now),
        @"local": @YES
    };
    [items insertObject:record atIndex:0];
    CGWriteRecents(items);
}

static void CGUpdateDraftFromEditable(id editable) {
    if (!editable || CGEditableLooksSensitive(editable)) return;
    NSString *text = CGEditableText(editable);
    if (text == nil) return;

    NSString *selectedURL = CGSelectedWebURL(CGCurrentWebRoot());
    if (selectedURL.length && !CGIsChatGPTURLString(selectedURL)) return;

    NSString *trimmed = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) {
        CGActiveEditable = editable;
        CGCurrentDraft = [trimmed copy];
    }
}

static void CGDraftMonitorTick(__unused NSTimer *timer) {
    id editable = CGActiveEditable;
    if (!editable || !CGCurrentDraft.length) return;
    NSString *current = CGEditableText(editable);
    if (current == nil) return;

    NSString *selectedURL = CGSelectedWebURL(CGCurrentWebRoot());
    if (selectedURL.length && !CGIsChatGPTURLString(selectedURL)) {
        CGCurrentDraft = nil;
        CGActiveEditable = nil;
        return;
    }

    NSString *trimmed = [current stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (trimmed.length) {
        CGCurrentDraft = [trimmed copy];
        return;
    }

    // ChatGPT clears its composer locally as soon as a prompt is submitted.
    // Save that text immediately; this no longer depends on Gecko history or
    // ChatGPT having generated a /c/... URL/title yet.
    NSString *submitted = CGCurrentDraft;
    CGCurrentDraft = nil;
    CGActiveEditable = nil;
    CGSaveLocalPrompt(submitted);
}

static void CGHookedInsertText(id self, SEL _cmd, NSString *text) {
    if (CGOriginalInsertText) ((void (*)(id, SEL, NSString *))CGOriginalInsertText)(self, _cmd, text);
    dispatch_async(dispatch_get_main_queue(), ^{
        CGUpdateDraftFromEditable(self);
    });
}

static void CGHookedDeleteBackward(id self, SEL _cmd) {
    if (CGOriginalDeleteBackward) ((void (*)(id, SEL))CGOriginalDeleteBackward)(self, _cmd);
    dispatch_async(dispatch_get_main_queue(), ^{
        CGUpdateDraftFromEditable(self);
    });
}

static void CGTryInstallChildViewHooks(void) {
    if (CGChildViewHooksInstalled) return;
    Class childView = objc_getClass("ChildView");
    if (!childView) {
        if (++CGChildViewHookAttempts < 100) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                CGTryInstallChildViewHooks();
            });
        }
        return;
    }

    Method insert = class_getInstanceMethod(childView, @selector(insertText:));
    Method delete = class_getInstanceMethod(childView, @selector(deleteBackward));
    if (!insert || !delete) return;

    CGOriginalInsertText = method_getImplementation(insert);
    CGOriginalDeleteBackward = method_getImplementation(delete);
    method_setImplementation(insert, (IMP)CGHookedInsertText);
    method_setImplementation(delete, (IMP)CGHookedDeleteBackward);
    CGChildViewHooksInstalled = YES;

    CGDraftMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 target:[NSBlockOperation blockOperationWithBlock:^{}] selector:@selector(main) userInfo:nil repeats:YES];
    [CGDraftMonitorTimer invalidate];
    CGDraftMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        CGDraftMonitorTick(timer);
    }];
}

void CGResetLocalPromptCapture(void) {
    CGCurrentDraft = nil;
    CGActiveEditable = nil;
}

void CGCaptureWebRecentsFromRoot(UIViewController *root) {
    if (!root) return;
    NSString *selectedURL = CGSelectedWebURL(root);
    if (!CGIsChatConversationURLString(selectedURL)) return;

    // Attach the real conversation URL to the newest locally-captured prompt.
    // This is best-effort only; the prompt itself is already saved even if
    // ChatGPT/Reynard never exposes the SPA URL to Objective-C.
    NSMutableArray<NSDictionary *> *items = [CGReadStoredRecents() mutableCopy];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    for (NSUInteger i = 0; i < items.count; i++) {
        NSMutableDictionary *item = [items[i] mutableCopy];
        NSString *url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : @"";
        NSTimeInterval date = [item[@"date"] doubleValue];
        if (![item[@"local"] boolValue]) continue;
        if (CGIsChatConversationURLString(url)) continue;
        if (now - date > 180.0) break;
        item[@"url"] = selectedURL;
        items[i] = item;
        CGWriteRecents(items);
        break;
    }
}

void CGCaptureWebRecents(void) {
    CGCaptureWebRecentsFromRoot(CGCurrentWebRoot());
}

NSArray<NSDictionary *> *CGWebRecentItems(void) {
    CGCaptureWebRecents();
    return CGReadStoredRecents();
}

void CGClearWebRecents(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:CGRecentsDefaultsKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:CGLegacyRecentsDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    CGResetLocalPromptCapture();
}

void CGDeleteWebRecentURLString(NSString *urlString) {
    if (!urlString.length) return;
    NSMutableArray *items = [CGReadStoredRecents() mutableCopy];
    NSIndexSet *indexes = [items indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
        return [item[@"url"] isEqualToString:urlString];
    }];
    if (indexes.count) [items removeObjectsAtIndexes:indexes];
    CGWriteRecents(items);
}

static UIButton *CGFindNewTabButton(UIView *root) {
    if (!root) return nil;
    if ([root isKindOfClass:UIButton.class]) {
        UIButton *button = (UIButton *)root;
        for (id target in button.allTargets) {
            for (NSString *action in [button actionsForTarget:target forControlEvent:UIControlEventTouchUpInside]) {
                if ([action rangeOfString:@"newTabTapped" options:NSCaseInsensitiveSearch].location != NSNotFound) return button;
            }
        }
    }
    for (UIView *subview in root.subviews) {
        UIButton *found = CGFindNewTabButton(subview);
        if (found) return found;
    }
    return nil;
}

void CGOpenWebRecentURLString(NSString *urlString) {
    UIViewController *root = CGCurrentWebRoot();
    if (!root) return;

    NSString *target = CGIsChatGPTURLString(urlString) ? urlString : @"https://chatgpt.com/";
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:target forKey:@"default.NewTabSettings.customNewTabURL"];
    [defaults synchronize];

    UIButton *button = CGFindNewTabButton(root.view);
    if (button) [button sendActionsForControlEvents:UIControlEventTouchUpInside];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
        [defaults setObject:@"https://chatgpt.com/" forKey:@"default.NewTabSettings.customNewTabURL"];
        [defaults synchronize];
    });
}

__attribute__((constructor))
static void CGInstallLocalPromptCapture(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.551.chatgpt14"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{
            CGTryInstallChildViewHooks();
        });
    }
}
