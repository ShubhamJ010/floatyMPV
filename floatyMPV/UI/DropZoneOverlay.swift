import SwiftUI

struct DropZoneOverlay: View {
    let isTargeted: Bool

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "square.and.arrow.down.fill")
                .font(.system(size: 32, weight: .medium))
                .foregroundStyle(isTargeted ? .primary : .secondary)
                .scaleEffect(isTargeted ? 1.1 : 0.9)
            
            Text(isTargeted ? "Drop to Play Video" : "Drop Video Here")
                .font(.system(size: 14, weight: .semibold, design: .rounded))
                .foregroundStyle(isTargeted ? .primary : .secondary)
        }
        .opacity(isTargeted ? 1.0 : 0.4)
        .blur(radius: isTargeted ? 0 : 0.5)
    }
}
