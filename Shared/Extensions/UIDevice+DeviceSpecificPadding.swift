import SwiftUI


extension UIDevice {
    
    var deviceSpecificPadding: CGFloat {
        UIScreen.main.bounds.width < 380 || userInterfaceIdiom == .pad ? 4 : 0
    }
    
}
