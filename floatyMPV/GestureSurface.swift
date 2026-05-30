import SwiftUI

struct GestureSurface: NSViewRepresentable {
    @Binding var isPickedUp: Bool

    func makeNSView(context: Context) -> GestureTrackingView {
        let view = GestureTrackingView()
        view.onPickedUpChanged = { pickedUp in
            DispatchQueue.main.async {
                isPickedUp = pickedUp
            }
        }
        return view
    }

    func updateNSView(_ nsView: GestureTrackingView, context: Context) {
        nsView.onPickedUpChanged = { pickedUp in
            DispatchQueue.main.async {
                isPickedUp = pickedUp
            }
        }
    }
}
