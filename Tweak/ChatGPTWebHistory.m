#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <sqlite3.h>

UIViewController *CGCurrentWebRoot(void);

static NSString * const CGRecentsDefaultsKey = @"CGWebRecentsV3";
static NSUInteger const CGRecentsLimit = 120;

static NSString *CGSupportPath(NSString *relativePath) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    return [support stringByAppendingPathComponent:relativePath];
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

static NSString *CGCleanChatTitle(NSString *title) {
    NSString *value = [title ?: @"" stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSArray<NSString *> *suffixes = @[@" | ChatGPT", @" - ChatGPT", @" — ChatGPT"];
    for (NSString *suffix in suffixes) {
        if ([value.lowercaseString hasSuffix:suffix.lowercaseString] && value.length > suffix.length) {
            value = [[value substringToIndex:value.length - suffix.length] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
            break;
        }
    }
    return value;
}

static BOOL CGTitleIsUseful(NSString *title) {
    NSString *value = CGCleanChatTitle(title);
    if (!value.length) return NO;
    NSArray<NSString *> *generic = @[@"chatgpt", @"new chat", @"recent chat", @"openai"];
    for (NSString *item in generic) {
        if ([value caseInsensitiveCompare:item] == NSOrderedSame) return NO;
    }
    return YES;
}

static NSString *CGDisplayTitle(NSString *title) {
    NSString *value = CGCleanChatTitle(title);
    return CGTitleIsUseful(value) ? value : @"Recent chat";
}

static NSString *CGIdentityForRecent(NSString *url, NSString *title) {
    if (CGIsChatConversationURLString(url)) return [@"url:" stringByAppendingString:url];
    if (CGIsChatGPTURLString(url) && CGTitleIsUseful(title)) {
        return [@"title:" stringByAppendingString:CGCleanChatTitle(title).lowercaseString];
    }
    return nil;
}

static NSArray<NSDictionary *> *CGReadStoredRecents(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:CGRecentsDefaultsKey];
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *valid = [NSMutableArray array];
    for (id raw in (NSArray *)value) {
        if (![raw isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *item = (NSDictionary *)raw;
        NSString *url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : nil;
        NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : nil;
        if (!CGIdentityForRecent(url, title)) continue;
        [valid addObject:item];
    }
    return valid;
}

static void CGMergeRecent(NSMutableDictionary<NSString *, NSMutableDictionary *> *map,
                          NSString *url,
                          NSString *title,
                          NSTimeInterval timestamp,
                          BOOL bumpExisting) {
    NSString *identity = CGIdentityForRecent(url, title);
    if (!identity.length) return;
    if (timestamp <= 0) timestamp = NSDate.date.timeIntervalSince1970;

    NSString *cleanTitle = CGDisplayTitle(title);
    NSMutableDictionary *existing = map[identity];
    if (!existing) {
        map[identity] = [@{@"id": identity,
                           @"url": url ?: @"https://chatgpt.com/",
                           @"title": cleanTitle,
                           @"date": @(timestamp)} mutableCopy];
        return;
    }

    NSString *oldTitle = [existing[@"title"] isKindOfClass:NSString.class] ? existing[@"title"] : @"";
    BOOL newTitleIsUseful = CGTitleIsUseful(cleanTitle);
    BOOL oldTitleIsGeneric = !CGTitleIsUseful(oldTitle);
    if (newTitleIsUseful || oldTitleIsGeneric) existing[@"title"] = cleanTitle;

    // If we first saw the page while it was still at chatgpt.com/ and later get
    // the real /c/... URL, keep the exact conversation URL.
    NSString *oldURL = [existing[@"url"] isKindOfClass:NSString.class] ? existing[@"url"] : @"";
    if (CGIsChatConversationURLString(url) || !oldURL.length) existing[@"url"] = url;

    NSTimeInterval oldDate = [existing[@"date"] doubleValue];
    if (bumpExisting || timestamp > oldDate) existing[@"date"] = @(timestamp);
}

static id CGSafeValueForKey(id object, NSString *key) {
    if (!object || !key.length) return nil;
    @try {
        return [object valueForKey:key];
    } @catch (__unused NSException *exception) {
        return nil;
    }
}

static void CGCaptureTabObject(NSMutableDictionary<NSString *, NSMutableDictionary *> *map, id tab, BOOL selected) {
    if (!tab) return;
    id rawURL = CGSafeValueForKey(tab, @"url");
    id rawTitle = CGSafeValueForKey(tab, @"title");
    NSString *url = [rawURL isKindOfClass:NSString.class] ? rawURL : ([rawURL isKindOfClass:NSURL.class] ? [(NSURL *)rawURL absoluteString] : nil);
    NSString *title = [rawTitle isKindOfClass:NSString.class] ? rawTitle : @"";
    if (!url.length) return;
    CGMergeRecent(map, url, title, NSDate.date.timeIntervalSince1970, selected);
}

static void CGCaptureFromLiveRoot(NSMutableDictionary<NSString *, NSMutableDictionary *> *map, UIViewController *root) {
    if (!root) return;

    // Reynard's BrowserViewController owns the live TabManager. On builds where
    // Swift exposes these properties through KVC this gives us the current URL
    // and generated ChatGPT title immediately, without waiting for SQLite to flush.
    id manager = CGSafeValueForKey(root, @"tabManager");
    if (!manager) return;

    id selected = CGSafeValueForKey(manager, @"selectedTab");
    CGCaptureTabObject(map, selected, YES);

    id tabs = CGSafeValueForKey(manager, @"regularTabs");
    if ([tabs isKindOfClass:NSArray.class]) {
        for (id tab in (NSArray *)tabs) {
            if (tab == selected) continue;
            CGCaptureTabObject(map, tab, NO);
        }
    }
}

static void CGCaptureFromHistoryDB(NSMutableDictionary<NSString *, NSMutableDictionary *> *map) {
    NSString *path = CGSupportPath(@"AppData/History/History");
    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) return;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK || !db) {
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 900);
    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT title, url, updated_at FROM history ORDER BY updated_at DESC LIMIT 500;";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *titleText = sqlite3_column_text(stmt, 0);
            const unsigned char *urlText = sqlite3_column_text(stmt, 1);
            if (!urlText) continue;
            NSString *url = [NSString stringWithUTF8String:(const char *)urlText];
            NSString *title = titleText ? [NSString stringWithUTF8String:(const char *)titleText] : @"";
            CGMergeRecent(map, url, title, sqlite3_column_double(stmt, 2), NO);
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
}

static void CGCaptureFromTabDB(NSMutableDictionary<NSString *, NSMutableDictionary *> *map) {
    NSString *path = CGSupportPath(@"AppData/TabManagement/TabManagement");
    if (!path.length || ![NSFileManager.defaultManager fileExistsAtPath:path]) return;

    sqlite3 *db = NULL;
    if (sqlite3_open_v2(path.UTF8String, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, NULL) != SQLITE_OK || !db) {
        if (db) sqlite3_close(db);
        return;
    }
    sqlite3_busy_timeout(db, 900);

    NSString *selectedID = nil;
    sqlite3_stmt *stateStmt = NULL;
    if (sqlite3_prepare_v2(db, "SELECT selected_regular_tab_id FROM tab_state WHERE id=1 LIMIT 1;", -1, &stateStmt, NULL) == SQLITE_OK && sqlite3_step(stateStmt) == SQLITE_ROW) {
        const unsigned char *text = sqlite3_column_text(stateStmt, 0);
        if (text) selectedID = [NSString stringWithUTF8String:(const char *)text];
    }
    if (stateStmt) sqlite3_finalize(stateStmt);

    sqlite3_stmt *stmt = NULL;
    const char *sql = "SELECT id, title, url, created_at, position FROM tabs WHERE is_private=0 ORDER BY position DESC;";
    if (sqlite3_prepare_v2(db, sql, -1, &stmt, NULL) == SQLITE_OK) {
        while (sqlite3_step(stmt) == SQLITE_ROW) {
            const unsigned char *idText = sqlite3_column_text(stmt, 0);
            const unsigned char *titleText = sqlite3_column_text(stmt, 1);
            const unsigned char *urlText = sqlite3_column_text(stmt, 2);
            if (!urlText) continue;

            NSString *tabID = idText ? [NSString stringWithUTF8String:(const char *)idText] : @"";
            NSString *title = titleText ? [NSString stringWithUTF8String:(const char *)titleText] : @"";
            NSString *url = [NSString stringWithUTF8String:(const char *)urlText];
            NSTimeInterval created = sqlite3_column_double(stmt, 3);
            BOOL selected = selectedID.length && [selectedID isEqualToString:tabID];
            NSTimeInterval seen = selected ? NSDate.date.timeIntervalSince1970 : created;
            CGMergeRecent(map, url, title, seen, selected);
        }
    }
    if (stmt) sqlite3_finalize(stmt);
    sqlite3_close(db);
}

static void CGWriteMergedRecents(NSMutableDictionary<NSString *, NSMutableDictionary *> *map) {
    NSArray *sorted = [[map allValues] sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSTimeInterval da = [a[@"date"] doubleValue];
        NSTimeInterval db = [b[@"date"] doubleValue];
        if (da > db) return NSOrderedAscending;
        if (da < db) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    if (sorted.count > CGRecentsLimit) sorted = [sorted subarrayWithRange:NSMakeRange(0, CGRecentsLimit)];
    [NSUserDefaults.standardUserDefaults setObject:sorted forKey:CGRecentsDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
}

void CGCaptureWebRecentsFromRoot(UIViewController *root) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *map = [NSMutableDictionary dictionary];
    for (NSDictionary *item in CGReadStoredRecents()) {
        NSString *url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : @"";
        NSString *title = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
        NSString *identity = [item[@"id"] isKindOfClass:NSString.class] ? item[@"id"] : CGIdentityForRecent(url, title);
        if (!identity.length) continue;
        map[identity] = [item mutableCopy];
    }

    // Use all three sources. Live tab state is fastest, TabManagement is the
    // durable current-tab source, and History is a final fallback.
    CGCaptureFromLiveRoot(map, root);
    CGCaptureFromTabDB(map);
    CGCaptureFromHistoryDB(map);
    CGWriteMergedRecents(map);
}

void CGCaptureWebRecents(void) {
    CGCaptureWebRecentsFromRoot(CGCurrentWebRoot());
}

NSArray<NSDictionary *> *CGWebRecentItems(void) {
    CGCaptureWebRecents();
    return CGReadStoredRecents();
}

void CGDeleteWebRecentURLString(NSString *urlString) {
    if (!urlString.length) return;
    NSMutableArray *items = [CGReadStoredRecents() mutableCopy];
    NSIndexSet *indexes = [items indexesOfObjectsPassingTest:^BOOL(NSDictionary *item, NSUInteger idx, BOOL *stop) {
        return [item[@"url"] isEqualToString:urlString];
    }];
    if (indexes.count) [items removeObjectsAtIndexes:indexes];
    [NSUserDefaults.standardUserDefaults setObject:items forKey:CGRecentsDefaultsKey];
    [NSUserDefaults.standardUserDefaults synchronize];
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
    if (!root || !CGIsChatGPTURLString(urlString)) return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:urlString forKey:@"default.NewTabSettings.customNewTabURL"];
    [defaults synchronize];

    UIButton *button = CGFindNewTabButton(root.view);
    if (button) [button sendActionsForControlEvents:UIControlEventTouchUpInside];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.35 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
        [defaults setObject:@"https://chatgpt.com/" forKey:@"default.NewTabSettings.customNewTabURL"];
        [defaults synchronize];
    });
}
