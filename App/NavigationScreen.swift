import SwiftUI
import MapKit

/// Tela de navegação: buscar destino, ver a rota, iniciar e acompanhar. A mesma navegação aparece
/// no painel (mapa próprio) e continua com o iPhone bloqueado.
struct NavigationScreen: View {
    @EnvironmentObject var nav: NavEngine
    @Environment(\.dismiss) private var dismiss
    @StateObject private var search = SearchModel()
    @StateObject private var preview = PanelPreview()
    @FocusState private var searching: Bool

    var body: some View {
        ZStack(alignment: .top) {
            NavMap(route: nav.route, destination: nav.destination, following: nav.navigating)
                .ignoresSafeArea()

            VStack(spacing: 10) {
                HStack(spacing: 10) {
                    Button { dismiss() } label: {
                        Image(systemName: "chevron.down").font(.system(size: 17, weight: .bold)).foregroundColor(.white)
                            .frame(width: 46, height: 46).background(Circle().fill(UI.surface))
                    }
                    if !nav.navigating {
                        HStack {
                            Image(systemName: "magnifyingglass").foregroundColor(UI.dim)
                            TextField("Para onde?", text: $search.query)
                                .focused($searching)
                                .foregroundColor(.white)
                                .submitLabel(.search)
                            if !search.query.isEmpty {
                                Button { search.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundColor(UI.dim) }
                            }
                        }
                        .padding(.horizontal, 14).frame(height: 46)
                        .background(RoundedRectangle(cornerRadius: 23).fill(UI.surface))
                    } else {
                        Spacer()
                    }
                }
                if searching && !search.results.isEmpty {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(search.results, id: \.self) { r in
                                Button {
                                    searching = false
                                    search.pick(r) { item in if let item = item { nav.preview(to: item) } }
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(r.title).font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                                        if !r.subtitle.isEmpty { Text(r.subtitle).font(.system(size: 13)).foregroundColor(UI.dim) }
                                    }
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .padding(.horizontal, 16).padding(.vertical, 12)
                                }
                                Divider().background(Color.white.opacity(0.06))
                            }
                        }
                    }
                    .frame(maxHeight: 320)
                    .background(RoundedRectangle(cornerRadius: 18).fill(UI.surface))
                }
                if let img = preview.image, !searching {
                    HStack {
                        Spacer()
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("PAINEL").font(.system(size: 10, weight: .bold)).kerning(1).foregroundColor(UI.dim)
                            Image(decorative: img, scale: 1)
                                .resizable().aspectRatio(contentMode: .fit)
                                .frame(width: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.white.opacity(0.15)))
                        }
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)

            VStack { Spacer(); bottomCard }
        }
        .background(UI.bg)
        .onAppear { preview.start(); KeepAlive.shared.start("tela") }
        .onDisappear { preview.stop(); KeepAlive.shared.stop("tela") }
    }

    @ViewBuilder private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if nav.navigating {
                HStack(spacing: 16) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16).fill(UI.accent)
                        Image(systemName: nav.nextStep?.maneuver.symbol ?? "arrow.up")
                            .font(.system(size: 34, weight: .bold)).foregroundColor(.white)
                    }
                    .frame(width: 72, height: 72)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(Geo.formatDistance(nav.distanceToNext)).font(.system(size: 30, weight: .heavy)).foregroundColor(.white)
                        Text(nav.nextStep?.instruction ?? "Siga em frente").font(.system(size: 15)).foregroundColor(UI.dim).lineLimit(2)
                    }
                }
                if let r = nav.radarAlert {
                    Label("Radar em \(Geo.formatDistance(r.distance))\(r.radar.maxspeed.map { " · \($0) km/h" } ?? "")", systemImage: "camera.metering.spot")
                        .font(.system(size: 15, weight: .bold)).foregroundColor(.white)
                        .padding(.horizontal, 14).padding(.vertical, 8)
                        .background(Capsule().fill(UI.coral))
                }
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Chegada \(Geo.clock(Date().addingTimeInterval(nav.remainingTime)))")
                            .font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                        Text("\(Geo.formatDuration(nav.remainingTime)) · \(Geo.formatDistance(nav.remainingDistance))")
                            .font(.system(size: 14)).foregroundColor(UI.dim)
                    }
                    Spacer()
                    Button("Encerrar") { nav.stop() }
                        .font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                        .padding(.horizontal, 20).padding(.vertical, 12)
                        .background(Capsule().fill(UI.coral))
                }
            } else if let r = nav.route {
                Text(nav.destination?.name ?? "Destino").font(.system(size: 20, weight: .bold)).foregroundColor(.white).lineLimit(1)
                Text("\(Geo.formatDuration(r.expectedTravelTime)) · \(Geo.formatDistance(r.distance))")
                    .font(.system(size: 15)).foregroundColor(UI.dim)
                HStack(spacing: 12) {
                    Button { nav.stop() } label: {
                        Text("Cancelar").frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Capsule().fill(Color.white.opacity(0.08)))
                    }
                    Button { nav.start() } label: {
                        Label("Iniciar", systemImage: "location.north.fill").frame(maxWidth: .infinity).padding(.vertical, 14)
                            .background(Capsule().fill(UI.accent)).foregroundColor(.white)
                    }
                }
                .font(.system(size: 17, weight: .semibold)).foregroundColor(.white)
            } else if nav.calculating {
                HStack { ProgressView().tint(.white); Text("Calculando a rota…").foregroundColor(.white) }
            } else {
                Text("Busque um destino acima. A rota aparece aqui e no painel da moto.")
                    .font(.system(size: 15)).foregroundColor(UI.dim)
                if let e = nav.errorText { Text(e).font(.system(size: 13)).foregroundColor(UI.coral) }
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 26, style: .continuous).fill(UI.surface).ignoresSafeArea(edges: .bottom))
        .shadow(color: .black.opacity(0.4), radius: 16, y: -4)
    }
}

