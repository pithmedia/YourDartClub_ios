import SwiftUI

// Shared visual tokens from resources/css/app.css and the official logo.
enum ClubStyle {
    static let background = Color(hex:0x0e1411)
    static let card = Color(hex:0x151d18)
    static let elevated = Color(hex:0x202c23)
    static let lime = Color(hex:0xbbf77a)
    static let text = Color(hex:0xf2f5ef)
    static let muted = Color(hex:0xa4afa5)
    static let border = Color(hex:0x2a372e)
    static let ink = Color(hex:0x172410)
}
extension Color {
    init(hex: UInt32) { self.init(.sRGB,red:Double((hex >> 16) & 255)/255,green:Double((hex >> 8) & 255)/255,blue:Double(hex & 255)/255,opacity:1) }
}
extension View {
    func clubCard(padding: CGFloat = 20) -> some View {
        self.padding(padding).background(ClubStyle.card,in:RoundedRectangle(cornerRadius:20))
            .overlay(RoundedRectangle(cornerRadius:20).stroke(ClubStyle.border,lineWidth:1))
    }
    func clubScreen() -> some View {
        self.scrollContentBackground(.hidden).background(ClubStyle.background)
            .toolbarBackground(ClubStyle.background,for:.navigationBar).toolbarBackground(.visible,for:.navigationBar)
    }
}
struct ClubButton: ButtonStyle {
    var primary = false
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth:.infinity,minHeight:48).padding(.horizontal,12)
            .foregroundStyle(primary ? ClubStyle.ink : ClubStyle.text)
            .background(primary ? ClubStyle.lime : ClubStyle.elevated,in:RoundedRectangle(cornerRadius:12))
            .opacity(!enabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}
struct ClubBackdrop: View {
    var body: some View {
        ZStack {
            ClubStyle.background
            RadialGradient(colors:[ClubStyle.lime.opacity(0.10),.clear],center:.topTrailing,startRadius:0,endRadius:500)
            GeometryReader { proxy in
                ZStack {
                    ForEach(0..<5) { index in Circle().stroke(ClubStyle.lime.opacity(0.06),lineWidth:1).frame(width:CGFloat(100 + index * 75),height:CGFloat(100 + index * 75)) }
                }.position(x:proxy.size.width * 0.92,y:90)
            }.clipped()
        }.accessibilityHidden(true)
    }
}
struct LogoIntro: View {
    let finished: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = false
    var body: some View {
        ZStack {
            ClubBackdrop().ignoresSafeArea()
            VStack(spacing:24) {
                ZStack {
                    Circle().trim(from:0,to:reveal ? 1 : 0).stroke(ClubStyle.lime.opacity(0.4),style:StrokeStyle(lineWidth:1,lineCap:.round)).frame(width:160,height:160).rotationEffect(.degrees(-90))
                    Image("Brand").resizable().scaledToFit().frame(width:112,height:112).clipShape(RoundedRectangle(cornerRadius:28))
                        .scaleEffect(reveal ? 1 : 0.8).shadow(color:ClubStyle.lime.opacity(0.16),radius:35)
                }
                Image("Wordmark").resizable().scaledToFit().frame(maxWidth:310).padding(.horizontal,32)
                    .opacity(reveal ? 1 : 0).offset(y:reveal ? 0 : 10)
                Text("intro_line").font(.caption.weight(.semibold)).tracking(3).foregroundStyle(ClubStyle.muted)
            }
        }
        .contentShape(Rectangle()).onTapGesture(perform:finished)
        .accessibilityElement(children:.ignore).accessibilityLabel("YourDartClub").accessibilityAction(named:Text("skip_intro"),finished)
        .task {
            if reduceMotion { finished(); return }
            withAnimation(.easeOut(duration:0.75)) { reveal = true }
            try? await Task.sleep(for:.milliseconds(1300))
            guard !Task.isCancelled else { return }; withAnimation(.easeOut(duration:0.25)) { finished() }
        }
    }
}
func textFormat(_ key: String, _ args: CVarArg...) -> String { String(format:tr(key),locale:Locale.current,arguments:args) }
