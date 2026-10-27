#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
extern NSDictionary *BPProbeMediaRoutes(void);

static NSDictionary *label(const void *address) {
    Dl_info info = {0};
    if (!dladdr(address, &info)) return @{};
    return @{ @"image": info.dli_fname ? @(info.dli_fname) : @"",
              @"symbol": info.dli_sname ? @(info.dli_sname) : @"",
              @"offset": @((uintptr_t)address - (uintptr_t)info.dli_saddr) };
}

static NSDictionary *dumpCode(const void *address) {
    if (!address) return @{};
    uint8_t bytes[2048] = {0};
    vm_size_t readSize = 0;
    kern_return_t status = vm_read_overwrite(mach_task_self(), (vm_address_t)address,
                                            sizeof(bytes), (vm_address_t)bytes, &readSize);
    if (status != KERN_SUCCESS) return @{ @"readError": @(status) };
    NSMutableArray *branches = [NSMutableArray array];
    for (NSUInteger offset = 0; offset + 4 <= readSize; offset += 4) {
        uint32_t instruction = 0;
        memcpy(&instruction, bytes + offset, sizeof(instruction));
        if ((instruction & 0x7c000000u) == 0x14000000u) {
            int64_t delta = ((int64_t)(instruction & 0x03ffffffu) << 38) >> 36;
            const void *target = (const void *)((uintptr_t)address + offset + delta);
            [branches addObject:@{ @"at": @(offset), @"target": @((uintptr_t)target), @"label": label(target) }];
        }
    }
    return @{ @"address": @((uintptr_t)address), @"label": label(address),
              @"bytes": [[NSData dataWithBytes:bytes length:readSize] base64EncodedStringWithOptions:0],
              @"branches": branches };
}

static uintptr_t readPointer(uintptr_t address) {
    uintptr_t value = 0;
    vm_size_t size = 0;
    if (vm_read_overwrite(mach_task_self(), address, sizeof(value), (vm_address_t)&value, &size) != KERN_SUCCESS || size != sizeof(value)) return 0;
    return value;
}

static void unusedOutput(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer) {}

static NSDictionary *inspectQueueImplementation(NSMutableDictionary *functions) {
    // Cloud simulator only: initialize the API through an idle output queue.
    // No buffers are supplied, AudioQueueStart is never called, then dispose.
    AudioStreamBasicDescription format = {0};
    format.mSampleRate = 48000;
    format.mFormatID = kAudioFormatLinearPCM;
    format.mFormatFlags = kAudioFormatFlagsNativeFloatPacked;
    format.mBytesPerPacket = format.mBytesPerFrame = 4;
    format.mFramesPerPacket = 1;
    format.mChannelsPerFrame = 1;
    format.mBitsPerChannel = 32;
    AudioQueueRef queue = NULL;
    OSStatus status = AudioQueueNewOutput(&format, unusedOutput, NULL, NULL, NULL, 0, &queue);
    if (queue) AudioQueueDispose(queue, true);
    uintptr_t address = (uintptr_t)dlsym(RTLD_DEFAULT, "AudioQueueNewInput");
    if (!address) return @{ @"idleOutputStatus": @(status), @"error": @"no input wrapper" };
    uint32_t words[48] = {0};
    vm_size_t size = 0;
    if (vm_read_overwrite(mach_task_self(), address, sizeof(words), (vm_address_t)words, &size) != KERN_SUCCESS) return @{ @"idleOutputStatus": @(status), @"error": @"read failed" };
    for (unsigned i = 0; i + 1 < size / 4; i++) {
        uint32_t adrp = words[i], load = words[i + 1];
        // ARM64 ADRP Xn; LDR X0,[Xn,#offset] in the inspected SDK27 wrapper.
        if ((adrp & 0x9f000000u) != 0x90000000u || (load & 0xffc0001fu) != 0xf9400000u || ((load >> 5) & 31) != (adrp & 31)) continue;
        int64_t immediate = (((adrp >> 5) & 0x7ffff) << 2) | ((adrp >> 29) & 3);
        if (immediate & (1 << 20)) immediate -= (1 << 21);
        uintptr_t global = ((address + i * 4) & ~(uintptr_t)4095) + immediate * 4096 + ((load >> 10) & 4095) * 8;
        uintptr_t instance = readPointer(global), table = readPointer(instance);
        uintptr_t implementation = readPointer(table + 0x240);
        if (implementation) {
            functions[@"AQ_virtual_newQueue"] = dumpCode((const void *)implementation);
            return @{ @"idleOutputStatus": @(status), @"implementation": label((const void *)implementation) };
        }
    }
    return @{ @"idleOutputStatus": @(status), @"error": @"wrapper global/vtable not resolved" };
}

