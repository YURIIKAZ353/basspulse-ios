#import "CaptureRuntimeProbe.h"
#import <objc/runtime.h>

// Read metadata only. No guessed private setters, recording permissions or
// system preferences are changed by this probe.
NSString *BPCaptureRuntimeDescription(NSObject *configuration) {
    NSMutableArray<NSString *> *properties = [NSMutableArray array];
    NSMutableArray<NSString *> *selectors = [NSMutableArray array];
    Class cls = configuration.class;
    unsigned count = 0;
    objc_property_t *list = class_copyPropertyList(cls, &count);
    for (unsigned i = 0; i < count; i++) {
        [properties addObject:@(property_getName(list[i]))];
    }
    free(list);
    Method *methods = class_copyMethodList(cls, &count);
    for (unsigned i = 0; i < count; i++) {
        NSString *name = NSStringFromSelector(method_getName(methods[i]));
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"lock"] || [lower containsString:@"audio"] ||
            [lower containsString:@"video"] || [lower containsString:@"duck"] ||
            [lower containsString:@"background"]) [selectors addObject:name];
    }
    free(methods);
    return [NSString stringWithFormat:@"%@ properties=%@ captureSelectors=%@", NSStringFromClass(cls),
            [properties componentsJoinedByString:@","], [selectors componentsJoinedByString:@","]];
}
