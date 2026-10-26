import CoreHaptics

enum PlannedPatternBuilder {
    static func make(plan: TrackPlan, hapticLead: TimeInterval, supportLevel: Float) throws -> CHHapticPattern {
        let config = plan.settings
        var events: [CHHapticEvent] = []
        var curves: [CHHapticParameterCurve] = []
        // Every event is submitted in one pattern while the app is foreground.
        // No new players, looping, or intensity updates are needed in background.
        let endTime = plan.duration + hapticLead
        var audioTime = 0.0
        while audioTime < endTime {
            let duration = min(12, endTime - audioTime)
            events.append(CHHapticEvent(eventType: .audioContinuous, parameters: [
                CHHapticEventParameter(parameterID: .audioVolume, value: supportLevel),
                CHHapticEventParameter(parameterID: .audioPitch, value: -1)
            ], relativeTime: audioTime, duration: duration))
            audioTime += duration
        }
        if config.mode == "beats" {
            for point in plan.beats {
                events.append(CHHapticEvent(eventType: .hapticTransient, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity,
                                           value: Float(point.detection.level * config.intensity)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(config.sharpness))
                ], relativeTime: hapticLead + point.time))
            }
        } else {
            var position = 0.0
            while position < plan.duration {
                let duration = min(29, plan.duration - position)
                events.append(CHHapticEvent(eventType: .hapticContinuous, parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: Float(config.intensity)),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: Float(config.sharpness))
                ], relativeTime: hapticLead + position, duration: duration))
                position += duration
            }
            var index = 0
            while index < plan.points.count {
                let end = min(index + 14, plan.points.count - 1)
                let start = plan.points[index].time
                var points = (index...end).map { i in
                    CHHapticParameterCurve.ControlPoint(relativeTime: plan.points[i].time - start,
                                                        value: Float(plan.points[i].detection.level))
                }
                if end == plan.points.count - 1 {
                    points.append(CHHapticParameterCurve.ControlPoint(relativeTime: plan.duration - start,
                                                                     value: Float(plan.points[end].detection.level)))
                }
                curves.append(CHHapticParameterCurve(parameterID: .hapticIntensityControl,
                                                     controlPoints: points, relativeTime: hapticLead + start))
                if end == plan.points.count - 1 { break }
                index = end
            }
        }
        return try CHHapticPattern(events: events, parameterCurves: curves)
    }
}