int main(int argc, char **argv) {
    @autoreleasepool {
        dlopen("/System/Library/Frameworks/CoreHaptics.framework/CoreHaptics", RTLD_NOW);
        dlopen("/System/Library/Frameworks/AudioToolbox.framework/AudioToolbox", RTLD_NOW);
        dlopen("/System/Library/Frameworks/ScreenCaptureKit.framework/ScreenCaptureKit", RTLD_NOW);
        dlopen("/System/Library/Frameworks/ReplayKit.framework/ReplayKit", RTLD_NOW);
        NSMutableDictionary *result = [NSMutableDictionary dictionary];
        result[@"os"] = NSProcessInfo.processInfo.operatingSystemVersionString;
        result[@"device"] = NSProcessInfo.processInfo.environment[@"SIMULATOR_MODEL_IDENTIFIER"] ?: @"host";
        NSMutableDictionary *classes = [NSMutableDictionary dictionary];
        NSArray *classNames = @[@"CHHapticEngine", @"AVHapticPlayer", @"AVHapticClient", @"PatternPlayer",
                                @"AdvancedPatternPlayer", @"PatternPlayerBase", @"AVHapticPlayerChannel", @"HapticServerConfig",
                                @"SCStream", @"SCStreamConfiguration", @"SCContentFilter", @"SCContentSharingPickerConfiguration",
                                @"RPDaemonProxy", @"RPScreenRecorder", @"RPAppAudioCaptureManager"];
        for (NSString *className in classNames) {
            Class cls = NSClassFromString(className);
            if (!cls) { classes[className] = @{ @"present": @NO }; continue; }
            NSMutableDictionary *methods = [NSMutableDictionary dictionary];
            NSMutableArray *names = [NSMutableArray array];
            unsigned count = 0;
            Method *list = class_copyMethodList(cls, &count);
            for (unsigned i = 0; i < count; ++i) {
                NSString *selector = NSStringFromSelector(method_getName(list[i]));
                [names addObject:selector];
                NSString *lower = selector.lowercaseString;
                BOOL inspect = [lower containsString:@"behavior"] || [lower containsString:@"privileg"]
                    || [lower containsString:@"options"] || [lower containsString:@"priority"]
                    || [lower containsString:@"vibepattern"] || [lower containsString:@"ringtone"]
                    || [lower containsString:@"mute"] || [lower containsString:@"capabil"]
                    || [lower containsString:@"background"] || [lower containsString:@"serverconfig"]
                    || [lower containsString:@"lock"] || [lower containsString:@"duck"]
                    || ([className hasPrefix:@"SC"] && ([lower containsString:@"audio"] || [lower containsString:@"video"] || [lower containsString:@"capture"]));
                if (inspect) {
                    methods[selector] = @{ @"encoding": @(method_getTypeEncoding(list[i])),
                                          @"code": dumpCode((const void *)method_getImplementation(list[i])) };
                }
            }
            free(list);
            classes[className] = @{ @"present": @YES, @"methods": methods, @"selectors": names };
        }
        result[@"classes"] = classes;
        NSMutableDictionary *functions = [NSMutableDictionary dictionary];
        for (NSString *name in @[@"AudioServicesPlaySystemSoundWithVibration", @"AudioServicesPlaySystemSoundWithVibrationAndFlags",
                                @"AudioServicesStartSystemSoundWithVibration", @"AudioServicesPlaySystemSoundWithOptions",
                                @"HapticServerManager_VibeEnginePlay", @"HapticServerManager_VibeEngineInitialize",
                                @"AudioQueueNewInput", @"AudioQueueNewInputWithAudioSession", @"AudioQueueNewInputWithDispatchQueue"]) {
            void *address = dlsym(RTLD_DEFAULT, name.UTF8String);
            functions[name] = address ? dumpCode(address) : @{ @"present": @NO };
        }
        result[@"aqInterfaceProbe"] = inspectQueueImplementation(functions);
        for (unsigned depth = 0; depth < 3 && functions.count < 40; depth++) {
            NSDictionary *snapshot = [functions copy];
            for (NSString *name in snapshot) {
                if (![name hasPrefix:@"AudioQueue"] && ![name hasPrefix:@"AQ_virtual"] && ![name hasPrefix:@"_ZN2AQ"] && ![name containsString:@"ClientQueue"] && ![name containsString:@"ermission"]) continue;
                for (NSDictionary *branch in snapshot[name][@"branches"]) {
                    NSDictionary *targetLabel = branch[@"label"];
                    NSString *symbol = targetLabel[@"symbol"] ?: @"";
                    NSString *lower = symbol.lowercaseString;
                    if (functions[symbol] || functions.count >= 40 || [targetLabel[@"offset"] longLongValue] != 0) continue;
                    if ([symbol hasPrefix:@"_ZN2AQ"] || [symbol hasPrefix:@"AudioQueue"] || [lower containsString:@"clientqueue"] || [lower containsString:@"permission"] || [lower containsString:@"entitlement"]) {
                        functions[symbol] = dumpCode((const void *)[branch[@"target"] unsignedLongLongValue]);
                    }
                }
            }
        }
        result[@"functions"] = functions;
        NSMutableDictionary *constants = [NSMutableDictionary dictionary];
        for (NSString *name in @[@"CHHapticEngineOptionKeyUsageCategory", @"CHHapticEngineOptionKeyPriority",
                                @"CHHapticUsageCategorySystemSound", @"CHHapticUsageCategorySystemSoundHapticsParser",
                                @"CHHapticUsageCategoryDefault", @"CHHapticPriorityLow", @"CHHapticPriorityHigh",
                                @"CHHapticPriorityHighest", @"CHHapticPriorityExclusive"]) {
            void *address = dlsym(RTLD_DEFAULT, name.UTF8String);
            if (address) {
                NSString *value = *(NSString * __unsafe_unretained *)address;
                constants[name] = [value isKindOfClass:NSString.class] ? value : @"not a string";
            }
        }
        result[@"constants"] = constants;
        Class configClass = NSClassFromString(@"SCStreamConfiguration");
        if (configClass) {
            id config = [configClass new];
            NSMutableDictionary *defaults = [NSMutableDictionary dictionary];
            unsigned propertyCount = 0;
            objc_property_t *properties = class_copyPropertyList(configClass, &propertyCount);
            for (unsigned i = 0; i < propertyCount; i++) {
                NSString *key = @(property_getName(properties[i]));
                NSString *lower = key.lowercaseString;
                if ([lower containsString:@"audio"] || [lower containsString:@"video"] || [lower containsString:@"capture"] || [lower containsString:@"lock"] || [lower containsString:@"duck"]) {
                    @try { defaults[key] = [[config valueForKey:key] description] ?: @"nil"; }
                    @catch (NSException *exception) { defaults[key] = exception.name; }
                }
            }
            free(properties);
            result[@"captureConfigurationDefaults"] = defaults;
        }
        result[@"mediaRoutes"] = BPProbeMediaRoutes();
        NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        printf("BPRESEARCH:%s\n", [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding].UTF8String);
    }
    return 0;
}
