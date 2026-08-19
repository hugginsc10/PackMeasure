import SwiftUI

struct RootPlaceholderView: View {
    var body: some View {
        ContentUnavailableView(
            "PackMeasure",
            systemImage: "shippingbox",
            description: Text("Scanner setup is in progress.")
        )
    }
}

#Preview {
    RootPlaceholderView()
}
