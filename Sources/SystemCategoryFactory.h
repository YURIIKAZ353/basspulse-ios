#import <Foundation/Foundation.h>
#import <AVFAudio/AVFAudio.h>
#import <CoreHaptics/CoreHaptics.h>

NS_ASSUME_NONNULL_BEGIN
@interface BPSystemCategoryResult : NSObject
@property(nonatomic, strong, nullable) CHHapticEngine *engine;
@property(nonatomic, copy) NSString *detail;
@end

FOUNDATION_EXPORT BPSystemCategoryResult *BPCreateSystemCategoryEngine(AVAudioSession *session);
FOUNDATION_EXPORT BPSystemCategoryResult *BPRequestBackgroundHaptics(CHHapticEngine *engine);
NS_ASSUME_NONNULL_END
