import SwiftUI
import MapKit
import UIKit
import Photos

struct DailyRouteMapView: View {
    @StateObject private var locationManager = GPSLocationManager.shared
    @State private var position: MapCameraPosition = .userLocation(followsHeading: true, fallback: .automatic)
    @State private var stayPoints: [StayPoint] = []
    @State private var ttSegments: [TTSegment] = []
    @State private var legLabelsByPoint: [String] = []
    @State private var showExportSuccess = false
    @State private var showExportFailure = false
    @State private var exportErrorMessage = ""
    @State private var isFollowingUser = true

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                topControlBar
                mapViewArea
            }
            .navigationTitle("每日路線軌跡")
            .navigationBarTitleDisplayMode(.inline)
            .alert("匯出成功", isPresented: $showExportSuccess) {
                Button("確定", role: .cancel) { }
            } message: {
                Text("地圖軌跡影像已成功儲存至相簿。")
            }
            .alert("匯出失敗", isPresented: $showExportFailure) {
                Button("確定", role: .cancel) { }
            } message: {
                Text(exportErrorMessage)
            }
        }
        .onAppear {
            refreshStayPoints()
        }
        .onChange(of: locationManager.todayPoints.count) { _, count in
            refreshStayPoints()
            if count > 1 && isFollowingUser {
                withAnimation {
                    position = .userLocation(followsHeading: true, fallback: .automatic)
                }
            }
        }
        .onChange(of: locationManager.manualStayPoints.count) { _, _ in
            refreshStayPoints()
        }
        .onReceive(NotificationCenter.default.publisher(for: .deliverySessionDidStop)) { _ in
            exportMapImage()
        }
    }

    private var topControlBar: some View {
        HStack(spacing: 8) {
            Button(action: {
                if locationManager.isTracking {
                    locationManager.stopTracking()
                } else {
                    locationManager.startTracking()
                }
            }) {
                HStack {
                    Image(systemName: locationManager.isTracking ? "pause.circle.fill" : "play.circle.fill")
                    Text(locationManager.isTracking ? "停止" : "追蹤")
                }
                .font(.subheadline.bold())
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(locationManager.isTracking ? Color.red : Color.green)
                .foregroundColor(.white)
                .cornerRadius(20)
            }

            Spacer()

            Button(action: {
                isFollowingUser.toggle()
                if isFollowingUser {
                    withAnimation {
                        position = .userLocation(followsHeading: true, fallback: .automatic)
                    }
                } else {
                    fitRouteInView()
                }
            }) {
                Image(systemName: isFollowingUser ? "location.fill" : "map.fill")
                    .font(.subheadline)
                    .padding(8)
                    .background(Color.purple.opacity(0.15))
                    .foregroundColor(.purple)
                    .clipShape(Circle())
            }

            Button(action: {
                exportMapImage()
            }) {
                HStack {
                    Image(systemName: "square.and.arrow.up")
                    Text("匯出圖")
                }
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color.blue)
                .foregroundColor(.white)
                .cornerRadius(8)
            }

            Button(action: {
                locationManager.todayPoints.removeAll()
                locationManager.clearManualStayPoints()
                stayPoints.removeAll()
                ttSegments.removeAll()
                legLabelsByPoint.removeAll()
            }) {
                Text("清除")
                    .font(.subheadline)
                    .foregroundColor(.gray)
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
    }

    private var mapViewArea: some View {
        ZStack {
            Map(position: $position) {
                if locationManager.todayPoints.count > 1 {
                    MapPolyline(coordinates: locationManager.todayPoints.map { $0.coordinate })
                        .stroke(.yellow, lineWidth: 6)
                }

                ForEach(ttSegments) { seg in
                    Annotation("", coordinate: seg.midCoordinate) {
                        Text("\(seg.label): \(seg.minutes)分")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Color.purple.opacity(0.9))
                            .cornerRadius(5)
                    }
                }

                ForEach(Array(stayPoints.enumerated()), id: \.element.id) { i, stay in
                    let idx = i + 1
                    let duration = max(0, Int(stay.departureTime.timeIntervalSince(stay.arrivalTime) / 60))
                    Annotation("", coordinate: stay.coordinate) {
                        MinimalStayAnnotationView(index: idx, durationMinutes: duration)
                    }
                }

                if let firstPoint = locationManager.todayPoints.first {
                    Annotation("", coordinate: firstPoint.coordinate) {
                        MapTagView(text: "出發 \(locationManager.startTimeString)", color: .green, above: true)
                    }
                }

                if let lastPoint = locationManager.todayPoints.last, locationManager.todayPoints.count > 1 {
                    Annotation("", coordinate: lastPoint.coordinate) {
                        MapTagView(text: "結束 \(locationManager.endTimeString)", color: .red, above: false)
                    }
                }
            }
            .mapControls {
                MapUserLocationButton()
                MapCompass()
            }
            .overlay(alignment: .topLeading) {
                topLeftDataCenterCard
            }
        }
    }

    private var topLeftDataCenterCard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                Text("開始：\(locationManager.startTimeString)")
                Text("結束：\(locationManager.endTimeString)")
                Text("總時間：\(totalDurationString)")

                Divider()
                    .background(Color.white.opacity(0.6))

                ForEach(Array(stayPoints.enumerated()), id: \.element.id) { i, stay in
                    let idx = i + 1
                    let duration = max(0, Int(stay.departureTime.timeIntervalSince(stay.arrivalTime) / 60))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("S\(idx) \(timeString(stay.arrivalTime))")
                        Text("E\(idx) \(timeString(stay.departureTime))")
                        Text("ST\(idx): \(duration) MIN")
                            .bold()
                    }
                    if idx < stayPoints.count {
                        Spacer().frame(height: 4)
                    }
                }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .foregroundColor(.white)
            .padding(10)
        }
        .frame(maxWidth: 190, maxHeight: 280)
        .background(Color.black.opacity(0.75))
        .cornerRadius(10)
        .shadow(radius: 4)
        .padding(.top, 10)
        .padding(.leading, 10)
    }

    private var totalDurationString: String {
        guard let first = locationManager.todayPoints.first?.timestamp,
              let last = locationManager.todayPoints.last?.timestamp,
              locationManager.todayPoints.count > 1 else { return "0 HR 0 MIN" }
        
        let totalMinutes = max(0, Int(last.timeIntervalSince(first) / 60))
        let hours = totalMinutes / 60
        let mins = totalMinutes % 60
        return hours > 0 ? "\(hours) HR \(mins) MIN" : "\(mins) MIN"
    }

    private func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: date)
    }

    private func refreshStayPoints() {
        let autoStays = locationManager.calculateStayPoints()
        let merged = (autoStays + locationManager.manualStayPoints)
            .sorted { $0.arrivalTime < $1.arrivalTime }
        stayPoints = merged
        ttSegments = computeTTSegments(from: merged)
        legLabelsByPoint = computeLegLabelsByPoint(from: merged)
    }

    private func computeLegLabelsByPoint(from stays: [StayPoint]) -> [String] {
        let points = locationManager.todayPoints
        guard !points.isEmpty else { return [] }

        struct Boundary {
            let endTime: Date
            let label: String
        }
        var boundaries: [Boundary] = []
        if let first = stays.first {
            boundaries.append(Boundary(endTime: first.arrivalTime, label: "出-1"))
        }
        for i in 0..<max(0, stays.count - 1) {
            boundaries.append(Boundary(endTime: stays[i + 1].arrivalTime, label: "\(i + 1)-\(i + 2)"))
        }
        let lastLabel = stays.isEmpty ? "出-終" : "\(stays.count)-終"
        boundaries.append(Boundary(endTime: points.last!.timestamp, label: lastLabel))

        var result: [String] = []
        result.reserveCapacity(points.count)
        var bIndex = 0
        for point in points {
            while bIndex < boundaries.count - 1 && point.timestamp > boundaries[bIndex].endTime {
                bIndex += 1
            }
            result.append(boundaries[bIndex].label)
        }
        return result
    }

    private func computeTTSegments(from stays: [StayPoint]) -> [TTSegment] {
        guard let firstPoint = locationManager.todayPoints.first,
              let lastPoint = locationManager.todayPoints.last,
              locationManager.todayPoints.count > 1 else { return [] }

        struct Leg {
            let from: CLLocationCoordinate2D
            let fromTime: Date
            let to: CLLocationCoordinate2D
            let toTime: Date
            let label: String
        }

        var legs: [Leg] = []
        if let firstStay = stays.first {
            legs.append(Leg(from: firstPoint.coordinate, fromTime: firstPoint.timestamp, to: firstStay.coordinate, toTime: firstStay.arrivalTime, label: "出-1"))
        }
        if stays.count > 1 {
            for i in 0..<(stays.count - 1) {
                legs.append(Leg(from: stays[i].coordinate, fromTime: stays[i].departureTime, to: stays[i + 1].coordinate, toTime: stays[i + 1].arrivalTime, label: "\(i + 1)-\(i + 2)"))
            }
        }
        if let lastStay = stays.last {
            legs.append(Leg(from: lastStay.coordinate, fromTime: lastStay.departureTime, to: lastPoint.coordinate, toTime: lastPoint.timestamp, label: "\(stays.count)-終"))
        }

        return legs.compactMap { leg in
            let minutes = Int(leg.toTime.timeIntervalSince(leg.fromTime) / 60)
            guard minutes > 0 else { return nil }
            let mid = CLLocationCoordinate2D(
                latitude: (leg.from.latitude + leg.to.latitude) / 2,
                longitude: (leg.from.longitude + leg.to.longitude) / 2
            )
            return TTSegment(midCoordinate: mid, minutes: minutes, label: leg.label)
        }
    }

    private func fitRouteInView() {
        let coords = locationManager.todayPoints.map { $0.coordinate }
        guard !coords.isEmpty else { return }
        let lats = coords.map { $0.latitude }
        let lngs = coords.map { $0.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLng = lngs.min(), let maxLng = lngs.max() else { return }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
            longitudeDelta: max((maxLng - minLng) * 1.4, 0.01)
        )
        withAnimation {
            position = .region(MKCoordinateRegion(center: center, span: span))
        }
    }

    // MARK: - 匯出地圖畫布
    @MainActor
    private func exportMapImage() {
        let coords = locationManager.todayPoints.map { $0.coordinate }
        guard !coords.isEmpty else {
            self.exportErrorMessage = "目前沒有軌跡點可供匯出"
            self.showExportFailure = true
            return
        }
        
        let lats = coords.map { $0.latitude }
        let lngs = coords.map { $0.longitude }
        guard let minLat = lats.min(), let maxLat = lats.max(),
              let minLng = lngs.min(), let maxLng = lngs.max() else { return }

        let center = CLLocationCoordinate2D(
            latitude: (minLat + maxLat) / 2,
            longitude: (minLng + maxLng) / 2
        )
        let span = MKCoordinateSpan(
            latitudeDelta: max((maxLat - minLat) * 1.4, 0.01),
            longitudeDelta: max((maxLng - minLng) * 1.4, 0.01)
        )
        
        let options = MKMapSnapshotter.Options()
        options.region = MKCoordinateRegion(center: center, span: span)
        options.size = CGSize(width: 1400, height: 1400)
        options.scale = UIScreen.main.scale
        
        let snapshotter = MKMapSnapshotter(options: options)
        snapshotter.start { snapshot, error in
            guard let snapshot = snapshot else {
                DispatchQueue.main.async {
                    self.exportErrorMessage = "地圖畫面產生失敗：\(error?.localizedDescription ?? "未知錯誤")"
                    self.showExportFailure = true
                }
                return
            }
            
            let finalImage = self.drawOverlays(on: snapshot)
            
            FootprintImageSaver.saveImageToMonthlyAlbum(image: finalImage) { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.showExportSuccess = true
                    } else {
                        self.exportErrorMessage = error?.localizedDescription ?? "存檔失敗，請確認相簿存取權限。"
                        self.showExportFailure = true
                    }
                }
            }
        }
    }

    private func drawOverlays(on snapshot: MKMapSnapshotter.Snapshot) -> UIImage {
        let renderer = UIGraphicsImageRenderer(size: snapshot.image.size)
        let timeFormatter = DateFormatter()
        timeFormatter.dateFormat = "HH:mm"

        return renderer.image { rendererContext in
            snapshot.image.draw(at: .zero)
            let ctx = rendererContext.cgContext

            let points = locationManager.todayPoints.map { snapshot.point(for: $0.coordinate) }
            if points.count > 1 {
                ctx.setStrokeColor(UIColor.systemYellow.cgColor)
                ctx.setLineWidth(6)
                ctx.setLineJoin(.round)
                ctx.setLineCap(.round)
                ctx.move(to: points[0])
                points.dropFirst().forEach { ctx.addLine(to: $0) }
                ctx.strokePath()

                drawDirectionArrows(on: ctx, points: points, legLabels: legLabelsByPoint)
            }

            for seg in ttSegments {
                drawTag("\(seg.label): \(seg.minutes)分", at: snapshot.point(for: seg.midCoordinate), color: .systemPurple)
            }

            if let first = locationManager.todayPoints.first {
                drawTag("出發 \(timeFormatter.string(from: first.timestamp))", at: snapshot.point(for: first.coordinate), color: .systemGreen, verticalOffset: -34)
            }
            if let last = locationManager.todayPoints.last, locationManager.todayPoints.count > 1 {
                drawTag("結束 \(timeFormatter.string(from: last.timestamp))", at: snapshot.point(for: last.coordinate), color: .systemRed, verticalOffset: 34)
            }

            for (i, stay) in stayPoints.enumerated() {
                let idx = i + 1
                let duration = max(0, Int(stay.departureTime.timeIntervalSince(stay.arrivalTime) / 60))
                let p = snapshot.point(for: stay.coordinate)
                drawTag("\(idx): \(duration)分", at: p, color: .black)
            }

            drawDataCenterCard(imageSize: snapshot.image.size)
        }
    }

    private func drawDirectionArrows(on ctx: CGContext, points: [CGPoint], legLabels: [String]) {
        guard points.count > 1 else { return }
        let arrowSpacing: CGFloat = 90
        var distanceSinceLastArrow: CGFloat = arrowSpacing

        for i in 1..<points.count {
            let p0 = points[i - 1]
            let p1 = points[i]
            let dx = p1.x - p0.x
            let dy = p1.y - p0.y
            let segmentLength = sqrt(dx * dx + dy * dy)
            guard segmentLength > 0 else { continue }

            distanceSinceLastArrow += segmentLength
            if distanceSinceLastArrow >= arrowSpacing {
                distanceSinceLastArrow = 0
                let angle = atan2(dy, dx)
                let mid = CGPoint(x: (p0.x + p1.x) / 2, y: (p0.y + p1.y) / 2)
                let label = i < legLabels.count ? legLabels[i] : (legLabels.last ?? "")
                drawArrowhead(on: ctx, at: mid, angle: angle, legLabel: label)
            }
        }
    }

    private func drawArrowhead(on ctx: CGContext, at point: CGPoint, angle: CGFloat, legLabel: String) {
        let size: CGFloat = 13
        ctx.saveGState()
        ctx.translateBy(x: point.x, y: point.y)
        ctx.rotate(by: angle)

        let path = CGMutablePath()
        path.move(to: CGPoint(x: size, y: 0))
        path.addLine(to: CGPoint(x: -size * 0.6, y: size * 0.65))
        path.addLine(to: CGPoint(x: -size * 0.6, y: -size * 0.65))
        path.closeSubpath()

        ctx.addPath(path)
        ctx.setFillColor(UIColor.white.cgColor)
        ctx.fillPath()

        ctx.addPath(path)
        ctx.setStrokeColor(UIColor.black.cgColor)
        ctx.setLineWidth(1.5)
        ctx.strokePath()
        ctx.restoreGState()

        guard !legLabel.isEmpty else { return }
        let badgeAttrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 12),
            .foregroundColor: UIColor.white,
            .strokeColor: UIColor.black,
            .strokeWidth: -4.0
        ]
        let badge = NSAttributedString(string: legLabel, attributes: badgeAttrs)
        let badgeSize = badge.size()
        badge.draw(at: CGPoint(x: point.x + 10, y: point.y - badgeSize.height / 2))
    }

    private func drawDataCenterCard(imageSize: CGSize) {
        let chipPaddingH: CGFloat = 12
        let chipPaddingV: CGFloat = 7
        let chipSpacing: CGFloat = 8
        let rowSpacing: CGFloat = 8
        let margin: CGFloat = 30
        let headerFont = UIFont.boldSystemFont(ofSize: 23)
        let bodyFont = UIFont.systemFont(ofSize: 19, weight: .semibold)

        // 新程式碼：加入「年月日」資訊
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy/MM/dd"
        let dateString = dateFormatter.string(from: locationManager.todayPoints.first?.timestamp ?? Date())

        var chips: [(text: String, font: UIFont)] = [
            ("日期 \(dateString)", headerFont), // 👈 新增這行：加入當下的年月日
            ("開始 \(locationManager.startTimeString)", headerFont),
            ("結束 \(locationManager.endTimeString)", headerFont),
            ("總時間 \(totalDurationString)", headerFont)
        ]
        for (i, stay) in stayPoints.enumerated() {
            let idx = i + 1
            let duration = max(0, Int(stay.departureTime.timeIntervalSince(stay.arrivalTime) / 60))
            chips.append(("S\(idx) \(timeString(stay.arrivalTime))", bodyFont))
            chips.append(("E\(idx) \(timeString(stay.departureTime))", bodyFont))
            chips.append(("ST\(idx) \(duration)分", bodyFont))
        }

        let maxX = imageSize.width - margin
        var x: CGFloat = margin
        var y: CGFloat = margin
        var rowHeight: CGFloat = 0

        for chip in chips {
            let plainAttrs: [NSAttributedString.Key: Any] = [.font: chip.font]
            let textSize = NSAttributedString(string: chip.text, attributes: plainAttrs)
                .boundingRect(with: CGSize(width: 400, height: 60), options: [.usesLineFragmentOrigin], context: nil).size
            let chipWidth = textSize.width + chipPaddingH * 2
            let chipHeight = textSize.height + chipPaddingV * 2

            if x + chipWidth > maxX, x > margin {
                x = margin
                y += rowHeight + rowSpacing
                rowHeight = 0
            }

            let chipRect = CGRect(x: x, y: y, width: chipWidth, height: chipHeight)
            UIColor.black.setFill()
            UIBezierPath(roundedRect: chipRect, cornerRadius: chipHeight / 2).fill()

            let drawAttrs: [NSAttributedString.Key: Any] = [
                .font: chip.font,
                .foregroundColor: UIColor.white
            ]
            NSAttributedString(string: chip.text, attributes: drawAttrs)
                .draw(at: CGPoint(x: x + chipPaddingH, y: y + chipPaddingV))

            x += chipWidth + chipSpacing
            rowHeight = max(rowHeight, chipHeight)
        }
    }

    private func drawTag(_ text: String, at point: CGPoint, color: UIColor, verticalOffset: CGFloat = 0) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: UIFont.boldSystemFont(ofSize: 18),
            .foregroundColor: UIColor.white
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        let bounds = attributed.boundingRect(with: CGSize(width: 400, height: 200), options: [.usesLineFragmentOrigin], context: nil)
        let padding: CGFloat = 6
        let rect = CGRect(x: point.x - (bounds.width + padding * 2) / 2, y: point.y - (bounds.height + padding * 2) / 2 + verticalOffset, width: bounds.width + padding * 2, height: bounds.height + padding * 2)

        let ctx = UIGraphicsGetCurrentContext()
        ctx?.saveGState()
        UIBezierPath(roundedRect: rect, cornerRadius: 6).addClip()
        color.withAlphaComponent(0.85).setFill()
        UIRectFill(rect)
        attributed.draw(with: rect.insetBy(dx: padding, dy: padding), options: [.usesLineFragmentOrigin], context: nil)
        ctx?.restoreGState()
    }
}

