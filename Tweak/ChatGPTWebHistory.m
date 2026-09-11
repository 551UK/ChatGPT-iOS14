#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <sqlite3.h>

UIViewController *CGCurrentWebRoot(void);

static NSString * const CGRecentsDefaultsKey = @"CGWebRecentsV5";
static NSString * const CGLegacyRecentsDefaultsKeyV4 = @"CGWebRecentsV4";
static NSString * const CGLegacyRecentsDefaultsKeyV3 = @"CGWebRecentsV3";
static NSUInteger const CGRecentsLimit = 120;

static __weak id CGActiveEditable = nil;
static NSString *CGCurrentDraft = nil;
static NSTimer *CGDraftMonitorTimer = nil;
static IMP CGOriginalInsertText = NULL;
static IMP CGOriginalDeleteBackward = NULL;
static BOOL CGChildViewHooksInstalled = NO;
static NSInteger CGChildViewHookAttempts = 0;
static BOOL CGResolverRunning = NO;

#pragma mark - Reynard tab database

static NSString *CGTabDatabasePath(void) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    return [support stringByAppendingPathComponent:@"AppData/TabManagement/TabManagement"];
}

static sqlite3 *CGOpenTabDatabase(void) {
    NSString *path = CGTabDatabasePath();
    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) return NULL;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK || !db) {
        if (db) sqlite3_close(db);
        return NULL;
    }
    sqlite3_busy_timeout(db, 500);
    return db;
}

static NSString *CGSQLiteString(sqlite3_stmt *stmt, int column) {
    const unsigned char *text = sqlite3_column_text(stmt, column);
    return text ? [NSString stringWithUTF8String:(const char *)text] : nil;
}

static NSDictionary *CGTabSnapshotForID(NSString *tabID) {
    if (!tabID.length) return nil;
    sqlite3 *db = CGOpenTabDatabase();
    if (!db) return nil;

    NSDictionary *result = nil;
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT id, title, url, tab_session_state FROM tabs WHERE id = ? LIMIT 1;";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        sqlite3_bind_text(stmt, 1, tabID.UTF8String, -1, SQLITE_TRANSIENT);
        if (sqlite3_step(stmt) == SQLITE_ROW) {
            NSString *foundID = CGSQLiteString(stmt, 0) ?: tabID;
            NSString *title = CGSQLiteString(stmt, 1) ?: @"";
            NSString *url = CGSQLiteString(stmt, 2) ?: @"";
            NSString *state = CGSQLiteString(stmt, 3) ?: @"";
            result = @{ @"id": foundID, @"title": title, @"url": url, @"state": state };
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return result;
}

static NSDictionary *CGSelectedTabSnapshot(void) {
    sqlite3 *db = CGOpenTabDatabase();
    if (!db) return nil;

    NSString *selectedID = nil;
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT selected_regular_tab_id, selected_private_tab_id, selected_tab_mode FROM tab_state WHERE id = 1 LIMIT 1;";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
        NSString *regularID = CGSQLiteString(stmt, 0);
        NSString *privateID = CGSQLiteString(stmt, 1);
        NSString *mode = CGSQLiteString(stmt, 2) ?: @"regular";
        selectedID = [mode isEqualToString:@"private"] ? privateID : regularID;
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);

    if (selectedID.length) return CGTabSnapshotForID(selectedID);

    // First-run fallback while the state row is still being written.
    db = CGOpenTabDatabase();
    if (!db) return nil;
    NSDictionary *result = nil;
    stmt = NULL;
    if (sqlite3_prepare_v2(db, "SELECT id, title, url, tab_session_state FROM tabs WHERE is_private = 0 ORDER BY position DESC LIMIT 1;", -1, &stmt, NULL) == SQLITE_OK && sqlite3_step(stmt) == SQLITE_ROW) {
        result = @{ @"id": CGSQLiteString(stmt, 0) ?: @"",
                    @"title": CGSQLiteString(stmt, 1) ?: @"",
                    @"url": CGSQLiteString(stmt, 2) ?: @"",
                    @"state": CGSQLiteString(stmt, 3) ?: @"" };
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
    return result;
}

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

static NSString *CGConversationURLFromSessionState(NSString *state) {
    if (!state.length) return nil;
    NSString *unescaped = [state stringByReplacingOccurrencesOfString:@"\\/" withString:@"/"];
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"https?://(?:www\\.)?chatgpt\\.com/(?:c|conversation)/[A-Za-z0-9_-]+" options:NSRegularExpressionCaseInsensitive error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:unescaped options:0 range:NSMakeRange(0, unescaped.length)];
    if (!match || match.range.location == NSNotFound) return nil;
    NSString *url = [unescaped substringWithRange:match.range];
    return CGIsChatConversationURLString(url) ? url : nil;
}

