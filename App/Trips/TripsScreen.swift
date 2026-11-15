import SwiftUI
import MapKit
import Charts

/// Diário de Bordo: gravação, lista de percursos e detalhes no estilo dos apps de treino.
struct TripsScreen: View {
    @ObservedObject var rec = TripRecorder.shared
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    recordCard
                    monthCard
                    if rec.trips.isEmpty {
                        Text("Nenhum percurso ainda. Com a gravação automática ligada, o Tron Racing grava sozinho quando você anda com a moto conectada.")
                            .font(.system(size: 14)).foregroundColor(UI.dim).padding(.top, 8)
                    }
                    ForEach(rec.trips) { t in
                        NavigationLink { TripDetail(trip: t) } label: { TripRow(trip: t) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(18)
            }
            .background(UI.bg.ignoresSafeArea())
            .navigationTitle("Diário de Bordo")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Fechar") { dismiss() } } }
        }
        .tint(UI.accent)
    }

    private var recordCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if rec.recording, let t = rec.current {
                HStack(spacing: 8) {
                    Circle().fill(UI.coral).frame(width: 10, height: 10)
                    Text("GRAVANDO").font(.system(size: 13, weight: .heavy)).kerning(1.5).foregroundColor(UI.coral)
                    Spacer()
                    Text(Geo.formatDuration(t.duration)).font(.system(size: 14, weight: .semibold)).foregroundColor(UI.dim)
                }
                HStack(alignment: .firstTextBaseline, spacing: 22) {
                    stat(Geo.formatDistance(t.distance), "distância", big: true)
                    stat("\(Int((t.avgSpeed * 3.6).rounded())) km/h", "média")
                    stat("\(Int((t.maxSpeed * 3.6).rounded())) km/h", "máxima")
                }
                Button { rec.stop() } label: {
                    Text("Encerrar e salvar").font(.system(size: 16, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Capsule().fill(UI.coral)).foregroundColor(.white)
                }
            } else {
                Button { rec.start() } label: {
                    Label("Gravar percurso agora", systemImage: "record.circle").font(.system(size: 16, weight: .semibold))
                        .frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Capsule().fill(UI.accent)).foregroundColor(.white)
                }
                Toggle(isOn: $rec.autoRecord) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Gravar sozinho").foregroundColor(.white)
                        Text("Começa ao andar com a moto conectada e para depois de 8 min parado.")
                            .font(.system(size: 12)).foregroundColor(UI.dim)
                    }
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(UI.surface))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(UI.line))
    }

    private var monthCard: some View {
        let m = rec.monthSummary
        return HStack {
            stat(String(format: "%.0f km", m.km), "neste mês")
            Spacer()
            stat("\(m.rides)", m.rides == 1 ? "percurso" : "percursos")
            Spacer()
            stat(String(format: "%.1f h", m.hours).replacingOccurrences(of: ".", with: ","), "rodando")
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(UI.surface))
    }

    private func stat(_ v: String, _ l: String, big: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(v).font(.system(size: big ? 30 : 20, weight: .bold)).foregroundColor(.white)
            Text(l).font(.system(size: 12)).foregroundColor(UI.dim)
        }
    }
}

struct TripRow: View {
    let trip: Trip
    @State private var img: UIImage?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ZStack {
                Rectangle().fill(UI.card)
                if let i = img { Image(uiImage: i).resizable().aspectRatio(contentMode: .fill) }
                else { ProgressView().tint(UI.dim) }
            }
            .frame(height: 150).clipped()
            VStack(alignment: .leading, spacing: 6) {
                Text(trip.title).font(.system(size: 18, weight: .bold)).foregroundColor(.white)
                Text(trip.start.formatted(.dateTime.weekday(.wide).day().month(.wide).hour().minute()))
                    .font(.system(size: 12)).foregroundColor(UI.dim)
                HStack(spacing: 18) {
                    mini(Geo.formatDistance(trip.distance), "distância")
                    mini(Geo.formatDuration(trip.movingTime), "rodando")
                    mini("\(Int((trip.avgSpeed * 3.6).rounded())) km/h", "média")
                }
                .padding(.top, 4)
            }
            .padding(14)
        }
        .background(UI.surface)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous).stroke(UI.line))
        .task(id: trip.id) {
            let pts = TripRecorder.shared.points(for: trip)
            img = await TripMap.snapshot(pts, size: CGSize(width: 360, height: 150))
        }
    }

    private func mini(_ v: String, _ l: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(v).font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            Text(l).font(.system(size: 11)).foregroundColor(UI.dim)
        }
    }
}

