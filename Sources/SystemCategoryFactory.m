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
