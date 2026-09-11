#pragma mark - CGModels.h

@interface CGAttachment : NSObject
@property (nonatomic, copy) NSString *name;
@property (nonatomic, copy) NSString *mimeType;
@property (nonatomic, strong) NSData *data;
@property (nonatomic, assign) BOOL image;
- (NSDictionary *)dictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;
@end

@interface CGMessage : NSObject
@property (nonatomic, copy) NSString *role;
@property (nonatomic, copy) NSString *text;
@property (nonatomic, strong) NSMutableArray<CGAttachment *> *attachments;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *sources;
@property (nonatomic, strong) NSMutableArray<NSString *> *generatedImagePaths;
@property (nonatomic, strong) NSDate *date;
- (NSDictionary *)dictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;
@end

@interface CGConversation : NSObject
@property (nonatomic, copy) NSString *identifier;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *previousResponseID;
@property (nonatomic, strong) NSMutableArray<CGMessage *> *messages;
@property (nonatomic, strong) NSDate *updatedAt;
- (NSDictionary *)dictionary;
+ (instancetype)fromDictionary:(NSDictionary *)dict;
@end

#pragma mark - CGModels.m

@implementation CGAttachment
- (NSDictionary *)dictionary {
    return @{ @"name": self.name ?: @"Attachment",
              @"mime": self.mimeType ?: @"application/octet-stream",
              @"data": [self.data base64EncodedStringWithOptions:0] ?: @"",
              @"image": @(self.image) };
}
+ (instancetype)fromDictionary:(NSDictionary *)dict {
    CGAttachment *a = [CGAttachment new];
    a.name = dict[@"name"] ?: @"Attachment";
    a.mimeType = dict[@"mime"] ?: @"application/octet-stream";
    a.data = [[NSData alloc] initWithBase64EncodedString:dict[@"data"] ?: @"" options:0] ?: [NSData data];
    a.image = [dict[@"image"] boolValue];
    return a;
}
@end

@implementation CGMessage
- (instancetype)init {
    if ((self = [super init])) {
        _attachments = [NSMutableArray array]; _sources = [NSMutableArray array]; _generatedImagePaths = [NSMutableArray array]; _date = [NSDate date];
    }
    return self;
}
- (NSDictionary *)dictionary {
    NSMutableArray *atts = [NSMutableArray array]; for (CGAttachment *a in self.attachments) [atts addObject:a.dictionary];
    return @{ @"role": self.role ?: @"user", @"text": self.text ?: @"", @"attachments": atts,
              @"sources": self.sources ?: @[], @"images": self.generatedImagePaths ?: @[], @"date": @([self.date timeIntervalSince1970]) };
}
+ (instancetype)fromDictionary:(NSDictionary *)dict {
    CGMessage *m = [CGMessage new]; m.role = dict[@"role"] ?: @"user"; m.text = dict[@"text"] ?: @"";
    for (NSDictionary *a in dict[@"attachments"] ?: @[]) [m.attachments addObject:[CGAttachment fromDictionary:a]];
    [m.sources addObjectsFromArray:dict[@"sources"] ?: @[]]; [m.generatedImagePaths addObjectsFromArray:dict[@"images"] ?: @[]];
    if (dict[@"date"]) m.date = [NSDate dateWithTimeIntervalSince1970:[dict[@"date"] doubleValue]];
    return m;
}
@end

@implementation CGConversation
- (instancetype)init {
    if ((self = [super init])) { _identifier = NSUUID.UUID.UUIDString; _title = @"New chat"; _messages = [NSMutableArray array]; _updatedAt = [NSDate date]; }
    return self;
}
- (NSDictionary *)dictionary {
    NSMutableArray *msgs = [NSMutableArray array]; for (CGMessage *m in self.messages) [msgs addObject:m.dictionary];
    return @{ @"id": self.identifier ?: NSUUID.UUID.UUIDString, @"title": self.title ?: @"New chat", @"previous": self.previousResponseID ?: @"",
              @"messages": msgs, @"updated": @([self.updatedAt timeIntervalSince1970]) };
}
+ (instancetype)fromDictionary:(NSDictionary *)dict {
    CGConversation *c = [CGConversation new]; c.identifier = dict[@"id"] ?: NSUUID.UUID.UUIDString; c.title = dict[@"title"] ?: @"New chat";
    c.previousResponseID = [dict[@"previous"] length] ? dict[@"previous"] : nil; [c.messages removeAllObjects];
    for (NSDictionary *m in dict[@"messages"] ?: @[]) [c.messages addObject:[CGMessage fromDictionary:m]];
    if (dict[@"updated"]) c.updatedAt = [NSDate dateWithTimeIntervalSince1970:[dict[@"updated"] doubleValue]];
    return c;
}
@end

#pragma mark - CGStore.h

@interface CGStore : NSObject
+ (instancetype)shared;
@property (nonatomic, strong) NSMutableArray<CGConversation *> *conversations;
@property (nonatomic, copy) NSString *currentConversationID;
- (CGConversation *)currentConversation;
- (CGConversation *)newConversation;
- (void)deleteConversation:(CGConversation *)conversation;
- (void)save;
- (NSString *)apiKey;
- (void)setAPIKey:(NSString *)key;
- (NSString *)model;
- (void)setModel:(NSString *)model;
- (NSString *)reasoningEffort;
- (void)setReasoningEffort:(NSString *)effort;
- (BOOL)webSearchEnabled;
- (void)setWebSearchEnabled:(BOOL)enabled;
- (BOOL)codeInterpreterEnabled;
- (void)setCodeInterpreterEnabled:(BOOL)enabled;
- (BOOL)imageGenerationEnabled;
- (void)setImageGenerationEnabled:(BOOL)enabled;
@end

