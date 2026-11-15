import SwiftUI
import WidgetKit

/// Build 175: widget-extensie van Bingr op de Mac: de widget "Bingr Radio" (klein en middel), met de zender die nu speelt
/// en de favoriete zenders als knoppen. Zelfde code als op iPhone en iPad (BingrWidgets/RadioWidgets.swift); de app zet
/// de zenderlijst (alleen wat het actieve profiel mag, ook een kinderprofiel) in de App Group (RadioBridge174).
@main
struct BingrMacWidgets: WidgetBundle {
    var body: some Widget {
        RadioWidget()
    }
}
