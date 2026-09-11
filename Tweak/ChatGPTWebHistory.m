#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <sqlite3.h>

UIViewController *CGCurrentWebRoot(void);

static NSString * const CGRecentsDefaultsKey = @"CGWebRecentsV2";
static NSUInteger const CGRecentsLimit = 120;

static NSString *CGSupportPath(NSString *relativePath) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    if (!support.length) return nil;
    return [support stringByAppendingPathComponent:relativePath];
}

static BOOL CGIsChatConversationURLString(NSString *urlString) {
    NSURL *url = [NSURL URLWithString:urlString ?: @""];
    if (!url) return NO;
    NSString *host = url.host.lowercaseString ?: @"";
    if (!([host isEqualToString:@"chatgpt.com"] || [host isEqualToString:@"www.chatgpt.com"])) return NO;
    NSString *path = url.path.lowercaseString ?: @"";
    return [path hasPrefix:@"/c/"] || [path containsString:@"/c/"];
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
    if (!value.length || [value caseInsensitiveCompare:@"ChatGPT"] == NSOrderedSame || [value caseInsensitiveCompare:@"New chat"] == NSOrderedSame) {
        return @"Recent chat";
    }
    return value;
}

static NSArray<NSDictionary *> *CGReadStoredRecents(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:CGRecentsDefaultsKey];
    if (![value isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *valid = [NSMutableArray array];
    for (id item in (NSArray *)value) {
        if (![item isKindOfClass:NSDictionary.class]) continue;
        NSString *url = [item[@"url"] isKindOfClass:NSString.class] ? item[@"url"] : nil;
        if (!CGIsChatConversationURLString(url)) continue;
        [valid addObject:item];
    }
    return valid;
}

static void CGMergeRecent(NSMutableDictionary<NSString *, NSMutableDictionary *> *map,
                          NSString *url,
                          NSString *title,
                          NSTimeInterval timestamp,
                          BOOL bumpExisting) {
    if (!CGIsChatConversationURLString(url)) return;
    if (timestamp <= 0) timestamp = NSDate.date.timeIntervalSince1970;

    NSString *cleanTitle = CGCleanChatTitle(title);
    NSMutableDictionary *existing = map[url];
    if (!existing) {
        map[url] = [@{@"url": url,
                      @"title": cleanTitle,
                      @"date": @(timestamp)} mutableCopy];
        return;
    }

    NSString *oldTitle = [existing[@"title"] isKindOfClass:NSString.class] ? existing[@"title"] : @"";
    BOOL newTitleIsUseful = ![cleanTitle isEqualToString:@"Recent chat"];
    BOOL oldTitleIsGeneric = !oldTitle.length || [oldTitle isEqualToString:@"Recent chat"];
    if (newTitleIsUseful || oldTitleIsGeneric) existing[@"title"] = cleanTitle;

    NSTimeInterval oldDate = [existing[@"date"] doubleValue];
    if (bumpExisting || timestamp > oldDate) existing[@"date"] = @(timestamp);
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

void CGCaptureWebRecents(void) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *map = [NSMutableDictionary dictionary];
    for (NSDictionary *item in CGReadStoredRecents()) {
        NSString *url = item[@"url"];
        if (!url.length) continue;
        map[url] = [item mutableCopy];
    }

    // Reynard persists the current tab URL and page title on every Gecko
    // location/title change. This is more reliable for ChatGPT's SPA than browser
    // history alone, so use it first and keep history as a fallback.
    CGCaptureFromTabDB(map);
    CGCaptureFromHistoryDB(map);

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
    if (!root || !CGIsChatConversationURLString(urlString)) return;

    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
    [defaults setObject:urlString forKey:@"default.NewTabSettings.customNewTabURL"];
    [defaults synchronize];

    UIButton *button = CGFindNewTabButton(root.view);
    if (button) [button sendActionsForControlEvents:UIControlEventTouchUpInside];

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.80 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [defaults setObject:@"customURL" forKey:@"default.NewTabSettings.newTabDisplayOption"];
        [defaults setObject:@"https://chatgpt.com/" forKey:@"default.NewTabSettings.customNewTabURL"];
        [defaults synchronize];
    });
}