/// Prévia do que vai para o painel.
final class PanelPreview: ObservableObject {
    @Published var image: CGImage?
    func start() {
        MapStreamer.shared.onPreview = { [weak self] img in self?.image = img }
        MapStreamer.shared.setPreview(true)
    }
    func stop() {
        MapStreamer.shared.setPreview(false)
        MapStreamer.shared.onPreview = nil
    }
}

/// Busca de endereços e lugares (Apple Maps).
final class SearchModel: NSObject, ObservableObject, MKLocalSearchCompleterDelegate {
    @Published var query = "" { didSet { completer.queryFragment = query } }
    @Published private(set) var results: [MKLocalSearchCompletion] = []
    private let completer = MKLocalSearchCompleter()

    override init() {
        super.init()
        completer.delegate = self
        completer.resultTypes = [.address, .pointOfInterest]
        if let l = KeepAlive.shared.last {
            completer.region = MKCoordinateRegion(center: l.coordinate, latitudinalMeters: 60_000, longitudinalMeters: 60_000)
        }
    }

    func completerDidUpdateResults(_ c: MKLocalSearchCompleter) { results = Array(c.results.prefix(8)) }
    func completer(_ c: MKLocalSearchCompleter, didFailWithError error: Error) { results = [] }

    func pick(_ r: MKLocalSearchCompletion, done: @escaping (MKMapItem?) -> Void) {
        query = r.title
        MKLocalSearch(request: MKLocalSearch.Request(completion: r)).start { resp, _ in
            done(resp?.mapItems.first)
        }
    }
}

/// Mapa da Apple (escuro) com a rota e os radares.
struct NavMap: UIViewRepresentable {
    let route: MKRoute?
    let destination: MKMapItem?
    let following: Bool

    func makeCoordinator() -> Coord { Coord() }

    func makeUIView(context: Context) -> MKMapView {
        let m = MKMapView()
        m.overrideUserInterfaceStyle = .dark
        m.showsUserLocation = true
        m.pointOfInterestFilter = .excludingAll
        m.delegate = context.coordinator
        m.userTrackingMode = .follow
        context.coordinator.addRadars(m)
        return m
    }

    func updateUIView(_ m: MKMapView, context: Context) {
        let c = context.coordinator
        if c.shownRoute !== route {
            c.shownRoute = route
            m.removeOverlays(m.overlays)
            m.removeAnnotations(m.annotations.filter { $0 is DestinationPin })
            if let r = route {
                m.addOverlay(r.polyline)
                if !following {
                    m.setVisibleMapRect(r.polyline.boundingMapRect, edgePadding: UIEdgeInsets(top: 160, left: 40, bottom: 260, right: 40), animated: true)
                }
            }
            if let d = destination {
                let pin = DestinationPin()
                pin.coordinate = d.placemark.coordinate
                pin.title = d.name
                m.addAnnotation(pin)
            }
            c.addRadars(m)
        }
        if following && m.userTrackingMode != .followWithHeading { m.setUserTrackingMode(.followWithHeading, animated: true) }
    }

    final class DestinationPin: MKPointAnnotation {}
    final class RadarPin: MKPointAnnotation {}

    final class Coord: NSObject, MKMapViewDelegate {
        var shownRoute: MKRoute?

        func addRadars(_ m: MKMapView) {
            m.removeAnnotations(m.annotations.filter { $0 is RadarPin })
            let here = KeepAlive.shared.last?.coordinate
            var list = RadarStore.shared.all
            if let h = here { list.sort { Geo.meters(h, $0.coord) < Geo.meters(h, $1.coord) } }
            for r in list.prefix(300) {
                let p = RadarPin()
                p.coordinate = r.coord
                p.title = r.maxspeed.map { "Radar \($0) km/h" } ?? "Radar"
                m.addAnnotation(p)
            }
        }

        func mapView(_ m: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
            let r = MKPolylineRenderer(overlay: overlay)
            r.strokeColor = UIColor(red: 0.24, green: 0.55, blue: 1, alpha: 1)
            r.lineWidth = 7
            return r
        }

        func mapView(_ m: MKMapView, viewFor a: MKAnnotation) -> MKAnnotationView? {
            if a is MKUserLocation { return nil }
            let v = MKMarkerAnnotationView(annotation: a, reuseIdentifier: a is RadarPin ? "radar" : "dest")
            if a is RadarPin {
                v.markerTintColor = UI.coralUI
                v.glyphImage = UIImage(systemName: "camera.metering.spot")
                v.displayPriority = .defaultLow
            } else {
                v.markerTintColor = UIColor(red: 0.24, green: 0.55, blue: 1, alpha: 1)
                v.glyphImage = UIImage(systemName: "flag.checkered")
            }
            return v
        }
    }
}
