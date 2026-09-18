import SwiftUI

struct ScrollCurveEditor: View {
    @Binding var profile: MotionProfile
    var showGraph = true
    private var curve: ScrollResponse { profile.resolvedScrollResponse }

    var body: some View {
        VStack(alignment:.leading, spacing:10) {
            if showGraph {
                HStack {
                    Text("Scroll response").font(.system(size:12,weight:.semibold))
                    Spacer()
                    if profile.scrollResponse != nil {
                        Button { profile.scrollResponse = nil } label: { Image(systemName:"arrow.uturn.backward") }
                            .buttonStyle(.plain).help("Restore the previous speed and acceleration settings")
                            .accessibilityLabel("Restore previous scrolling")
                    }
                }
                Text("Scroll sensitivity ↑ · √ scale").font(.caption2).foregroundStyle(.secondary)
                graph.frame(height:132)
                HStack {
                    Text("Slow").foregroundStyle(.teal)
                    Spacer()
                    Text("Finger speed →").foregroundStyle(.secondary)
                    Spacer()
                    Text("Fast").foregroundStyle(.orange)
                }.font(.system(size:10,weight:.medium))
            }
            parameter("Slow speed", value:endpoint(fast:false))
            parameter("Fast speed", value:endpoint(fast:true))
            parameter("Transition point", value:Binding(get:{curve.transitionPercent},set:{percent in
                var edited = curve; edited.transitionPercent = percent
                profile.scrollResponse = edited.sanitized
            }))
            if showGraph {
                Text("Move the transition right to stay slow longer. Drag the dashed line or use the sliders. Equal Slow and Fast speeds give constant sensitivity.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
                if profile.scrollResponse == nil {
                    Text("Current scrolling is preserved until you edit a control.")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
        }
    }

    private var graph: some View {
        GeometryReader { proxy in
            let inset = 12.0
            let width = max(1,proxy.size.width - 2*inset)
            let height = max(1,proxy.size.height - 2*inset)
            let maximum = max(ScrollResponse.maximumMultiplier,profile.scrollGain(at:ScrollResponse.inputRange))
            let marker = inset + curve.transitionSpeed / ScrollResponse.inputRange * width
            ZStack {
                RoundedRectangle(cornerRadius:10).fill(Color.primary.opacity(0.035))
                Path { path in
                    for index in 0...4 {
                        let x = inset + Double(index)/4*width
                        let y = inset + Double(index)/4*height
                        path.move(to:CGPoint(x:x,y:inset)); path.addLine(to:CGPoint(x:x,y:inset+height))
                        path.move(to:CGPoint(x:inset,y:y)); path.addLine(to:CGPoint(x:inset+width,y:y))
                    }
                }.stroke(Color.secondary.opacity(0.08),lineWidth:1)
                Path { path in
                    path.move(to:CGPoint(x:marker,y:inset)); path.addLine(to:CGPoint(x:marker,y:inset+height))
                }.stroke(Color.secondary.opacity(0.5),style:StrokeStyle(lineWidth:1,dash:[3,4]))
                Path { path in
                    for index in 0...128 {
                        let fraction = Double(index)/128
                        let gain = profile.scrollGain(at:fraction * ScrollResponse.inputRange)
                        let point = CGPoint(x:inset+fraction*width,y:inset+(1-sqrt(min(1,max(0,gain/maximum))))*height)
                        if index == 0 { path.move(to:point) } else { path.addLine(to:point) }
                    }
                }.stroke(LinearGradient(colors:[.teal,.orange],startPoint:.leading,endPoint:.trailing),style:StrokeStyle(lineWidth:2.5,lineCap:.round))
                Circle().fill(Color.secondary).frame(width:5,height:5).position(x:marker,y:inset+height)
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance:0).onChanged { event in
                var edited = curve
                edited.transitionSpeed = min(ScrollResponse.maximumTransition,max(ScrollResponse.minimumTransition,(event.location.x-inset)/width*ScrollResponse.inputRange))
                profile.scrollResponse = edited.sanitized
            })
            .accessibilityElement(children:.ignore)
            .accessibilityLabel("Scroll response curve. Use the Slow speed, Fast speed, and Transition point controls below.")
        }
    }

    private func endpoint(fast: Bool) -> Binding<Double> {
        Binding(get:{ScrollResponse.percent(forMultiplier:fast ? curve.fastMultiplier : curve.slowMultiplier)},set:{percent in
            var edited = curve
            edited.setEndpoint(fast:fast,multiplier:ScrollResponse.multiplier(forPercent:percent))
            profile.scrollResponse = edited.sanitized
        })
    }

    private func parameter(_ title:String, value:Binding<Double>) -> some View {
        let bounded = Binding<Double>(get:{value.wrappedValue},set:{if $0.isFinite { value.wrappedValue = min(100,max(0,$0)) }})
        return HStack(spacing:8) {
            Text(title).font(.system(size:11)).frame(width:92,alignment:.leading)
            Slider(value:bounded,in:0...100).controlSize(.small).accessibilityLabel(title)
            TextField("",value:bounded,format:.number.precision(.fractionLength(1)))
                .textFieldStyle(.roundedBorder).multilineTextAlignment(.trailing)
                .font(.system(size:11)).monospacedDigit().frame(width:48)
                .accessibilityLabel("\(title) percent")
        }
    }
}
