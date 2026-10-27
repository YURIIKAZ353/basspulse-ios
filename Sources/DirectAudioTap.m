#import "DirectAudioTap.h"
#import <AudioToolbox/AudioToolbox.h>
#import <objc/runtime.h>
#import <unistd.h>
#import <math.h>

// Guarded declarations of the tap descriptions used by Apple's audio service.
// No entitlements are added or modified. A server refusal is reported verbatim.
@interface NSObject (BPAudioTapSelectors)
- (instancetype)initSystemTapWithFormat:(AVAudioFormat *)format excludePIDs:(NSArray<NSNumber *> *)pids;
- (instancetype)initWithTapDescription:(id)description;
@end

@interface BPDirectAudioTap () {
    AudioQueueRef _queue;
    AVAudioFormat *_format;
    id _tap;
    unsigned long long _buffers;
}
- (void)consume:(AudioQueueBufferRef)buffer queue:(AudioQueueRef)queue;
@end

static void BPDirectInput(void *context, AudioQueueRef queue, AudioQueueBufferRef buffer,
                          const AudioTimeStamp *time, UInt32 packets,
                          const AudioStreamPacketDescription *descriptions) {
    [(__bridge BPDirectAudioTap *)context consume:buffer queue:queue];
}

@implementation BPDirectAudioTap
- (instancetype)init {
    if ((self = [super init])) {
        _onPCM = ^(AVAudioPCMBuffer *buffer, NSTimeInterval time) {};
        _onEvent = ^(NSString *event) {};
    }
    return self;
}

- (BOOL)fail:(NSString *)stage status:(OSStatus)status error:(NSError **)error {
    NSString *message = [NSString stringWithFormat:@"DirectTap %@: OSStatus=%d", stage, (int)status];
    self.onEvent(message);
    if (error) *error = [NSError errorWithDomain:@"BassPulse.DirectAudioTap" code:status
                                      userInfo:@{NSLocalizedDescriptionKey:message}];
    [self stop];
    return NO;
}

