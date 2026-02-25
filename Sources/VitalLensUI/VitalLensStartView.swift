import SwiftUI
import VitalLensInference
import VitalLensCore

#if canImport(UIKit)

// MARK: - FFI Metadata Cache
public struct VitalMetadataCache {
    nonisolated(unsafe) private static var cache: [String: VitalDisplayMeta] = [:]
    nonisolated(unsafe) private static var queriedKeys: Set<String> = []
    private static let lock = NSLock()
    
    public static func getMeta(for id: String) -> VitalDisplayMeta? {
        lock.lock()
        defer { lock.unlock() }
        
        if queriedKeys.contains(id) { return cache[id] }
        
        if let meta = VitalLensCore.getVitalInfo(vitalId: id) {
            cache[id] = meta
        }
        queriedKeys.insert(id)
        
        return cache[id]
    }
    
    /// Dynamically fetches the brand accent color based on Respiratory Rate, falling back to default blue.
    public static var brandBlue: Color {
        if let meta = getMeta(for: "respiratory_rate"), let c = Color(hex: meta.color) {
            return c
        }
        return Color(red: 0/255, green: 163/255, blue: 252/255)
    }
}

// MARK: - Color Hex Extension
public extension Color {
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")
        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }
        self.init(
            red: Double((rgb & 0xFF0000) >> 16) / 255.0,
            green: Double((rgb & 0x00FF00) >> 8) / 255.0,
            blue: Double(rgb & 0x0000FF) / 255.0
        )
    }
}

// MARK: - DRY Reusable Start View
public struct VitalLensStartView: View {
    public let title: String
    public let subtitle: String
    public let timingHintLabel: String
    public let startButtonLabel: String
    @Binding public var currentMode: VitalLensMode
    public let onStart: () -> Void
    
    public init(
        title: String,
        subtitle: String,
        timingHintLabel: String,
        startButtonLabel: String,
        currentMode: Binding<VitalLensMode>,
        onStart: @escaping () -> Void
    ) {
        self.title = title
        self.subtitle = subtitle
        self.timingHintLabel = timingHintLabel
        self.startButtonLabel = startButtonLabel
        self._currentMode = currentMode
        self.onStart = onStart
    }
    
    public var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.07, blue: 0.09)
                .edgesIgnoringSafeArea(.all)
            
            VStack(spacing: 24) {
                HStack(spacing: 12) {
                    Image("vitallens_logo", bundle: .module)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 32, height: 32)
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.white)
                    
                    Spacer()
                }
                .padding(.top, 8)
                
                Spacer()
                
                Text(subtitle)
                    .font(.title3)
                    .fontWeight(.bold)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                
                VStack(spacing: 0) {
                    HStack(spacing: 0) {
                        GuideItem(icon: "person.crop.circle.fill", text: "Center your face\nin the oval.")
                        GuideItem(icon: "pause.circle.fill", text: "Hold yourself and\ncamera still.")
                    }
                    HStack(spacing: 0) {
                        GuideItem(icon: "sun.max.fill", text: "Ensure bright,\nsteady lighting.")
                        GuideItem(icon: "clock.fill", text: timingHintLabel)
                    }
                }
                .padding(.vertical, 16)
                .background(Color(white: 0.12))
                .cornerRadius(20)
                
                Button(action: onStart) {
                    Text(startButtonLabel)
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 18)
                        .background(VitalMetadataCache.brandBlue)
                        .cornerRadius(16)
                }
                
                Button(action: {
                    currentMode = currentMode == .eco ? .standard : .eco
                }) {
                    HStack(spacing: 16) {
                        HStack(spacing: 0) {
                            ZStack {
                                Circle().fill(currentMode == .eco ? VitalMetadataCache.brandBlue : Color.clear)
                                Image(systemName: "leaf.fill")
                                    .foregroundColor(currentMode == .eco ? .white : .gray)
                                    .font(.system(size: 14))
                            }
                            .frame(width: 36, height: 36)
                            
                            ZStack {
                                Circle().fill(currentMode == .standard ? VitalMetadataCache.brandBlue : Color.clear)
                                Image(systemName: "bolt.fill")
                                    .foregroundColor(currentMode == .standard ? .white : .gray)
                                    .font(.system(size: 14))
                            }
                            .frame(width: 36, height: 36)
                        }
                        .background(Color.black.opacity(0.4))
                        .cornerRadius(18)
                        
                        VStack(alignment: .leading, spacing: 4) {
                            Text(currentMode == .eco ? "Eco Mode" : "Standard Mode")
                                .font(.subheadline)
                                .bold()
                                .foregroundColor(.white)
                            
                            Text(currentMode == .eco ? "Standard accuracy, for slower connections and devices" : "High accuracy, for fast connections and devices")
                                .font(.caption2)
                                .foregroundColor(.gray)
                                .multilineTextAlignment(.leading)
                                .lineLimit(2)
                        }
                        Spacer()
                    }
                    .padding(14)
                    .background(Color(white: 0.12))
                    .cornerRadius(20)
                }
                .buttonStyle(PlainButtonStyle())
                
                Spacer()
            }
            .padding(.horizontal, 24)
        }
    }
}

// MARK: - Guide Item
public struct GuideItem: View {
    public let icon: String
    public let text: String
    
    public var body: some View {
        VStack(spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 24))
                .foregroundColor(VitalMetadataCache.brandBlue)
            Text(text)
                .font(.caption2)
                .multilineTextAlignment(.center)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 16)
    }
}

#endif
