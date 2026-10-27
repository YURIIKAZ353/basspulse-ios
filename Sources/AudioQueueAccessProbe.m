#import "AudioQueueAccessProbe.h"
#import <AVFoundation/AVFoundation.h>
#import <dlfcn.h>
#import <mach/mach.h>
#import <string.h>

// Read this app's mapped memory only. No code, vtables, entitlements, task
// policies, or server memory are modified. Never call a private validator.
static uintptr_t BPRead(uintptr_t address, void *buffer, vm_size_t length) {
    // arm64e system vtables can contain signed pointers. Try the original
    // pointer first, then mapped canonical candidates; never dereference them.
    uintptr_t candidates[] = { address, address & 0x0000ffffffffffffULL, address & 0x0000007fffffffffULL };
    for (unsigned i = 0; i < 3; i++) {
        if (!candidates[i]) continue;
        vm_size_t size = 0;
        if (vm_read_overwrite(mach_task_self(), candidates[i], length, (vm_address_t)buffer, &size) == KERN_SUCCESS && size == length) return candidates[i];
    }
    return 0;
}
static uintptr_t BPWord(uintptr_t address) {
    uintptr_t value = 0;
    return BPRead(address, &value, sizeof(value)) ? value : 0;
}
static NSDictionary *BPLabel(uintptr_t address) {
    uint8_t byte = 0;
    uintptr_t normalized = BPRead(address, &byte, 1);
    Dl_info info = {0};
    if (!normalized || !dladdr((const void *)normalized, &info)) return @{};
    return @{ @"image": info.dli_fname ? [@(info.dli_fname) lastPathComponent] : @"",
              @"symbol": info.dli_sname ? @(info.dli_sname) : @"",
              @"offset": @(normalized - (uintptr_t)info.dli_saddr) };
}
static NSString *BPText(uintptr_t address) {
    char bytes[192] = {0};
    if (!BPRead(address, bytes, sizeof(bytes))) return nil;
    NSUInteger n = 0;
    while (n < sizeof(bytes) && bytes[n]) {
        if ((unsigned char)bytes[n] < 32 || (unsigned char)bytes[n] > 126) return nil;
        n++;
    }
    if (n < 4 || n >= sizeof(bytes)) return nil;
    return [[NSString alloc] initWithBytes:bytes length:n encoding:NSUTF8StringEncoding];
}
static NSDictionary *BPCode(uintptr_t pointer, unsigned requested) {
    uint8_t bytes[3072] = {0};
    unsigned length = MIN(requested, sizeof(bytes));
    uintptr_t address = BPRead(pointer, bytes, length);
    if (!address) return @{ @"readError": @YES, @"label": BPLabel(pointer) };
    NSMutableArray *branches = [NSMutableArray array], *references = [NSMutableArray array];
    for (unsigned i = 0; i + 4 <= length; i += 4) {
        uint32_t op = 0; memcpy(&op, bytes + i, 4);
        if ((op & 0x7c000000u) == 0x14000000u) {
            int64_t delta = ((int64_t)(op & 0x03ffffffu) << 38) >> 36;
            uintptr_t target = address + i + delta;
            [branches addObject:@{ @"at": @(i), @"target": @(target), @"label": BPLabel(target) }];
        }
        if (i + 8 <= length && (op & 0x9f000000u) == 0x90000000u) {
            uint32_t next = 0; memcpy(&next, bytes + i + 4, 4);
            if ((next & 0xffc00000u) != 0x91000000u || ((next >> 5) & 31) != (op & 31)) continue;
            int64_t imm = (((op >> 5) & 0x7ffff) << 2) | ((op >> 29) & 3);
            if (imm & (1 << 20)) imm -= (1 << 21);
            uintptr_t ref = ((address + i) & ~(uintptr_t)4095) + imm * 4096 + ((next >> 10) & 4095);
            NSString *value = BPText(ref);
            uintptr_t count = BPWord(ref + 24);
            if (!value && count > 3 && count < 190) value = BPText(BPWord(ref + 16));
            if (value) [references addObject:@{ @"at": @(i), @"text": value }];
        }
    }
    return @{ @"address": @(address), @"label": BPLabel(address),
              @"bytes": [[NSData dataWithBytes:bytes length:length] base64EncodedStringWithOptions:0],
              @"branches": branches, @"references": references };
}

NSString *BPDescribeAudioQueueAccess(void) {
    uintptr_t function = (uintptr_t)dlsym(RTLD_DEFAULT, "AudioQueueNewInput");
    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSMutableDictionary *result = [@{ @"os": NSProcessInfo.processInfo.operatingSystemVersionString,
        @"category": session.category, @"mode": session.mode,
        @"options": @(session.categoryOptions), @"recordPermission": @(session.recordPermission),
        @"wrapper": BPCode(function, 384) } mutableCopy];
    uint32_t words[80] = {0};
    uintptr_t address = BPRead(function, words, sizeof(words));
    uintptr_t registers[32] = {0};
    BOOL found = NO;
    for (unsigned i = 0; address && i < 80; i++) {
        uint32_t op = words[i]; unsigned rd = op & 31, rn = (op >> 5) & 31;
        if ((op & 0x9f000000u) == 0x90000000u) {
            int64_t imm = (((op >> 5) & 0x7ffff) << 2) | ((op >> 29) & 3);
            if (imm & (1 << 20)) imm -= (1 << 21);
            registers[rd] = ((address + i * 4) & ~(uintptr_t)4095) + imm * 4096;
        } else if ((op & 0xffc00000u) == 0x91000000u) {
            registers[rd] = registers[rn] ? registers[rn] + ((op >> 10) & 4095) : 0;
        } else if ((op & 0xffc00000u) == 0xf9400000u) {
            registers[rd] = registers[rn] ? BPWord(registers[rn] + ((op >> 10) & 4095) * 8) : 0;
            if (rd == 0 && registers[0]) {
                uintptr_t instance = registers[0], table = BPWord(instance), method = BPWord(table + 0x240);
                NSDictionary *label = BPLabel(method);
                // Device system libraries can omit private C++ symbol names.
                // Match the wrapper's API-global/vtable structure and image;
                // preserve labels and bytes for independent verification.
                if ([label[@"image"] containsString:@"AudioToolbox"]) {
                    result[@"newQueue"] = BPCode(method, 3072);
                    uintptr_t policy = BPWord(instance + 0x10), policyTable = BPWord(policy);
                    NSMutableArray *methods = [NSMutableArray array];
                    for (unsigned slot = 0; slot < 3; slot++) [methods addObject:BPLabel(BPWord(policyTable + slot * 8))];
                    result[@"policyMethods"] = methods;
                    result[@"validator"] = BPCode(BPWord(policyTable + 0x10), 3072);
                    found = YES; break;
                }
            }
        } else if ((op & 0xfc000000u) == 0x94000000u) {
            memset(registers, 0, 19 * sizeof(uintptr_t));
        }
    }
    result[@"resolvedValidator"] = @(found);
    NSData *json = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
    return json ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : @"probe JSON failed";
}