static NSString *CGResolvedConversationURL(NSDictionary *snapshot) {
    if (![snapshot isKindOfClass:NSDictionary.class]) return nil;
    NSString *url = [snapshot[@"url"] isKindOfClass:NSString.class] ? snapshot[@"url"] : nil;
    if (CGIsChatConversationURLString(url)) return url;
    NSString *state = [snapshot[@"state"] isKindOfClass:NSString.class] ? snapshot[@"state"] : nil;
    return CGConversationURLFromSessionState(state);
}

NSString *CGStoredSelectedWebURL(void) {
    NSDictionary *snapshot = CGSelectedTabSnapshot();
    NSString *url = [snapshot[@"url"] isKindOfClass:NSString.class] ? snapshot[@"url"] : nil;
    NSString *resolved = CGResolvedConversationURL(snapshot);
    return resolved ?: url;
}

#pragma mark - Local Recents store

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
    NSArray *limited = items ?: @[];
    if (limited.count > CGRecentsLimit) limited = [limited subarrayWithRange:NSMakeRange(0, CGRecentsLimit)];
    [NSUserDefaults.standardUserDefaults setObject:limited forKey:CGRecentsDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

static BOOL CGResolveStoredRecentsOnce(void) {
    NSMutableArray<NSDictionary *> *items = [CGReadStoredRecents() mutableCopy];
    BOOL changed = NO;
    BOOL unresolved = NO;

    for (NSUInteger i = 0; i < items.count; i++) {
        NSDictionary *raw = items[i];
        NSString *tabID = [raw[@"tab_id"] isKindOfClass:NSString.class] ? raw[@"tab_id"] : nil;
        NSString *oldURL = [raw[@"url"] isKindOfClass:NSString.class] ? raw[@"url"] : nil;
        if (!tabID.length || CGIsChatConversationURLString(oldURL)) continue;

        NSDictionary *snapshot = CGTabSnapshotForID(tabID);
        NSString *resolved = CGResolvedConversationURL(snapshot);
        if (resolved.length) {
            NSMutableDictionary *item = [raw mutableCopy];
            item[@"url"] = resolved;
            items[i] = item;
            changed = YES;
        } else if (snapshot) {
            unresolved = YES;
        }
    }

    if (changed) CGWriteRecents(items);
    return unresolved;
}

static void CGRunResolverAttempt(NSUInteger attempt) {
    if (attempt >= 50) {
        CGResolverRunning = NO;
        return;
    }

    BOOL unresolved = CGResolveStoredRecentsOnce();
    if (!unresolved) {
        CGResolverRunning = NO;
        return;
    }

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.40 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        CGRunResolverAttempt(attempt + 1);
    });
}

static void CGStartResolver(void) {
    if (CGResolverRunning) return;
    CGResolverRunning = YES;
    CGRunResolverAttempt(0);
}

#pragma mark - Prompt capture

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
    if (![text isKindOfClass:NSString.class] || text.length > 8000) return nil;
    return text;
}

static void CGSaveLocalPrompt(NSString *prompt) {
    NSString *title = CGPromptTitle(prompt);
    if (!title.length || [title isEqualToString:@"Recent chat"]) return;

    NSDictionary *snapshot = CGSelectedTabSnapshot();
    NSString *tabID = [snapshot[@"id"] isKindOfClass:NSString.class] ? snapshot[@"id"] : nil;
    NSString *selectedURL = [snapshot[@"url"] isKindOfClass:NSString.class] ? snapshot[@"url"] : nil;
    NSString *resolvedURL = CGResolvedConversationURL(snapshot);
    NSString *storedURL = resolvedURL ?: (CGIsChatGPTURLString(selectedURL) ? selectedURL : @"https://chatgpt.com/");
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;

    NSMutableArray<NSDictionary *> *items = [CGReadStoredRecents() mutableCopy];
    NSUInteger existingIndex = NSNotFound;
    if (tabID.length) {
        existingIndex = [items indexOfObjectPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
            NSString *existingTabID = [item[@"tab_id"] isKindOfClass:NSString.class] ? item[@"tab_id"] : nil;
            return [existingTabID isEqualToString:tabID];
        }];
    }

    if (existingIndex != NSNotFound) {
        NSMutableDictionary *existing = [items[existingIndex] mutableCopy];
        existing[@"date"] = @(now);
        if (resolvedURL.length) existing[@"url"] = resolvedURL;
        [items removeObjectAtIndex:existingIndex];
        [items insertObject:existing atIndex:0];
    } else {
        NSString *identifier = tabID.length ? [@"tab:" stringByAppendingString:tabID] : [NSString stringWithFormat:@"local:%.3f:%@", now, NSUUID.UUID.UUIDString];
        NSMutableDictionary *record = [@{
            @"id": identifier,
            @"url": storedURL,
            @"title": title,
            @"date": @(now),
            @"local": @YES
        } mutableCopy];
        if (tabID.length) record[@"tab_id"] = tabID;
        [items insertObject:record atIndex:0];
    }

    CGWriteRecents(items);
    if (!resolvedURL.length && tabID.length) CGStartResolver();
}

