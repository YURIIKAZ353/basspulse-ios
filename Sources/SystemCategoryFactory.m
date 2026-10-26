#import "SystemCategoryFactory.h"
#import <dlfcn.h>

// The selector is present in generated iOS 26 runtime headers. Exported option
// constants also occur in the iOS 27 SDK's CoreHaptics.tbd. Runtime presence and
// the actual returned category are checked; neither implies background rights.
@interface CHHapticEngine (BPPrivateInitialization)
- (instancetype)initWithAudioSession:(AVAudioSession *)session
                    sessionIsShared:(BOOL)shared
                            options:(NSDictionary *)options
                              error:(NSError **)error;
@property(nonatomic, readonly) NSString *usageCategory;
@property(nonatomic, readonly) NSString *priority;
@end

@interface NSObject (BPPrivateCapabilities)
- (id)player;
- (id)client;
- (unsigned long long)clientID;
- (void)queryServerCapabilities:(NSDictionary *)capabilities
                         reply:(void (^)(NSDictionary * _Nullable, NSError * _Nullable))reply;
@end

@implementation BPSystemCategoryResult
@end

static NSString *BPStringExport(void *handle, const char *name) {
    void *address = dlsym(handle, name);
    if (!address) return nil;
    NSString *value = *(NSString * __unsafe_unretained *)address;
    return [value isKindOfClass:NSString.class] ? value : nil;
}

BPSystemCategoryResult *BPCreateSystemCategoryEngine(AVAudioSession *session) {
    BPSystemCategoryResult *result = [BPSystemCategoryResult new];
    result.detail = @"SystemSound category unavailable";
    void *handle = dlopen("/System/Library/Frameworks/CoreHaptics.framework/CoreHaptics", RTLD_NOW);
    if (!handle) return result;
    @try {
        NSString *key = BPStringExport(handle, "CHHapticEngineOptionKeyUsageCategory");
        NSString *category = BPStringExport(handle, "CHHapticUsageCategorySystemSound");
        SEL initializer = @selector(initWithAudioSession:sessionIsShared:options:error:);
        if (!key || !category || ![CHHapticEngine instancesRespondToSelector:initializer]) {
            result.detail = @"В этой версии iOS отсутствует внутренний интерфейс категории SystemSound.";
            return result;
        }
        NSError *error = nil;
        CHHapticEngine *engine = [[CHHapticEngine alloc] initWithAudioSession:session
                                                           sessionIsShared:YES
                                                                   options:@{key: category}
                                                                     error:&error];
        if (!engine || error) {
            result.detail = [NSString stringWithFormat:@"SystemSound engine rejected: %@", error ?: @"nil engine"];
            return result;
        }
        NSString *actual = [engine respondsToSelector:@selector(usageCategory)] ? engine.usageCategory : nil;
        NSString *priority = [engine respondsToSelector:@selector(priority)] ? engine.priority : @"unknown";
        result.detail = [NSString stringWithFormat:@"requestedCategory=%@ actualCategory=%@ priority=%@",
                         category, actual ?: @"unknown", priority];
        if (![actual isEqualToString:category]) {
            result.detail = [result.detail stringByAppendingString:@"; category not confirmed, no fallback"];
            return result;
        }
        result.engine = engine;
    } @catch (NSException *exception) {
        result.detail = [NSString stringWithFormat:@"SystemSound initialization exception: %@ %@",
                         exception.name, exception.reason ?: @""];
    } @finally {
        dlclose(handle);
    }
    return result;
}

BPSystemCategoryResult *BPRequestBackgroundHaptics(CHHapticEngine *engine) {
    BPSystemCategoryResult *result = [BPSystemCategoryResult new];
    result.detail = @"BackgroundGate: interface unavailable";
    @try {
        if (![engine respondsToSelector:@selector(player)]) return result;
        id player = [engine player];
        if (!player || ![player respondsToSelector:@selector(queryServerCapabilities:reply:)]) return result;
        NSString *clientLabel = @"unknown";
        if ([player respondsToSelector:@selector(client)]) {
            id client = [player client];
            if ([client respondsToSelector:@selector(clientID)]) {
                clientLabel = [NSString stringWithFormat:@"0x%llx", [client clientID]];
            }
        }
        __block BOOL replied = NO;
        __block NSError *replyError = nil;
        __block NSArray *replyKeys = nil;
        // In the inspected iOS 26.1 implementation this is a synchronous XPC
        // capability query. Its AllowBackgroundHaptics entry updates the client
        // policy. We do not patch entitlements, memory, priority or other clients.
        [player queryServerCapabilities:@{@"RequestedLocality": @"Default", @"AllowBackgroundHaptics": @YES}
                                  reply:^(NSDictionary *capabilities, NSError *error) {
            replied = YES;
            replyError = error;
            replyKeys = [capabilities.allKeys sortedArrayUsingSelector:@selector(compare:)];
        }];
        result.detail = [NSString stringWithFormat:
            @"BackgroundGate client=%@ requested AllowBackgroundHaptics=YES replied=%@ error=%@ replyKeys=%@; API reply is not physical confirmation",
            clientLabel, replied ? @"YES" : @"NO", replyError ?: @"none", replyKeys ?: @[]];
        if (replied && !replyError) result.engine = engine;
    } @catch (NSException *exception) {
        result.detail = [NSString stringWithFormat:@"BackgroundGate exception: %@ %@", exception.name, exception.reason ?: @""];
    }
    return result;
}
