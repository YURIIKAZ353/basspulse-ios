#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreHaptics/CoreHaptics.h>

NSDictionary *BPProbeMediaRoutes(void) {
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    @try {
        NSDictionary *pattern = @{@"Version": @1, @"Pattern": @[
            @{@"Event": @{@"Time": @0, @"EventType": @"HapticContinuous", @"EventDuration": @4,
                          @"EventParameters": @[@{@"ParameterID": @"HapticIntensity", @"ParameterValue": @0.5},
                                                @{@"ParameterID": @"HapticSharpness", @"ParameterValue": @0.1}]}},
            @{@"ParameterCurve": @{@"ParameterID": @"HapticIntensityControl", @"Time": @0,
                                    @"ParameterCurveControlPoints": @[@{@"Time": @0, @"ParameterValue": @0},
                                                                    @{@"Time": @2, @"ParameterValue": @1},
                                                                    @{@"Time": @4, @"ParameterValue": @0}]}}
        ]};
        NSError *error = nil;
        CHHapticPattern *validated = [[CHHapticPattern alloc] initWithDictionary:pattern error:&error];
        result[@"coreHapticPatternValid"] = @(validated != nil && error == nil);
        if (error) result[@"patternError"] = error.description;
        NSURL *url = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"BassPulse-media-route.ahap"]];
        [[NSJSONSerialization dataWithJSONObject:pattern options:0 error:&error] writeToURL:url atomically:YES];
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:url options:nil];
        dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
        [asset loadValuesAsynchronouslyForKeys:@[@"playable", @"tracks", @"duration"] completionHandler:^{
            dispatch_semaphore_signal(semaphore);
        }];
        BOOL timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, 20 * NSEC_PER_SEC)) != 0;
        result[@"loadTimedOut"] = @(timedOut);
        if (!timedOut) {
            NSError *assetError = nil;
            result[@"playableLoadStatus"] = @([asset statusOfValueForKey:@"playable" error:&assetError]);
            result[@"playable"] = @(asset.playable);
            result[@"durationSeconds"] = @(CMTIME_IS_NUMERIC(asset.duration) ? CMTimeGetSeconds(asset.duration) : -1);
            NSMutableArray *tracks = [NSMutableArray array];
            for (AVAssetTrack *track in asset.tracks) [tracks addObject:track.mediaType];
            result[@"trackTypes"] = tracks;
            if (assetError) result[@"assetError"] = assetError.description;
        }
        NSURL *outputURL = [NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"BassPulse-haptic-writer.mov"]];
        [NSFileManager.defaultManager removeItemAtURL:outputURL error:nil];
        AVAssetWriter *writer = [[AVAssetWriter alloc] initWithURL:outputURL fileType:AVFileTypeQuickTimeMovie error:&error];
        result[@"writerAvailableMediaTypes"] = writer.availableMediaTypes ?: @[];
        result[@"writerCanApplyHapticPassthrough"] = @([writer canApplyOutputSettings:nil forMediaType:AVMediaTypeHaptic]);
        result[@"note"] = @"Asset recognition only. No motor playback or background success is tested.";
    } @catch (NSException *exception) {
        result[@"exception"] = [NSString stringWithFormat:@"%@ %@", exception.name, exception.reason ?: @""];
    }
    return result;
}
