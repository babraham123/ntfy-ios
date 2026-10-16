import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var delegate: AppDelegate

    var body: some View {
        MainView()
            .alert(item: $delegate.deepLinkAlert) { alert in
                Alert(title: Text(alert.title), message: Text(alert.message))
            }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(AppDelegate())
    }
}