- (BOOL)startWithError:(NSError **)error {
    [self stop];
    Class descriptionClass = NSClassFromString(@"ATAudioTapDescription");
    Class tapClass = NSClassFromString(@"ATAudioTap");
    SEL initializer = @selector(initSystemTapWithFormat:excludePIDs:);
    if (!descriptionClass || !tapClass ||
        ![descriptionClass instancesRespondToSelector:initializer] ||
        ![tapClass instancesRespondToSelector:@selector(initWithTapDescription:)]) {
        return [self fail:@"runtime interface unavailable" status:-1 error:error];
    }
    _format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32 sampleRate:48000
                                               channels:2 interleaved:NO];
    AVAudioFormat *interleaved = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                                               sampleRate:48000 channels:2 interleaved:YES];
    @try {
        id description = [[descriptionClass alloc] initSystemTapWithFormat:interleaved excludePIDs:@[@(getpid())]];
        if (description) _tap = [[tapClass alloc] initWithTapDescription:description];
    } @catch (NSException *exception) {
        self.onEvent([NSString stringWithFormat:@"DirectTap exception: %@ %@", exception.name, exception.reason]);
        return [self fail:@"description initialization" status:-2 error:error];
    }
    if (!_tap) return [self fail:@"nil tap description" status:-3 error:error];
    AudioStreamBasicDescription asbd = *interleaved.streamDescription;
    // 0x800 is the process-tap queue flag used by replayd for app/system audio.
    // Never fall back to a microphone input queue if this request is refused.
    OSStatus status = AudioQueueNewInput(&asbd, BPDirectInput, (__bridge void *)self, NULL, NULL, 0x800, &_queue);
    self.onEvent([NSString stringWithFormat:@"DirectTap AudioQueueNewInput flags=0x800 status=%d", (int)status]);
    if (status != noErr) return [self fail:@"AudioQueueNewInput" status:status error:error];
    // 'qtob': the tap-object property used by replayd; value is the ObjC object,
    // not a pointer to a pointer. Audio service enforces its own access checks.
    status = AudioQueueSetProperty(_queue, 0x71746f62u, (__bridge const void *)_tap, (UInt32)sizeof(void *));
    self.onEvent([NSString stringWithFormat:@"DirectTap AudioQueueSetProperty qtob status=%d", (int)status]);
    if (status != noErr) return [self fail:@"AudioQueueSetProperty(qtob)" status:status error:error];
    UInt32 size = sizeof(asbd);
    status = AudioQueueGetProperty(_queue, kAudioQueueProperty_StreamDescription, &asbd, &size);
    if (status != noErr) return [self fail:@"stream format" status:status error:error];
    if (asbd.mFormatID != kAudioFormatLinearPCM || asbd.mChannelsPerFrame != 2 ||
        asbd.mBitsPerChannel != 32 || asbd.mBytesPerFrame != 8 ||
        !(asbd.mFormatFlags & kAudioFormatFlagIsFloat) ||
        (asbd.mFormatFlags & (kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsBigEndian))) {
        return [self fail:@"unsupported PCM format" status:-4 error:error];
    }
    _format = [[AVAudioFormat alloc] initWithCommonFormat:AVAudioPCMFormatFloat32
                                            sampleRate:asbd.mSampleRate channels:2 interleaved:NO];
    if (!_format) return [self fail:@"invalid PCM format" status:-5 error:error];
    _buffers = 0;
    for (unsigned i = 0; i < 4; i++) {
        AudioQueueBufferRef buffer = NULL;
        status = AudioQueueAllocateBuffer(_queue, 1024 * asbd.mBytesPerFrame, &buffer);
        if (status != noErr) return [self fail:@"allocate buffer" status:status error:error];
        status = AudioQueueEnqueueBuffer(_queue, buffer, 0, NULL);
        if (status != noErr) return [self fail:@"enqueue buffer" status:status error:error];
    }
    status = AudioQueueStart(_queue, NULL);
    self.onEvent([NSString stringWithFormat:@"DirectTap AudioQueueStart status=%d; success is not PCM confirmation", (int)status]);
    if (status != noErr) return [self fail:@"AudioQueueStart" status:status error:error];
    return YES;
}

- (void)consume:(AudioQueueBufferRef)buffer queue:(AudioQueueRef)queue {
    UInt32 frames = buffer->mAudioDataByteSize / 8;
    if (frames > 0 && frames <= 262144 && buffer->mAudioDataByteSize % 8 == 0) {
        AVAudioPCMBuffer *pcm = [[AVAudioPCMBuffer alloc] initWithPCMFormat:_format frameCapacity:frames];
        if (pcm.floatChannelData) {
            pcm.frameLength = frames;
            const float *source = buffer->mAudioData;
            float peak = 0;
            for (UInt32 i = 0; i < frames; i++) {
                pcm.floatChannelData[0][i] = source[i * 2];
                pcm.floatChannelData[1][i] = source[i * 2 + 1];
                peak = fmaxf(peak, fmaxf(fabsf(source[i * 2]), fabsf(source[i * 2 + 1])));
            }
            _buffers++;
            if (_buffers == 1 || _buffers % 100 == 0) {
                self.onEvent([NSString stringWithFormat:@"DirectTap PCM buffers=%llu peak=%f frames=%u", _buffers, peak, frames]);
            }
            self.onPCM(pcm, NSProcessInfo.processInfo.systemUptime);
        }
    }
    OSStatus status = AudioQueueEnqueueBuffer(queue, buffer, 0, NULL);
    if (status != noErr) self.onEvent([NSString stringWithFormat:@"DirectTap callback requeue status=%d", (int)status]);
}

- (void)stop {
    if (_queue) {
        // Synchronous disposal waits for the callback before releasing its owner.
        AudioQueueDispose(_queue, true);
        _queue = NULL;
    }
    _tap = nil;
}
- (void)dealloc { [self stop]; }
@end
