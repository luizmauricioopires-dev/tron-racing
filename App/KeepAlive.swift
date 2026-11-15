import Foundation
import CoreLocation

/// GPS do app. Enquanto a moto está conectada ou há navegação, pede a localização continuamente:
/// além de alimentar o mapa, é isso que mantém o Tron Racing rodando com o iPhone bloqueado
/// (aparece a pílula azul de localização no topo).
final class KeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = KeepAlive()
    private let manager = CLLocationManager()
    private var reasons = Set<String>()

    /// Chamado na fila principal a cada nova posição.
    var onLocation: ((CLLocation) -> Void)?
    private(set) var last: CLLocation?

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBestForNavigation
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// `reason`: "moto", "nav", "tela"... O GPS fica ligado enquanto houver algum motivo.
    func start(_ reason: String = "moto") {
        DispatchQueue.main.async {
            let wasEmpty = self.reasons.isEmpty
            self.reasons.insert(reason)
            guard wasEmpty else { return }
            self.requestPermission()
            if reason != "tela" {
                self.manager.allowsBackgroundLocationUpdates = true
                self.manager.showsBackgroundLocationIndicator = true
            }
            self.manager.startUpdatingLocation()
            Log.d("GPS ligado (\(reason))")
        }
    }

    func stop(_ reason: String = "moto") {
        DispatchQueue.main.async {
            self.reasons.remove(reason)
            if self.reasons.isEmpty {
                self.manager.stopUpdatingLocation()
                self.manager.allowsBackgroundLocationUpdates = false
                Log.d("GPS desligado")
            } else if !self.reasons.contains("moto") && !self.reasons.contains("nav") {
                self.manager.allowsBackgroundLocationUpdates = false
            }
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Log.d("permissão de localização: \(m.authorizationStatus.rawValue)")
        if !reasons.isEmpty { m.startUpdatingLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let l = locations.last, l.horizontalAccuracy >= 0 else { return }
        last = l
        onLocation?(l)
    }

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Log.d("localização: \(error.localizedDescription)")
    }
}