struct TripDetail: View {
    @State var trip: Trip
    @State private var points: [TripPoint] = []
    @State private var map: UIImage?
    @State private var shareImage: UIImage?
    @State private var renaming = false
    @State private var newTitle = ""
    @State private var confirmDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                ZStack(alignment: .bottomTrailing) {
                    RoundedRectangle(cornerRadius: 18).fill(UI.card)
                    if let m = map { Image(uiImage: m).resizable().aspectRatio(contentMode: .fill) }
                    else { ProgressView().tint(UI.dim) }
                }
                .frame(height: 320)
                .clipShape(RoundedRectangle(cornerRadius: 18))
                ForEach(trip.records, id: \.self) { r in
                    HStack(spacing: 12) {
                        Image(systemName: "trophy.fill").font(.system(size: 22)).foregroundColor(Color(red: 1, green: 0.78, blue: 0.2))
                        Text("Parabéns! \(r)").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(UI.surface))
                }
                statsGrid
                if points.count > 10 { speedChart }
            }
            .padding(18)
        }
        .background(UI.bg.ignoresSafeArea())
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let img = shareImage {
                    ShareLink(item: Image(uiImage: img), preview: SharePreview(trip.title, image: Image(uiImage: img))) {
                        Image(systemName: "square.and.arrow.up")
                    }
                }
                Menu {
                    Button { newTitle = trip.title; renaming = true } label: { Label("Renomear", systemImage: "pencil") }
                    Button(role: .destructive) { confirmDelete = true } label: { Label("Apagar", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
        .alert("Nome do percurso", isPresented: $renaming) {
            TextField("Nome", text: $newTitle)
            Button("Salvar") { TripRecorder.shared.rename(trip, to: newTitle); trip.title = newTitle; makeShare() }
            Button("Cancelar", role: .cancel) {}
        }
        .confirmationDialog("Apagar este percurso? Não dá para desfazer.", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Apagar", role: .destructive) { TripRecorder.shared.delete(trip); dismiss() }
        }
        .task {
            points = TripRecorder.shared.points(for: trip)
            map = await TripMap.snapshot(points, size: CGSize(width: 390, height: 320))
            makeShare()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(trip.title).font(.system(size: 28, weight: .heavy)).foregroundColor(.white)
            Text(trip.start.formatted(.dateTime.weekday(.wide).day().month(.wide).year().hour().minute()))
                .font(.system(size: 13)).foregroundColor(UI.dim)
            if let p = trip.placeLine {
                Label(p, systemImage: "mappin.and.ellipse").font(.system(size: 14, weight: .medium)).foregroundColor(UI.dim)
            }
        }
    }

    private var statsGrid: some View {
        let items: [(String, String)] = [
            ("Distância", Geo.formatDistance(trip.distance)),
            ("Velocidade média", "\(Int((trip.avgSpeed * 3.6).rounded())) km/h"),
            ("Tempo rodando", Geo.formatDuration(trip.movingTime)),
            ("Velocidade máxima", "\(Int((trip.maxSpeed * 3.6).rounded())) km/h"),
            ("Subida acumulada", "\(Int(trip.elevationGain.rounded())) m"),
            ("Duração total", Geo.formatDuration(trip.duration)),
        ]
        return LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], spacing: 18) {
            ForEach(items, id: \.0) { it in
                VStack(alignment: .leading, spacing: 3) {
                    Text(it.0).font(.system(size: 13)).foregroundColor(UI.dim)
                    Text(it.1).font(.system(size: 24, weight: .bold)).foregroundColor(.white)
                }
            }
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(UI.surface))
    }

    private var speedChart: some View {
        let step = max(1, points.count / 300)
        let t0 = points.first?.t ?? 0
        let data = stride(from: 0, to: points.count, by: step).map { (min: (points[$0].t - t0) / 60, kmh: points[$0].speed * 3.6) }
        return VStack(alignment: .leading, spacing: 8) {
            Text("Velocidade").font(.system(size: 15, weight: .semibold)).foregroundColor(.white)
            Chart(data.indices, id: \.self) { i in
                AreaMark(x: .value("min", data[i].min), y: .value("km/h", data[i].kmh))
                    .foregroundStyle(LinearGradient(colors: [UI.accent.opacity(0.5), UI.accent.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                LineMark(x: .value("min", data[i].min), y: .value("km/h", data[i].kmh))
                    .foregroundStyle(UI.accent)
            }
            .chartXAxisLabel("minutos")
            .chartYAxisLabel("km/h")
            .frame(height: 160)
        }
        .padding(18)
        .background(RoundedRectangle(cornerRadius: 18).fill(UI.surface))
    }

    /// Imagem para compartilhar: mapa + números, no estilo do app.
    @MainActor private func makeShare() {
        guard let m = map else { return }
        let card = VStack(alignment: .leading, spacing: 0) {
            Image(uiImage: m).resizable().aspectRatio(contentMode: .fill).frame(width: 390, height: 300).clipped()
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(trip.title).font(.system(size: 22, weight: .heavy)).foregroundColor(.white)
                    Spacer()
                    Text("TRON").font(UI.wide(16)).foregroundColor(.white.opacity(0.85))
                    Text("Racing").font(UI.script(18)).foregroundColor(.white.opacity(0.85))
                }
                if let p = trip.placeLine { Text(p).font(.system(size: 13)).foregroundColor(UI.dim) }
                HStack(spacing: 22) {
                    shareStat("Distância", Geo.formatDistance(trip.distance))
                    shareStat("Média", "\(Int((trip.avgSpeed * 3.6).rounded())) km/h")
                    shareStat("Máxima", "\(Int((trip.maxSpeed * 3.6).rounded())) km/h")
                    shareStat("Tempo", Geo.formatDuration(trip.movingTime))
                }
            }
            .padding(18)
        }
        .frame(width: 390)
        .background(UI.bg)
        let r = ImageRenderer(content: card)
        r.scale = 3
        shareImage = r.uiImage
    }

    private func shareStat(_ l: String, _ v: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(l).font(.system(size: 11)).foregroundColor(UI.dim)
            Text(v).font(.system(size: 17, weight: .bold)).foregroundColor(.white)
        }
    }
}

