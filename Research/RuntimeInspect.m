#import <Foundation/Foundation.h>
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <unistd.h>
#import <stdatomic.h>
extern NSDictionary *BPProbeMediaRoutes(void);
static uintptr_t readPointer(uintptr_t address);

static NSString *readText(uintptr_t address) {
    char buffer[192] = {0};
    vm_size_t size = 0;
    if (vm_read_overwrite(mach_task_self(), address, sizeof(buffer), (vm_address_t)buffer, &size) != KERN_SUCCESS) return nil;
    NSUInteger n = 0;
    while (n < size && buffer[n]) {
        if ((unsigned char)buffer[n] < 32 || (unsigned char)buffer[n] > 126) return nil;
        n++;
    }
    if (n < 4 || n >= size) return nil;
    return [[NSString alloc] initWithBytes:buffer length:n encoding:NSUTF8StringEncoding];
}

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
    NSMutableArray *references = [NSMutableArray array];
    for (NSUInteger offset = 0; offset + 4 <= readSize; offset += 4) {
        uint32_t instruction = 0;
        memcpy(&instruction, bytes + offset, sizeof(instruction));
        if (offset + 8 <= readSize && (instruction & 0x9f000000u) == 0x90000000u) {
            uint32_t next = 0;
            memcpy(&next, bytes + offset + 4, sizeof(next));
            if ((next & 0xffc00000u) == 0x91000000u && ((next >> 5) & 31) == (instruction & 31)) {
                int64_t immediate = (((instruction >> 5) & 0x7ffff) << 2) | ((instruction >> 29) & 3);
                if (immediate & (1 << 20)) immediate -= (1 << 21);
                uintptr_t ref = (((uintptr_t)address + offset) & ~(uintptr_t)4095) + immediate * 4096 + ((next >> 10) & 4095);
                NSString *value = readText(ref);
                if (!value && readPointer(ref + 24) > 3 && readPointer(ref + 24) < 190) value = readText(readPointer(ref + 16));
                if (value) [references addObject:@{ @"at": @(offset), @"text": value }];
            }
        }
        if ((instruction & 0x7c000000u) == 0x14000000u) {
            int64_t delta = ((int64_t)(instruction & 0x03ffffffu) << 38) >> 36;
            const void *target = (const void *)((uintptr_t)address + offset + delta);
            [branches addObject:@{ @"at": @(offset), @"target": @((uintptr_t)target), @"label": label(target) }];
        }
    }
    return @{ @"address": @((uintptr_t)address), @"label": label(address),
              @"bytes": [[NSData dataWithBytes:bytes length:readSize] base64EncodedStringWithOptions:0],
              @"branches": branches, @"references": references };
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
    // Simulator audio IPC can stall in a CLI. Initialize on a worker and bound
    // the wait; the API singleton is published before queue/server creation.
    __block _Atomic(OSStatus) status = INT32_MIN;
    dispatch_semaphore_t completed = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        AudioStreamBasicDescription localFormat = format;
        AudioQueueRef queue = NULL;
        status = AudioQueueNewOutput(&localFormat, unusedOutput, NULL, NULL, NULL, 0, &queue);
        if (queue) AudioQueueDispose(queue, true);
        dispatch_semaphore_signal(completed);
    });
    dispatch_semaphore_wait(completed, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
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
            // NewQueue's first virtual call is the access validator stored at
            // V2Impl+0x10, vtable+0x10. Resolve and inspect; never invoke it.
            uintptr_t validator = readPointer(instance + 0x10);
            uintptr_t validatorTable = readPointer(validator);
            NSMutableArray *validationMethods = [NSMutableArray array];
            for (unsigned slot = 0; slot < 12; slot++) {
                uintptr_t method = readPointer(validatorTable + slot * sizeof(uintptr_t));
                if (method) {
                    NSString *key = [NSString stringWithFormat:@"AQ_virtual_validator_%u", slot];
                    functions[key] = dumpCode((const void *)method);
                    [validationMethods addObject:@{ @"slot": @(slot), @"label": label((const void *)method) }];
                }
            }
            return @{ @"idleOutputStatus": @(status), @"implementation": label((const void *)implementation), @"validationMethods": validationMethods };
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
        fflush(stdout);
        // Do not run global AudioQueue teardown against an IPC-stalled worker.
        _exit(0);
    }
    return 0;
}