// MARK: - 輔助 View 結構
private struct TTSegment: Identifiable {
    let id = UUID()
    let midCoordinate: CLLocationCoordinate2D
    let minutes: Int
    let label: String
}

private struct MapTagView: View {
    let text: String
    let color: Color
    let above: Bool

    var body: some View {
        VStack(spacing: 2) {
            if above { tag }
            Circle().fill(color).frame(width: 8, height: 8)
            if !above { tag }
        }
    }

    private var tag: some View {
        Text(text)
            .font(.system(size: 10, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(color)
            .cornerRadius(5)
            .shadow(radius: 2)
            .fixedSize()
    }
}

private struct MinimalStayAnnotationView: View {
    let index: Int
    let durationMinutes: Int

    var body: some View {
        Text("\(index): \(durationMinutes)分")
            .font(.system(size: 9, weight: .bold))
            .foregroundColor(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color.black.opacity(0.85))
            .cornerRadius(5)
            .shadow(radius: 2)
            .fixedSize()
    }
}

class FootprintImageSaver {
    static func saveImageToMonthlyAlbum(image: UIImage, completion: @escaping (Bool, Error?) -> Void) {
        let now = Date()
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年MM月"
        let albumTitle = formatter.string(from: now)
        
        PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
            guard status == .authorized || status == .limited else {
                completion(false, NSError(domain: "PhotoError", code: 403, userInfo: [NSLocalizedDescriptionKey: "未取得相簿權限"]))
                return
            }
            
            // 1. 先取得或建立月份相簿
            let album = fetchOrCreateAlbum(title: albumTitle)
            
            // 2. 寫入照片並加入該相簿
            PHPhotoLibrary.shared().performChanges({
                let creationRequest = PHAssetChangeRequest.creationRequestForAsset(from: image)
                creationRequest.creationDate = now
                
                if let album = album, let placeholder = creationRequest.placeholderForCreatedAsset {
                    let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                    albumChangeRequest?.addAssets([placeholder] as NSArray)
                }
            }) { success, error in
                DispatchQueue.main.async {
                    completion(success, error)
                }
            }
        }
    }
    
    private static func fetchOrCreateAlbum(title: String) -> PHAssetCollection? {
        let fetchOptions = PHFetchOptions()
        fetchOptions.predicate = NSPredicate(format: "title = %@", title)
        let collection = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: fetchOptions)
        
        if let first = collection.firstObject { return first }
        
        var placeholder: PHObjectPlaceholder?
        try? PHPhotoLibrary.shared().performChangesAndWait {
            // 正確建立專屬相簿
            let createAlbumRequest = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: title)
            placeholder = createAlbumRequest.placeholderForCreatedAssetCollection
        }
        
        if let placeholder = placeholder {
            return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [placeholder.localIdentifier], options: nil).firstObject
        }
        return nil
    }
}
