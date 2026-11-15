import Foundation
import CoreLocation

/// O iOS congela apps em segundo plano. Enquanto a moto está conectada, o Tron Racing pede a
/// localização continuamente (modo de navegação), e assim continua rodando com o Waze na frente.
/// Aparece a pílula azul de localização no topo da tela: é ela que mantém o app vivo.
final class KeepAlive: NSObject, CLLocationManagerDelegate {
    static let shared = KeepAlive()
    private let manager = CLLocationManager()
    private var active = false

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
        manager.distanceFilter = kCLDistanceFilterNone
        manager.pausesLocationUpdatesAutomatically = false
        manager.activityType = .automotiveNavigation
    }

    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    func start() {
        DispatchQueue.main.async {
            self.active = true
            self.requestPermission()
            self.manager.allowsBackgroundLocationUpdates = true
            self.manager.showsBackgroundLocationIndicator = true
            self.manager.startUpdatingLocation()
            Log.d("mantendo o app ativo em segundo plano (localização)")
        }
    }

    func stop() {
        DispatchQueue.main.async {
            self.active = false
            self.manager.stopUpdatingLocation()
            self.manager.allowsBackgroundLocationUpdates = false
        }
    }

    func locationManagerDidChangeAuthorization(_ m: CLLocationManager) {
        Log.d("permissão de localização: \(m.authorizationStatus.rawValue)")
        if active { m.startUpdatingLocation() }
    }

    func locationManager(_ m: CLLocationManager, didUpdateLocations locations: [CLLocation]) {}

    func locationManager(_ m: CLLocationManager, didFailWithError error: Error) {
        Log.d("localização: \(error.localizedDescription)")
    }
}