static void CGUpdateDraftFromEditable(id editable) {
    if (!editable || CGEditableLooksSensitive(editable)) return;
    NSString *text = CGEditableText(editable);
    if (text == nil) return;

    NSString *selectedURL = CGStoredSelectedWebURL();
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

    NSString *selectedURL = CGStoredSelectedWebURL();
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

    // ChatGPT clears the composer immediately after submission. Save the first
    // prompt against Reynard's actual tab UUID, then resolve that tab's SPA URL
    // to the final /c/... conversation link in the background.
    NSString *submitted = CGCurrentDraft;
    CGCurrentDraft = nil;
    CGActiveEditable = nil;
    CGSaveLocalPrompt(submitted);
}

static void CGHookedInsertText(id self, SEL _cmd, NSString *text) {
    if (CGOriginalInsertText) ((void (*)(id, SEL, NSString *))CGOriginalInsertText)(self, _cmd, text);
    dispatch_async(dispatch_get_main_queue(), ^{ CGUpdateDraftFromEditable(self); });
}

static void CGHookedDeleteBackward(id self, SEL _cmd) {
    if (CGOriginalDeleteBackward) ((void (*)(id, SEL))CGOriginalDeleteBackward)(self, _cmd);
    dispatch_async(dispatch_get_main_queue(), ^{ CGUpdateDraftFromEditable(self); });
}

static void CGTryInstallChildViewHooks(void) {
    if (CGChildViewHooksInstalled) return;
    Class childView = objc_getClass("ChildView");
    if (!childView) {
        if (++CGChildViewHookAttempts < 100) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.10 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ CGTryInstallChildViewHooks(); });
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

    CGDraftMonitorTimer = [NSTimer scheduledTimerWithTimeInterval:0.25 repeats:YES block:^(NSTimer *timer) {
        CGDraftMonitorTick(timer);
    }];
}

void CGResetLocalPromptCapture(void) {
    CGCurrentDraft = nil;
    CGActiveEditable = nil;
}

void CGCaptureWebRecentsFromRoot(__unused UIViewController *root) {
    CGResolveStoredRecentsOnce();
}

void CGCaptureWebRecents(void) {
    CGResolveStoredRecentsOnce();
}

NSArray<NSDictionary *> *CGWebRecentItems(void) {
    CGResolveStoredRecentsOnce();
    return CGReadStoredRecents();
}

void CGClearWebRecents(void) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:CGRecentsDefaultsKey];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:CGLegacyRecentsDefaultsKeyV4];
    [NSUserDefaults.standardUserDefaults removeObjectForKey:CGLegacyRecentsDefaultsKeyV3];
    [NSUserDefaults.standardUserDefaults synchronize];
    CGResetLocalPromptCapture();
}

#pragma mark - Opening a saved conversation

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

static void CGOpenExactWebURL(NSString *urlString) {
    UIViewController *root = CGCurrentWebRoot();
    if (!root || !CGIsChatConversationURLString(urlString)) return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:urlString forKey:@"default.NewTabSettings.customNewTabURL"];
    [defaults synchronize];

    UIButton *button = CGFindNewTabButton(root.view);
    if (button) [button sendActionsForControlEvents:UIControlEventTouchUpInside];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
        [defaults setObject:@"https://chatgpt.com/" forKey:@"default.NewTabSettings.customNewTabURL"];
        [defaults synchronize];
    });
}

BOOL CGOpenWebRecentItem(NSDictionary *item) {
    if (![item isKindOfClass:NSDictionary.class]) return NO;

    NSString *tabID = [item[@"tab_id"] isKindOfClass:NSString.class] ? item[@"tab_id"] : nil;
    NSString *targetURL = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : nil;

    if (tabID.length) {
        NSDictionary *snapshot = CGTabSnapshotForID(tabID);
        NSString *resolved = CGResolvedConversationURL(snapshot);
        if (resolved.length) targetURL = resolved;

        NSDictionary *selected = CGSelectedTabSnapshot();
        NSString *selectedID = [selected[@"id"] isKindOfClass:NSString.class] ? selected[@"id"] : nil;
        if (selectedID.length && [selectedID isEqualToString:tabID]) {
            // That exact Gecko tab is already selected, so simply dismissing the
            // Recents sheet returns to the original live conversation.
            return YES;
        }
    }

    if (!CGIsChatConversationURLString(targetURL)) return NO;
    CGOpenExactWebURL(targetURL);
    return YES;
}

void CGOpenWebRecentURLString(NSString *urlString) {
    if (CGIsChatConversationURLString(urlString)) CGOpenExactWebURL(urlString);
}

__attribute__((constructor))
static void CGInstallLocalPromptCapture(void) {
    @autoreleasepool {
        if (![[NSBundle mainBundle].bundleIdentifier isEqualToString:@"com.551.chatgpt14"]) return;
        dispatch_async(dispatch_get_main_queue(), ^{ CGTryInstallChildViewHooks(); });
    }
}
