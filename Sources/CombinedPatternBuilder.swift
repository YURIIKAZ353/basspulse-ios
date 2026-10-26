import CoreHaptics

enum CombinedPatternBuilder {
    static func make(chunk: PreparedAudioChunk, resource: CHHapticAudioResourceID) throws -> CHHapticPattern {
        let settings = chunk.settings
        // Audio and haptics use the same engine clock. Signed manual adjustment
        // delays either side without introducing a separate test tone.
        let audioLead = max(0, -settings.delayMS / 1000)
        let hapticLead = max(0, settings.delayMS / 1000)
        var events = [CHHapticEvent(audioResourceID: resource, parameters: [
            CHHapticEventParameter(parameterID: .audioVolume, value: 1)
        ], relativeTime: audioLead, duration: chunk.duration)]
        var curves: [CHHapticParameterCurve] = []
        if settings.hapticsEnabled && settings.intensity > 0 {
            if settings.mode == "beats" {
                for point in chunk.points where point.detection.beat {
                    events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity,
                                               value: Float(point.detection.level * settings.intensity)),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(settings.sharpness))
                    ], relativeTime: hapticLead + point.time))
                }
            } else {
                events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(settings.intensity)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(settings.sharpness))
                ], relativeTime: hapticLead, duration: chunk.duration))
                // Small, joined curves retain ~23 ms envelope detail without
                // relying on a large number of points in one parameter curve.
                var index = 0
                while index < chunk.points.count {
                    let end = min(index + 14, chunk.points.count - 1)
                    let start = chunk.points[index].time
                    var points = (index...end).map { i in
                        CHHapticParameterCurve.ControlPoint(relativeTime: chunk.points[i].time - start,
                                                            value: Float(chunk.points[i].detection.level))
                    }
                    if end == chunk.points.count - 1 {
                        points.append(CHHapticParameterCurve.ControlPoint(relativeTime: chunk.duration - start,
                                                                         value: Float(chunk.points[end].detection.level)))
                    }
                    curves.append(CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                                                         controlPoints: points, relativeTime: hapticLead + start))
                    if end == chunk.points.count - 1 { break }
                    index = end
                }
            }
        }
        return try CHHapticPattern(events: events, parameterCurves: curves)
    }
}