/// Foto do mapa escuro com o traçado em laranja, início (verde) e chegada (quadriculado).
enum TripMap {
    private static let cache = NSCache<NSString, UIImage>()

    static func snapshot(_ pts: [TripPoint], size: CGSize) async -> UIImage? {
        guard pts.count > 1 else { return nil }
        let key = "\(pts.first!.t)-\(pts.count)-\(Int(size.width))x\(Int(size.height))" as NSString
        if let c = cache.object(forKey: key) { return c }
        var rect = MKMapRect.null
        for p in pts { rect = rect.union(MKMapRect(origin: MKMapPoint(p.coord), size: MKMapSize(width: 1, height: 1))) }
        let opt = MKMapSnapshotter.Options()
        opt.mapRect = rect.insetBy(dx: -rect.width * 0.18 - 400, dy: -rect.height * 0.18 - 400)
        opt.size = size
        opt.traitCollection = UITraitCollection(userInterfaceStyle: .dark)
        opt.mapType = .mutedStandard
        opt.pointOfInterestFilter = .excludingAll
        guard let snap = try? await MKMapSnapshotter(options: opt).start() else { return nil }
        let img = UIGraphicsImageRenderer(size: size).image { _ in
            snap.image.draw(at: .zero)
            let path = UIBezierPath()
            let step = max(1, pts.count / 1500)
            for (n, i) in stride(from: 0, to: pts.count, by: step).enumerated() {
                let p = snap.point(for: pts[i].coord)
                if n == 0 { path.move(to: p) } else { path.addLine(to: p) }
            }
            path.addLine(to: snap.point(for: pts.last!.coord))
            path.lineJoinStyle = .round
            path.lineCapStyle = .round
            UIColor.black.withAlphaComponent(0.6).setStroke(); path.lineWidth = 7; path.stroke()
            UI.accentUI.setStroke(); path.lineWidth = 4; path.stroke()
            let a = snap.point(for: pts.first!.coord), b = snap.point(for: pts.last!.coord)
            UIColor(red: 0.3, green: 0.85, blue: 0.45, alpha: 1).setFill()
            UIBezierPath(ovalIn: CGRect(x: a.x - 7, y: a.y - 7, width: 14, height: 14)).fill()
            UIColor.white.setStroke()
            let ring = UIBezierPath(ovalIn: CGRect(x: a.x - 7, y: a.y - 7, width: 14, height: 14)); ring.lineWidth = 2; ring.stroke()
            for r in 0..<3 { for c in 0..<3 {
                ((r + c) % 2 == 0 ? UIColor.white : UIColor.black).setFill()
                UIRectFill(CGRect(x: b.x - 7.5 + CGFloat(c) * 5, y: b.y - 7.5 + CGFloat(r) * 5, width: 5, height: 5))
            } }
        }
        cache.setObject(img, forKey: key)
        return img
    }
}