#pragma mark - CGStore.m

static NSString * const CGCurrentKey = @"cg_current";
static NSString * const CGService = @"com.551.chatgpt14.api";

@implementation CGStore
+ (instancetype)shared { static CGStore *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [CGStore new]; }); return s; }
- (instancetype)init {
    if ((self = [super init])) {
        _conversations = [NSMutableArray array];
        NSData *saved = [NSData dataWithContentsOfFile:[self conversationsPath]];
        NSArray *raw = saved ? [NSJSONSerialization JSONObjectWithData:saved options:0 error:nil] : nil;
        if ([raw isKindOfClass:NSArray.class]) for (NSDictionary *d in raw) [_conversations addObject:[CGConversation fromDictionary:d]];
        _currentConversationID = [[NSUserDefaults standardUserDefaults] stringForKey:CGCurrentKey];
        if (_conversations.count == 0) [self newConversation];
        if (![self currentConversation]) _currentConversationID = _conversations.firstObject.identifier;
    }
    return self;
}
- (CGConversation *)currentConversation { for (CGConversation *c in self.conversations) if ([c.identifier isEqualToString:self.currentConversationID]) return c; return nil; }
- (CGConversation *)newConversation { CGConversation *c = [CGConversation new]; [self.conversations insertObject:c atIndex:0]; self.currentConversationID = c.identifier; [self save]; return c; }
- (void)deleteConversation:(CGConversation *)conversation { if (!conversation) return; [self.conversations removeObject:conversation]; if (self.conversations.count == 0) [self newConversation]; else if ([self.currentConversationID isEqualToString:conversation.identifier]) self.currentConversationID = self.conversations.firstObject.identifier; [self save]; }
- (NSString *)conversationsPath {
    NSString *dir = [NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES) firstObject];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"conversations.json"];
}
- (void)save {
    NSMutableArray *raw = [NSMutableArray array]; for (CGConversation *c in self.conversations) [raw addObject:c.dictionary];
    NSData *json = [NSJSONSerialization dataWithJSONObject:raw options:0 error:nil]; if (json) [json writeToFile:[self conversationsPath] atomically:YES];
    NSUserDefaults *d = NSUserDefaults.standardUserDefaults; [d setObject:self.currentConversationID forKey:CGCurrentKey]; [d synchronize];
}
- (NSString *)apiKey {
    NSDictionary *q = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService:CGService,
                        (__bridge id)kSecReturnData:@YES, (__bridge id)kSecMatchLimit:(__bridge id)kSecMatchLimitOne};
    CFTypeRef result = NULL; OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)q, &result);
    if (status == errSecSuccess && result) { NSData *data = CFBridgingRelease(result); return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]; }
    return [NSUserDefaults.standardUserDefaults stringForKey:@"cg_api_fallback"] ?: @"";
}
- (void)setAPIKey:(NSString *)key {
    NSData *data = [key dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *base = @{(__bridge id)kSecClass:(__bridge id)kSecClassGenericPassword, (__bridge id)kSecAttrService:CGService};
    SecItemDelete((__bridge CFDictionaryRef)base);
    if (key.length) { NSMutableDictionary *add = [base mutableCopy]; add[(__bridge id)kSecValueData] = data; OSStatus s = SecItemAdd((__bridge CFDictionaryRef)add, NULL); if (s != errSecSuccess) [NSUserDefaults.standardUserDefaults setObject:key forKey:@"cg_api_fallback"]; }
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"cg_api_fallback"];
}
- (NSString *)model { return [NSUserDefaults.standardUserDefaults stringForKey:@"cg_model"] ?: @"gpt-5.6"; }
- (void)setModel:(NSString *)model { [NSUserDefaults.standardUserDefaults setObject:model forKey:@"cg_model"]; }
- (NSString *)reasoningEffort { return [NSUserDefaults.standardUserDefaults stringForKey:@"cg_reason"] ?: @"medium"; }
- (void)setReasoningEffort:(NSString *)effort { [NSUserDefaults.standardUserDefaults setObject:effort forKey:@"cg_reason"]; }
- (BOOL)webSearchEnabled { return [NSUserDefaults.standardUserDefaults objectForKey:@"cg_web"] ? [NSUserDefaults.standardUserDefaults boolForKey:@"cg_web"] : YES; }
- (void)setWebSearchEnabled:(BOOL)e { [NSUserDefaults.standardUserDefaults setBool:e forKey:@"cg_web"]; }
- (BOOL)codeInterpreterEnabled { return [NSUserDefaults.standardUserDefaults objectForKey:@"cg_code"] ? [NSUserDefaults.standardUserDefaults boolForKey:@"cg_code"] : YES; }
- (void)setCodeInterpreterEnabled:(BOOL)e { [NSUserDefaults.standardUserDefaults setBool:e forKey:@"cg_code"]; }
- (BOOL)imageGenerationEnabled { return [NSUserDefaults.standardUserDefaults objectForKey:@"cg_imggen"] ? [NSUserDefaults.standardUserDefaults boolForKey:@"cg_imggen"] : YES; }
- (void)setImageGenerationEnabled:(BOOL)e { [NSUserDefaults.standardUserDefaults setBool:e forKey:@"cg_imggen"]; }
@end
